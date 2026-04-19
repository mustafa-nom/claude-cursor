//
//  BrowserTabURLExtractor.swift
//  claude-cursor
//
//  AXUIElement-based active-tab URL extraction for Chromium-family browsers
//  (Chrome, Arc, Brave, Edge). Reads the focused window's `AXAddressField`
//  subrole text field via a depth-limited BFS.
//
//  Two invariants are load-bearing:
//    1. Hard 150ms timeout. AX reads can block indefinitely if the target
//       app is wedged. We dispatch the traversal to a background queue and
//       wait on a `DispatchSemaphore`. If it times out we return nil and
//       let the caller record "no browser context" — never block the user's
//       chat-turn path.
//    2. Bundle-ID allowlist. We only attempt extraction for browsers whose
//       AX trees we've verified to expose `AXAddressField`. Safari doesn't
//       (requires AppleScript + TCC Automation prompt) so it's intentionally
//       omitted in v1; fall back to app-name-only grouping.
//

import AppKit
import ApplicationServices
import Foundation

/// Extracts the URL of the frontmost tab for a running Chromium-family
/// browser. Stateless; safe to call from any actor but the public API
/// runs on the main actor since it touches ClaudeCursorAnalytics.
enum BrowserTabURLExtractor {

    /// Bundle identifiers whose AX tree we know how to read. Safari is
    /// intentionally excluded — see file header. Each of these ships an
    /// `AXTextField` with subrole `AXAddressField` for the location bar.
    static let allowedBundleIdentifiers: Set<String> = [
        "com.google.Chrome",            // Google Chrome
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",            // Brave
        "com.microsoft.edgemac"         // Microsoft Edge
    ]

    /// Hard timeout for the AX traversal. Chosen so that the worst case
    /// on a hung browser process adds < 1 video frame of latency to the
    /// chat-turn pipeline.
    private static let accessibilityReadTimeoutMilliseconds: Int = 150

    /// Depth limit for the BFS. 6 comfortably covers the Chromium
    /// `AXApplication → AXWindow → AXToolbar → AXGroup → AXTextField`
    /// ladder even when Chrome ships minor tree-depth changes.
    private static let accessibilityTraversalMaxDepth: Int = 6

    // MARK: - Public API

    /// Returns the full URL string of the active tab, or nil if the bundle
    /// isn't allowlisted, AX isn't trusted, the traversal didn't find an
    /// address field, or the read timed out. Full URL is callers-only —
    /// the segmenter persists only the hostname + derived tool name.
    @MainActor
    static func activeTabURL(
        forBundleIdentifier bundleIdentifier: String,
        processIdentifier: pid_t
    ) -> String? {
        guard allowedBundleIdentifiers.contains(bundleIdentifier) else { return nil }
        guard AXIsProcessTrusted() else { return nil }

        // The AX read runs off the main actor with a hard wall-clock
        // deadline. If it doesn't beat the deadline we record a timeout
        // event and return nil — the chat turn proceeds without URL data.
        let resultBox = AccessibilityReadResultBox()
        let doneSemaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = searchForAddressField(processIdentifier: processIdentifier)
            doneSemaphore.signal()
        }

        let deadline: DispatchTime = .now() + .milliseconds(accessibilityReadTimeoutMilliseconds)
        if doneSemaphore.wait(timeout: deadline) == .timedOut {
            ClaudeCursorAnalytics.trackBrowserURLExtractionTimeout(
                bundleIdentifier: bundleIdentifier
            )
            return nil
        }

