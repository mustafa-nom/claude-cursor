//
//  AppIconCache.swift
//  claude-cursor
//
//  Memoizes `NSWorkspace.icon(forBundleIdentifier:)` lookups so the
//  chat sessions sidebar can render dozens of app icons per render pass
//  without going back to Launch Services every time. Icons rarely change
//  within a session, so a simple in-memory dictionary is enough — we
//  never evict, because the full set of bundle IDs the user has chatted
//  under is tiny (low tens).
//

import AppKit
import SwiftUI

/// Thread-safe, process-lifetime in-memory cache of `NSImage` app icons
/// keyed by bundle identifier. Designed for main-actor SwiftUI use — all
/// lookups and mutations happen on the main actor so no locking is needed.
@MainActor
final class AppIconCache {

    /// Shared instance. Single instance is fine because the cache is
    /// process-wide read-mostly data; no per-panel state.
    static let shared = AppIconCache()

    private var cachedIconsByBundleIdentifier: [String: NSImage] = [:]

    /// Placeholder icon used when a bundle identifier can't be resolved
    /// (empty string from legacy logs, uninstalled app, or sandbox quirk).
    /// We still memoize a single shared placeholder so SwiftUI gets a
    /// stable identity when re-rendering rows with unknown apps.
    private lazy var placeholderGenericAppIcon: NSImage = {
        // "app.fill" is a symbol that reads as a generic native app. This
        // matches what Finder falls back to for a corrupted .app bundle.
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .medium
        )
        let symbol = NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: "Unknown application"
        ) ?? NSImage()
        return symbol.withSymbolConfiguration(configuration) ?? symbol
    }()

    private init() {}

    /// Returns the Launch Services icon for the given bundle identifier,
    /// memoized across the app's lifetime. Falls back to a generic icon
    /// when the bundle can't be resolved (e.g. empty string from legacy
    /// session files that predate bundle-ID logging).
    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage {
        if let cached = cachedIconsByBundleIdentifier[bundleIdentifier] {
            return cached
        }

        // Empty bundle ID short-circuits to the placeholder so legacy
        // session_*.md rows still render something in the sidebar.
        guard !bundleIdentifier.isEmpty else {
            cachedIconsByBundleIdentifier[bundleIdentifier] = placeholderGenericAppIcon
            return placeholderGenericAppIcon
        }

        let workspace = NSWorkspace.shared
        if let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let bundleIcon = workspace.icon(forFile: applicationURL.path)
            cachedIconsByBundleIdentifier[bundleIdentifier] = bundleIcon
            return bundleIcon
        }

        // Bundle ID didn't resolve — app may be uninstalled since the
        // chat happened. Cache the placeholder so we don't re-hit Launch
        // Services on every sidebar render.
        cachedIconsByBundleIdentifier[bundleIdentifier] = placeholderGenericAppIcon
        return placeholderGenericAppIcon
    }

    /// Clears the cache. Only intended for tests; production code should
    /// never need to evict because bundle-ID → icon mappings are stable
    /// for the lifetime of the process.
    func removeAllCachedIcons() {
        cachedIconsByBundleIdentifier.removeAll()
    }
}

/// SwiftUI helper that renders the cached app icon at a fixed point size.
/// Keeps sidebar row layout logic free of `NSImage` → `Image` boilerplate.
struct CachedAppIconView: View {
    let bundleIdentifier: String
    let pointSize: CGFloat

    var body: some View {
        Image(nsImage: AppIconCache.shared.icon(forBundleIdentifier: bundleIdentifier))
            .resizable()
            .interpolation(.high)
            .frame(width: pointSize, height: pointSize)
    }
}
