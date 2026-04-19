//
//  ComputerUseSupport.swift
//  claude-cursor
//
//  Shared helpers for Claude Computer Use: aspect-ratio-matched image sizing
//  (pixel dimensions must match tool `display_width_px` / `display_height_px`),
//  target display selection, per-run metrics, and JSONL run logging.
//

import AppKit
import Foundation

// MARK: - Image formatting

enum ComputerUseImageFormatting {

    private static let supportedComputerUseResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768, 1024.0 / 768.0),
        (1280, 800, 1280.0 / 800.0),
        (1366, 768, 1366.0 / 768.0),
    ]

    /// Picks the Anthropic-recommended Computer Use resolution closest to the display aspect ratio.
    static func bestComputerUseResolution(
        forDisplayWidth displayWidth: Int,
        displayHeight: Int
    ) -> (width: Int, height: Int) {
        let displayAspectRatio = Double(displayWidth) / Double(max(1, displayHeight))
        var bestWidth = 1280
        var bestHeight = 800
        var smallestDifference = Double.greatestFiniteMagnitude
        for resolution in supportedComputerUseResolutions {
            let difference = abs(displayAspectRatio - resolution.aspectRatio)
            if difference < smallestDifference {
                smallestDifference = difference
                bestWidth = resolution.width
                bestHeight = resolution.height
            }
        }
        return (width: bestWidth, height: bestHeight)
    }

    /// Resizes image data to exact pixel dimensions for Computer Use (1:1 bitmap, Retina-safe).
    static func resizeImageDataForComputerUse(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Prepares a screen capture for the Computer Use API: same JPEG the model sees matches declared dimensions.
    static func jpegDataResizedForComputerUse(
        captureImageData: Data,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) -> Data? {
        let resolution = bestComputerUseResolution(
            forDisplayWidth: displayWidthInPoints,
            displayHeight: displayHeightInPoints
        )
        return resizeImageDataForComputerUse(
            originalImageData: captureImageData,
            targetWidth: resolution.width,
            targetHeight: resolution.height
        )
    }

    static func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFour = [UInt8](imageData.prefix(4))
            if firstFour == pngSignature { return "image/png" }
        }
        return "image/jpeg"
    }
}

// MARK: - Computer Use `type` action normalization

/// Interprets model `type` payloads so a mistaken trailing word `return` (e.g. `cursorreturn`)
/// becomes typed text plus a real Return keypress instead of literal letters.
enum ComputerUseTypeTextNormalization {

    struct NormalizedTypeAction {
        let textToType: String
        let shouldPressReturnAfterTyping: Bool
    }

    static func normalizedTypeAction(from rawText: String) -> NormalizedTypeAction {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NormalizedTypeAction(textToType: "", shouldPressReturnAfterTyping: true)
        }
        let lowercasedTrimmed = trimmed.lowercased()
        if lowercasedTrimmed == "return" || lowercasedTrimmed == "enter" {
            return NormalizedTypeAction(textToType: "", shouldPressReturnAfterTyping: true)
        }

        let returnSuffix = "return"
        guard lowercasedTrimmed.hasSuffix(returnSuffix), trimmed.count >= returnSuffix.count else {
            return NormalizedTypeAction(textToType: trimmed, shouldPressReturnAfterTyping: false)
        }

        let prefixEndIndex = trimmed.index(trimmed.endIndex, offsetBy: -returnSuffix.count)
        let textBeforeSuffix = trimmed[..<prefixEndIndex]
        if let lastCharacterBeforeSuffix = textBeforeSuffix.last, lastCharacterBeforeSuffix.isWhitespace {
            return NormalizedTypeAction(textToType: trimmed, shouldPressReturnAfterTyping: false)
        }

        let textPrefix = String(textBeforeSuffix)
        return NormalizedTypeAction(textToType: textPrefix, shouldPressReturnAfterTyping: true)
    }
}

// MARK: - Target display

enum ComputerUseTargetDisplay {

    /// Prefer the screen that contains the frontmost app’s key window; fall back to primary-like screen.
    static func preferredNSScreenForAutomation() -> NSScreen {
        if let screen = screenContainingFrontmostApplicationKeyWindow() {
            return screen
        }
        return NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    /// 1-based index for Anthropic `display_number`, stable against `NSScreen.screens` order.
    static func displayNumber(for targetScreen: NSScreen) -> Int {
        guard let targetID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 1
        }
        for (index, screen) in NSScreen.screens.enumerated() {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               id.uint32Value == targetID.uint32Value {
                return index + 1
            }
        }
        return 1
    }