        let extractedURL = resultBox.value
        if extractedURL == nil {
            ClaudeCursorAnalytics.trackBrowserURLExtractionFailed(
                bundleIdentifier: bundleIdentifier
            )
        }
        return extractedURL
    }

    /// Extracts the hostname from a full URL string. Returns nil for
    /// unparseable input or for URLs with no host component (e.g. `file://`,
    /// `chrome://newtab`). The sidebar treats nil hostname as "native app".
    static func hostname(fromRawURL rawURL: String) -> String? {
        guard let host = URLComponents(string: rawURL)?.host, !host.isEmpty else {
            return nil
        }
        return host
    }

    /// Maps a hostname to a human-friendly tool name for the sidebar
    /// sub-folder label ("Linear", "Figma", etc.). Falls back to
    /// title-casing the root-label when the hostname isn't in the
    /// hand-curated map so new tools still show up cleanly — the curated
    /// list exists only to enforce branding (e.g. "GitHub" vs "Github").
    static func deriveToolName(fromHostname host: String) -> String? {
        let normalizedHost = host.lowercased()
        if let curated = curatedHostToToolNameMap[normalizedHost] {
            return curated
        }

        // Also check suffix matches for subdomains — `app.posthog.com`
        // should resolve to the `posthog.com` curated entry if present.
        for (candidateHost, toolName) in curatedHostToToolNameMap {
            if normalizedHost.hasSuffix("." + candidateHost) {
                return toolName
            }
        }

        // Fallback: title-case the registrable label. For `app.posthog.com`
        // → "Posthog"; for `linear.app` → "Linear".
        let labels = normalizedHost.split(separator: ".")
        guard labels.count >= 2 else {
            return host.prefix(1).uppercased() + host.dropFirst()
        }
        let registrableLabel = String(labels[labels.count - 2])
        guard !registrableLabel.isEmpty else { return nil }
        return registrableLabel.prefix(1).uppercased() + registrableLabel.dropFirst()
    }

    // MARK: - Private: AX Traversal

    /// BFS the focused window's accessibility tree looking for a text
    /// field whose subrole is `AXAddressField`. Uses `removeFirst()` to
    /// keep true FIFO ordering — the address bar sits near the top of
    /// the Chromium window, so BFS finds it before deeper toolbar groups.
    private static func searchForAddressField(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)

        var focusedWindowValue: AnyObject?
        let focusedWindowReadStatus = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedWindowReadStatus == .success,
              let rawFocusedWindow = focusedWindowValue else {
            return nil
        }
        let focusedWindowElement = rawFocusedWindow as! AXUIElement

        // (element, depth) pairs so we can honor the depth cap without
        // extra bookkeeping per node.
        var bfsQueue: [(element: AXUIElement, depth: Int)] = [(focusedWindowElement, 0)]

        while !bfsQueue.isEmpty {
            let (currentElement, currentDepth) = bfsQueue.removeFirst()
            if currentDepth > accessibilityTraversalMaxDepth {
                continue
            }

            if let addressValue = addressFieldValueIfMatch(element: currentElement) {
                return addressValue
            }

            var childrenValue: AnyObject?
            AXUIElementCopyAttributeValue(
                currentElement,
                kAXChildrenAttribute as CFString,
                &childrenValue
            )
            if let childElements = childrenValue as? [AXUIElement] {
                for childElement in childElements {
                    bfsQueue.append((childElement, currentDepth + 1))
                }
            }
        }

        return nil
    }

    /// Returns the `AXValue` of `element` if and only if it's an
    /// `AXTextField` with subrole `AXAddressField`. Factored out so the
    /// BFS loop stays flat.
    private static func addressFieldValueIfMatch(element: AXUIElement) -> String? {
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard let roleString = roleValue as? String,
              roleString == (kAXTextFieldRole as String) else {
            return nil
        }

        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard let subroleString = subroleValue as? String,
              subroleString == "AXAddressField" else {
            return nil
        }

        var fieldValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fieldValue)
        return fieldValue as? String
    }

    // MARK: - Private: Hostname → Tool Name Curated Map

    /// Hand-curated map of hostnames to display names. Entries here win
    /// over the title-case fallback so "GitHub" renders with the correct
    /// casing instead of "Github", and so root labels like `google.com`
    /// route to the specific product ("Gmail", "Google Docs").
    private static let curatedHostToToolNameMap: [String: String] = [
        "linear.app": "Linear",
        "figma.com": "Figma",
        "github.com": "GitHub",
        "notion.so": "Notion",
        "docs.google.com": "Google Docs",
        "sheets.google.com": "Google Sheets",
        "drive.google.com": "Google Drive",
        "mail.google.com": "Gmail",
        "slack.com": "Slack",
        "claude.ai": "Claude",
        "chat.openai.com": "ChatGPT",
        "app.posthog.com": "PostHog",
        "posthog.com": "PostHog"
    ]
}

/// Reference-type container so the background-queue closure can write
/// the AX traversal result where the main actor can read it after the
/// semaphore wakes up. Value types won't work — closures capture by
/// value and the write would be lost.
///
/// `@unchecked Sendable` is safe here because the DispatchSemaphore
/// establishes a happens-before relationship: the background queue's
/// write to `value` is published before `signal()`, and the main
/// actor's read happens after `wait()` returns.
private final class AccessibilityReadResultBox: @unchecked Sendable {
    var value: String?
}