    private static func screenContainingFrontmostApplicationKeyWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestBoundsQuartz: CGRect?
        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else {
                continue
            }
            if width < 80 || height < 60 { continue }
            let cgRect = CGRect(x: x, y: y, width: width, height: height)
            if bestBoundsQuartz == nil || (width * height) > (bestBoundsQuartz!.width * bestBoundsQuartz!.height) {
                bestBoundsQuartz = cgRect
            }
        }

        guard let rectQuartz = bestBoundsQuartz else { return nil }

        let rectAppKit = quartzTopLeftRectToGlobalAppKitRect(rectQuartz)
        let center = CGPoint(x: rectAppKit.midX, y: rectAppKit.midY)

        for screen in NSScreen.screens {
            if screen.frame.contains(center) {
                return screen
            }
        }
        return nil
    }

    /// `CGWindowListCopyWindowInfo` bounds use top-left global Quartz space; `NSScreen.frame` uses bottom-left AppKit space.
    private static func quartzTopLeftRectToGlobalAppKitRect(_ quartzRect: CGRect) -> CGRect {
        guard let primaryLike = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return quartzRect
        }
        let globalMaxY = primaryLike.frame.maxY
        let appKitY = globalMaxY - quartzRect.origin.y - quartzRect.height
        return CGRect(x: quartzRect.origin.x, y: appKitY, width: quartzRect.width, height: quartzRect.height)
    }
}

// MARK: - Capture selection

enum ComputerUseCaptureSelection {

    /// Picks the capture whose `displayFrame` best overlaps the target screen (AppKit coords).
    static func bestCapture(
        matchingTargetScreen targetScreen: NSScreen,
        in captures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        let targetFrame = targetScreen.frame
        var best: CompanionScreenCapture?
        var bestArea: CGFloat = -1
        for capture in captures {
            let intersection = capture.displayFrame.intersection(targetFrame)
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = capture
            }
        }
        return best ?? captures.first
    }
}

// MARK: - Run metrics (stuck detection + cache-aware telemetry)

/// Per-run bookkeeping for a Computer Use agent loop. Used for two
/// unrelated concerns:
///
/// 1. Stuck detection — `consecutiveActionsWithoutMeaningfulScreenChange`
///    + the matching threshold on `ClaudeAPI` break the loop when actions
///    no longer move the UI.
/// 2. Cache-aware telemetry — wall-clock time, screenshot count, and the
///    three Anthropic `usage` input-token buckets (`input_tokens`,
///    `cache_read_input_tokens`, `cache_creation_input_tokens`) plus
///    `output_tokens`. Raw `input_tokens` is misleading for a long-context
///    loop because the growing message history gets heavily prompt-cached;
///    reporting the three buckets separately is the only way to see
///    whether caching is actually working.
///
/// The loop in `ClaudeAPI.runComputerUseAgentLoop` accumulates into these
/// fields each iteration, and `CompanionToolRegistry` folds them into the
/// `run_completed` / `run_refused` / `run_failed` JSONL events plus the
/// one-line summary it appends to `rollup.log`.
final class ComputerUseRunMetrics {
    var consecutiveActionsWithoutMeaningfulScreenChange: Int = 0

    /// Moment the loop started, used to compute `wall_clock_seconds` on finish.
    let wallClockStartDate: Date = Date()

    /// Incremented each time the action executor successfully captures a
    /// verification screenshot — roughly one per action, plus the initial
    /// screenshot. Helps size per-run image-upload cost.
    var screenshotCount: Int = 0

    /// Anthropic `usage.input_tokens` — tokens that were NOT read from cache
    /// and NOT used to create a cache entry. The "fresh" input-token cost.
    var inputTokensUncached: Int = 0

    /// Anthropic `usage.cache_read_input_tokens` — tokens served from the
    /// prompt cache. For a long-running loop this is usually the biggest
    /// bucket once the conversation is primed.
    var inputTokensCacheRead: Int = 0

    /// Anthropic `usage.cache_creation_input_tokens` — tokens that were
    /// cached for later reads (one-time cost per cacheable prefix).
    var inputTokensCacheCreation: Int = 0

    /// Anthropic `usage.output_tokens` — total model output tokens across
    /// all iterations.
    var outputTokens: Int = 0

    func resetStuckCounter() {
        consecutiveActionsWithoutMeaningfulScreenChange = 0
    }

    func registerActionOutcome(actionType: String, screenMeaningfullyChanged: Bool) {
        let expectsVisualChange = [
            "left_click", "right_click", "double_click", "scroll", "type", "key",
        ].contains(actionType)
        if expectsVisualChange {
            if screenMeaningfullyChanged {
                consecutiveActionsWithoutMeaningfulScreenChange = 0
            } else {
                consecutiveActionsWithoutMeaningfulScreenChange += 1
            }
        }
    }

    /// Folds a single Anthropic response's `usage` block into the running
    /// totals. Missing keys are treated as zero so partial/malformed usage
    /// blocks don't corrupt the aggregate.
    func addUsageFromResponseJSON(usageDict: [String: Any]?) {
        guard let usageDict else { return }
        inputTokensUncached += intField(usageDict, "input_tokens")
        inputTokensCacheRead += intField(usageDict, "cache_read_input_tokens")
        inputTokensCacheCreation += intField(usageDict, "cache_creation_input_tokens")
        outputTokens += intField(usageDict, "output_tokens")
    }

    private func intField(_ dict: [String: Any], _ key: String) -> Int {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Double { return Int(value) }
        return 0
    }

    /// Assembles a dict suitable for merging into the JSONL payload for
    /// `run_completed` / `run_refused` / `run_failed` events. Callers
    /// typically merge additional run-specific fields on top.
    func telemetryPayload(
        iterationsUsed: Int,
        finalStatus: String,
        frontmostBundleID: String
    ) -> [String: Any] {
        let wallClockSeconds = max(0, Date().timeIntervalSince(wallClockStartDate))
        return [
            "iterations": iterationsUsed,
            "wall_clock_seconds": Double(round(wallClockSeconds * 100) / 100),
            "screenshot_count": screenshotCount,
            "input_tokens_uncached": inputTokensUncached,
            "input_tokens_cache_read": inputTokensCacheRead,
            "input_tokens_cache_creation": inputTokensCacheCreation,
            "output_tokens": outputTokens,
            "final_status": finalStatus,
            "frontmost_bundle_id": frontmostBundleID,
        ]
    }
}

// MARK: - JSONL logging

enum ComputerUseRunLogger {

    /// Schema version for JSONL events under `raw/computer-use-runs/`.
    /// Bumped to 2 when we added cache-aware telemetry fields and the
    /// `run_refused` event type. Any external tooling reading these files
    /// should branch on `schema_version` so unknown types fail loudly
    /// rather than silently.
    static let currentSchemaVersion = 2

    static func appendRunEvent(
        wikiRawDirectoryURL: URL,
        runID: String,
        eventType: String,
        payload: [String: Any]
    ) {
        var merged = payload
        merged["schema_version"] = currentSchemaVersion
        merged["run_id"] = runID
        merged["event_type"] = eventType
        merged["recorded_at"] = ISO8601DateFormatter().string(from: Date())

        let logDirectory = wikiRawDirectoryURL.appendingPathComponent("computer-use-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let fileURL = logDirectory.appendingPathComponent("\(runID).jsonl")
        guard let lineData = try? JSONSerialization.data(withJSONObject: merged),
              var lineString = String(data: lineData, encoding: .utf8) else {
            return
        }
        lineString.append("\n")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(lineString.utf8))
        } else {
            try? lineString.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Appends a single, greppable summary line per run to
    /// `computer-use-runs/rollup.log`. The per-run JSONL file is great for
    /// detailed debugging but too noisy for eyeballing trends across many
    /// runs — one line per run makes regressions obvious (wall-clock
    /// creep, iteration count creep, cache-hit ratio drops, etc.).
    ///
    /// Format is space-separated key=value pairs so the file is both
    /// human-readable (`tail -f rollup.log`) and easy to parse with awk/
    /// cut. Values never contain spaces — bundle IDs are reverse-DNS
    /// strings, final_status is an enum, everything else is numeric.
    static func appendRollupSummary(
        wikiRawDirectoryURL: URL,
        runID: String,
        telemetryPayload: [String: Any]
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var summaryLine = "\(timestamp) run_id=\(runID)"
        let keysInStableOrder = [
            "final_status",
            "iterations",
            "wall_clock_seconds",
            "screenshot_count",
            "input_tokens_uncached",
            "input_tokens_cache_read",
            "input_tokens_cache_creation",
            "output_tokens",
            "frontmost_bundle_id",
        ]
        for key in keysInStableOrder {
            if let value = telemetryPayload[key] {
                summaryLine += " \(key)=\(value)"
            }
        }
        summaryLine += "\n"

        let logDirectory = wikiRawDirectoryURL.appendingPathComponent("computer-use-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let rollupFileURL = logDirectory.appendingPathComponent("rollup.log")

        if FileManager.default.fileExists(atPath: rollupFileURL.path),
           let handle = try? FileHandle(forWritingTo: rollupFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(summaryLine.utf8))
        } else {
            try? summaryLine.write(to: rollupFileURL, atomically: true, encoding: .utf8)
        }
    }
}
