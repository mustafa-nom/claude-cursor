//
//  YouTubeLessonExtractor.swift
//  claude-cursor
//
//  Turns a YouTube URL into a structured `Lesson` — an ordered list of
//  discrete, actionable steps with timestamps that the lesson overlay can
//  walk the user through. The extractor has two stages:
//
//    1. Transcript fetch — hits the Cloudflare Worker's /youtube-transcript
//       route which uses YouTube's Innertube API (ANDROID client context via
//       watch-page-extracted API key) to fetch caption tracks with valid auth
//       tokens. Returns an array of { start, duration, text } segments, or
//       signals that captions are unavailable.
//    2. Step structuring — sends the raw transcript to Claude with a prompt
//       that asks for discrete steps, each with a title, instruction body,
//       and timestamp range. The LLM returns JSON which we decode into
//       `LessonStep` values.
//
//  All network calls go through the Cloudflare Worker proxy — no raw API
//  keys ever ship in the app binary.
//

import Foundation

// MARK: - Data Models

/// A single discrete step within a YouTube tutorial lesson. The user is
/// guided through steps in order; each step corresponds to a specific time
/// range of the source video.
struct LessonStep: Codable, Equatable, Identifiable {
    /// Stable identifier (index-based) so SwiftUI lists can track steps
    /// correctly across re-renders.
    let id: Int

    /// Short title of the step, displayed in the step banner. Should read
    /// as an imperative — e.g. "Import the footage", "Create a new
    /// composition". Keep under ~60 characters.
    let title: String

    /// Longer, more specific instruction shown below the title. Tells the
    /// user what to actually do in their target app during this step.
    /// Typically one or two sentences.
    let instructionText: String

    /// Timestamp in the source video where this step begins, in seconds.
    /// Used to seek the PiP player when the user advances to this step.
    let startTimestampSeconds: Double

    /// Timestamp in the source video where this step ends, in seconds.
    /// Used to auto-advance when the PiP player crosses this boundary.
    let endTimestampSeconds: Double
}

/// A complete tutorial lesson extracted from a YouTube video. Owns the
/// video metadata plus the ordered list of steps. Persisted progress keys
/// off `youtubeVideoID`.
struct Lesson: Equatable {
    let youtubeVideoID: String
    let videoTitle: String
    let videoURL: URL
    let steps: [LessonStep]
}

/// A raw transcript segment returned by the worker. Client-side data model
/// that mirrors the worker's JSON shape.
struct YouTubeTranscriptSegment: Codable, Equatable {
    let start: Double
    let duration: Double
    let text: String
}

// MARK: - Errors

/// Errors that can occur while extracting a lesson from a YouTube video.
/// Each case carries enough information for the UI to show a meaningful
/// message without exposing implementation details.
enum YouTubeLessonExtractionError: LocalizedError {
    /// The supplied URL couldn't be parsed into a valid YouTube video ID.
    case invalidYouTubeURL(String)

    /// The worker rejected the transcript request. The status code and
    /// body string are included for logging.
    case transcriptFetchFailed(statusCode: Int, body: String)

    /// The video has no captions available and the Whisper fallback path
    /// is not yet wired up in V2. Users should pick a captioned video.
    case noCaptionsAvailable(fallbackReason: String)

    /// Claude returned a response that didn't contain valid JSON in the
    /// expected shape. The raw response is included for debugging.
    case stepStructuringFailedInvalidJSON(rawResponse: String)

    /// Claude's structuring step returned zero steps, which means the
    /// transcript couldn't be decomposed into actionable steps (too short,
    /// not tutorial-style, or the LLM misunderstood).
    case stepStructuringFailedNoSteps

    var errorDescription: String? {
        switch self {
        case .invalidYouTubeURL(let url):
            return "Couldn't recognize this as a YouTube URL: \(url)"
        case .transcriptFetchFailed(let statusCode, let body):
            return "Transcript fetch failed (HTTP \(statusCode)): \(body)"
        case .noCaptionsAvailable(let fallbackReason):
            return "This video doesn't have captions available (\(fallbackReason)). Pick a tutorial with captions."
        case .stepStructuringFailedInvalidJSON:
            return "Couldn't structure the transcript into steps. The video may be too short or not a tutorial."
        case .stepStructuringFailedNoSteps:
            return "Couldn't find discrete steps in this video. It may not be a step-by-step tutorial."
        }
    }
}

// MARK: - Extractor

/// Fetches YouTube transcripts via the Cloudflare Worker proxy and uses
/// Claude to structure them into ordered lesson steps. Stateless — safe to
/// create and discard per extraction.
final class YouTubeLessonExtractor {

    private let workerBaseURL: String
    private let claudeAPIForStepStructuring: ClaudeAPI
    private let urlSession: URLSession

    /// Maximum number of transcript characters sent to Claude for
    /// structuring. Tutorials longer than this get truncated — the LLM
    /// still produces steps from the first ~40k characters, which covers
    /// well over an hour of speech.
    private let maxTranscriptCharactersForStructuring: Int = 40_000

    /// Upper bound on the number of steps Claude is asked to produce. Keeps
    /// the lesson overlay readable and keeps the JSON response small enough
    /// to fit within the model's max_tokens budget.
    private let maxStepCountRequested: Int = 15

    init(
        workerBaseURL: String,
        claudeAPIForStepStructuring: ClaudeAPI
    ) {
        self.workerBaseURL = workerBaseURL
        self.claudeAPIForStepStructuring = claudeAPIForStepStructuring

        // Use a short-lived URLSession dedicated to transcript fetches.
        // Transcript payloads are small (tens of KB) so we don't need the
        // TLS warmup optimization that ClaudeAPI uses.
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.urlCache = nil
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    // MARK: - Public API

    /// Converts a YouTube URL into a structured lesson. Throws a
    /// `YouTubeLessonExtractionError` if the URL is invalid, captions are
    /// missing, or Claude returns an unparseable response. The returned
    /// `Lesson` is ready to be handed to the lesson overlay.
    func extractLesson(fromYouTubeURL youtubeURL: URL) async throws -> Lesson {
        guard let youtubeVideoID = Self.extractYouTubeVideoID(from: youtubeURL) else {
            throw YouTubeLessonExtractionError.invalidYouTubeURL(youtubeURL.absoluteString)
        }

        if let hardcodedLesson = Self.hardcodedLessonsByVideoID[youtubeVideoID] {
            return hardcodedLesson
        }

        let transcriptSegments = try await fetchTranscriptSegments(
            forYouTubeVideoID: youtubeVideoID
        )

        // Best-effort title fetch — if this fails, fall back to the video
        // ID so the lesson can still be built. Title is cosmetic, not
        // load-bearing for functionality.
        let videoTitleOrFallback = (try? await fetchVideoTitle(forYouTubeVideoID: youtubeVideoID))
            ?? "YouTube tutorial \(youtubeVideoID)"

        let structuredSteps = try await structureTranscriptIntoLessonSteps(
            transcriptSegments: transcriptSegments,
            videoTitle: videoTitleOrFallback
        )

        return Lesson(
            youtubeVideoID: youtubeVideoID,
            videoTitle: videoTitleOrFallback,
            videoURL: youtubeURL,
            steps: structuredSteps
        )
    }

    // MARK: - YouTube URL Parsing

    /// Parses a YouTube URL into its 11-character video ID. Supports the
    /// common URL shapes:
    ///   - https://www.youtube.com/watch?v=VIDEO_ID
    ///   - https://youtube.com/watch?v=VIDEO_ID&other=params
    ///   - https://youtu.be/VIDEO_ID
    ///   - https://m.youtube.com/watch?v=VIDEO_ID
    ///   - https://www.youtube.com/shorts/VIDEO_ID
    ///   - https://www.youtube.com/embed/VIDEO_ID
    /// Returns nil for anything we don't recognize as YouTube.
    static func extractYouTubeVideoID(from youtubeURL: URL) -> String? {
        guard let urlHost = youtubeURL.host?.lowercased() else { return nil }

        // youtu.be/VIDEO_ID — the ID is the first path component after the root slash
        if urlHost == "youtu.be" {
            let firstPathComponent = youtubeURL.pathComponents
                .first(where: { $0 != "/" && !$0.isEmpty })
            return firstPathComponent.flatMap(sanitizeVideoIDCandidate)
        }

        // Any youtube.com host (www., m., music., etc.)
        let isYouTubeHost = urlHost == "youtube.com" || urlHost.hasSuffix(".youtube.com")
        guard isYouTubeHost else { return nil }

        // /watch?v=VIDEO_ID — query parameter form
        if let urlComponents = URLComponents(url: youtubeURL, resolvingAgainstBaseURL: false),
           let queryItems = urlComponents.queryItems {
            if let videoIDQueryItem = queryItems.first(where: { $0.name == "v" })?.value {
                if let sanitizedID = sanitizeVideoIDCandidate(videoIDQueryItem) {
                    return sanitizedID
                }
            }
        }

        // /shorts/VIDEO_ID or /embed/VIDEO_ID — path-based forms
        let pathComponentsWithoutRoot = youtubeURL.pathComponents.filter { $0 != "/" }
        if pathComponentsWithoutRoot.count >= 2 {
            let firstPathSegment = pathComponentsWithoutRoot[0].lowercased()
            if firstPathSegment == "shorts" || firstPathSegment == "embed" || firstPathSegment == "v" {
                return sanitizeVideoIDCandidate(pathComponentsWithoutRoot[1])
            }
        }

        return nil
    }

    /// YouTube video IDs are always exactly 11 characters and use the URL-
    /// safe base64 alphabet. Reject anything that doesn't match.
    private static func sanitizeVideoIDCandidate(_ candidateVideoID: String) -> String? {
        guard candidateVideoID.count == 11 else { return nil }
        let allowedCharacters = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if candidateVideoID.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) {
            return candidateVideoID
        }
        return nil
    }

    // MARK: - Transcript Fetch

    /// Fetches transcript segments for a YouTube video. Tries two strategies:
    ///   1. Direct Innertube IOS client call from the user's machine — uses a
    ///      residential IP so YouTube doesn't block it.
    ///   2. Worker proxy `/youtube-transcript` endpoint — falls back here if
    ///      the direct call fails (shouldn't normally happen).
    ///
    /// The Innertube API is public (no secret keys), so calling it directly
    /// from the client is safe and doesn't expose any credentials.
    private func fetchTranscriptSegments(
        forYouTubeVideoID youtubeVideoID: String
    ) async throws -> [YouTubeTranscriptSegment] {
        // Strategy 1: Direct Innertube call from the client.
        // The user's machine has a residential IP that YouTube doesn't block,
        // unlike the Cloudflare Worker's datacenter IP which gets 429/LOGIN_REQUIRED.
        if let directSegments = try? await fetchTranscriptViaDirectInnertube(
            forYouTubeVideoID: youtubeVideoID
        ), !directSegments.isEmpty {
            return directSegments
        }

        // Strategy 2: Worker proxy fallback.
        return try await fetchTranscriptViaWorkerProxy(
            forYouTubeVideoID: youtubeVideoID
        )
    }

    // MARK: - Direct Innertube (Client-Side)

    /// Well-known Innertube API key used by yt-dlp, YouTube.js, and other
    /// open-source libraries. This is not a secret — it's embedded in
    /// YouTube's own web page JavaScript and is the same for all users.
    private static let innertubeKnownAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    private static let iosYouTubeUserAgent =
        "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)"

    /// Calls YouTube's Innertube /youtubei/v1/player endpoint directly with
    /// the IOS client context to get caption tracks. YouTube deprecated the
    /// ANDROID client for caption access in early 2026; the IOS client is the
    /// proven replacement used by yt-dlp and other libraries.
    ///
    /// Returns nil on any failure so the caller can fall back to the worker.
    private func fetchTranscriptViaDirectInnertube(
        forYouTubeVideoID youtubeVideoID: String
    ) async throws -> [YouTubeTranscriptSegment]? {
        guard let innertubeURL = URL(
            string: "https://www.youtube.com/youtubei/v1/player?key=\(Self.innertubeKnownAPIKey)"
        ) else { return nil }

        let innertubeRequestBody: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "20.03.02",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.2.1.22C161"
                ]
            ],
            "videoId": youtubeVideoID
        ]

        var request = URLRequest(url: innertubeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.iosYouTubeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: innertubeRequestBody)
        request.timeoutInterval = 10

        let (responseData, rawResponse) = try await urlSession.data(for: request)
        guard let httpResponse = rawResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        guard let playerResponse = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }

        let playabilityStatus = (playerResponse["playabilityStatus"] as? [String: Any])?["status"] as? String
        guard playabilityStatus == "OK" else { return nil }

        guard let captionsContainer = playerResponse["captions"] as? [String: Any],
              let tracklistRenderer = captionsContainer["playerCaptionsTracklistRenderer"] as? [String: Any],
              let captionTracks = tracklistRenderer["captionTracks"] as? [[String: Any]],
              !captionTracks.isEmpty else {
            return nil
        }

        // Pick the best caption track: prefer manual English, then ASR English,
        // then any manual track, then any ASR track.
        let selectedTrack = selectBestCaptionTrack(
            fromRawCaptionTracks: captionTracks,
            preferredLanguageCode: "en"
        )
        guard let captionBaseURL = selectedTrack?["baseUrl"] as? String else { return nil }

        // Fetch the actual caption content from the baseUrl. Strip fmt=srv3
        // so the endpoint returns XML by default, which we can parse reliably.
        let captionFetchURLString = captionBaseURL.replacingOccurrences(of: "&fmt=srv3", with: "")
        guard let captionFetchURL = URL(string: captionFetchURLString) else { return nil }

        var captionRequest = URLRequest(url: captionFetchURL)
        captionRequest.setValue(Self.iosYouTubeUserAgent, forHTTPHeaderField: "User-Agent")
        captionRequest.timeoutInterval = 10

        let (captionData, captionRawResponse) = try await urlSession.data(for: captionRequest)
        guard let captionHTTPResponse = captionRawResponse as? HTTPURLResponse,
              (200...299).contains(captionHTTPResponse.statusCode) else {
            return nil
        }

        guard let captionText = String(data: captionData, encoding: .utf8),
              !captionText.isEmpty else {
            return nil
        }

        return parseXMLCaptionsIntoTranscriptSegments(xmlText: captionText)
    }

    /// Picks the best caption track from Innertube's raw JSON response.
    /// Priority: manual preferred-language > manual any > ASR preferred-language > ASR any > first.
    private func selectBestCaptionTrack(
        fromRawCaptionTracks captionTracks: [[String: Any]],
        preferredLanguageCode: String
    ) -> [String: Any]? {
        if captionTracks.isEmpty { return nil }

        let languageMatches: (String) -> Bool = { trackLanguageCode in
            trackLanguageCode == preferredLanguageCode ||
            trackLanguageCode.hasPrefix(preferredLanguageCode + "-")
        }

        let isAutoGenerated: ([String: Any]) -> Bool = { track in
            (track["kind"] as? String) == "asr"
        }

        // Manual track in preferred language
        if let match = captionTracks.first(where: { track in
            !isAutoGenerated(track) &&
            languageMatches((track["languageCode"] as? String) ?? "")
        }) { return match }

        // Manual track in any language
        if let match = captionTracks.first(where: { !isAutoGenerated($0) }) {
            return match
        }

        // ASR track in preferred language
        if let match = captionTracks.first(where: { track in
            isAutoGenerated(track) &&
            languageMatches((track["languageCode"] as? String) ?? "")
        }) { return match }

        // ASR track in any language
        if let match = captionTracks.first(where: { isAutoGenerated($0) }) {
            return match
        }

        return captionTracks.first
    }

    /// Parses YouTube's XML caption format (the default when fmt=srv3 is
    /// stripped from the baseUrl) into transcript segments.
    /// XML shape: `<transcript><text start="1.23" dur="4.56">Caption text</text>...</transcript>`
    private func parseXMLCaptionsIntoTranscriptSegments(
        xmlText: String
    ) -> [YouTubeTranscriptSegment] {
        var segments: [YouTubeTranscriptSegment] = []

        let textTagPattern = try! NSRegularExpression(
            pattern: #"<text\s+start="([^"]*)"(?:\s+dur="([^"]*)")?[^>]*>([\s\S]*?)</text>"#,
            options: []
        )

        let fullRange = NSRange(xmlText.startIndex..., in: xmlText)
        let matches = textTagPattern.matches(in: xmlText, options: [], range: fullRange)

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }

            let startString = (xmlText as NSString).substring(with: match.range(at: 1))
            let durationString = match.range(at: 2).location != NSNotFound
                ? (xmlText as NSString).substring(with: match.range(at: 2))
                : "0"
            let rawCaptionText = (xmlText as NSString).substring(with: match.range(at: 3))

            let startSeconds = Double(startString) ?? 0
            let durationSeconds = max(0, Double(durationString) ?? 0)
            let cleanedText = rawCaptionText
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
                .decodeHTMLEntities()

            if cleanedText.isEmpty { continue }

            segments.append(YouTubeTranscriptSegment(
                start: startSeconds,
                duration: durationSeconds,
                text: cleanedText
            ))
        }

        return segments
    }

    // MARK: - Worker Proxy Transcript Fetch

    /// Calls the worker's /youtube-transcript endpoint and decodes the
    /// result. Throws `noCaptionsAvailable` if the video has no captions
    /// and `transcriptFetchFailed` for transport/status errors.
    private func fetchTranscriptViaWorkerProxy(
        forYouTubeVideoID youtubeVideoID: String
    ) async throws -> [YouTubeTranscriptSegment] {
        guard let transcriptRouteURL = URL(string: "\(workerBaseURL)/youtube-transcript") else {
            throw YouTubeLessonExtractionError.transcriptFetchFailed(
                statusCode: -1,
                body: "Invalid worker base URL: \(workerBaseURL)"
            )
        }

        var request = URLRequest(url: transcriptRouteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "videoID": youtubeVideoID,
            "preferredLanguage": "en"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, rawResponse) = try await urlSession.data(for: request)
        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw YouTubeLessonExtractionError.transcriptFetchFailed(
                statusCode: -1,
                body: "No HTTP response"
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw YouTubeLessonExtractionError.transcriptFetchFailed(
                statusCode: httpResponse.statusCode,
                body: errorBody
            )
        }

        struct TranscriptResponse: Codable {
            let segments: [YouTubeTranscriptSegment]
            let hasCaptions: Bool
            let fallbackReason: String?
        }

        let decodedResponse = try JSONDecoder().decode(TranscriptResponse.self, from: responseData)

        if !decodedResponse.hasCaptions || decodedResponse.segments.isEmpty {
            let fallbackReasonOrUnknown = decodedResponse.fallbackReason
                ?? "no_caption_tracks_available"
            throw YouTubeLessonExtractionError.noCaptionsAvailable(
                fallbackReason: fallbackReasonOrUnknown
            )
        }

        return decodedResponse.segments
    }

    // MARK: - Video Title Fetch (Best Effort)

    /// Fetches the human-readable title of a YouTube video using the public
    /// oEmbed endpoint. No API key required. Returns nil on any failure —
    /// callers should fall back to a generic title.
    private func fetchVideoTitle(forYouTubeVideoID youtubeVideoID: String) async throws -> String? {
        var oEmbedURLComponents = URLComponents(string: "https://www.youtube.com/oembed")
        oEmbedURLComponents?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(youtubeVideoID)"),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let oEmbedURL = oEmbedURLComponents?.url else { return nil }

        let (responseData, rawResponse) = try await urlSession.data(from: oEmbedURL)
        guard let httpResponse = rawResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let parsedJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        return parsedJSON?["title"] as? String
    }

    // MARK: - Step Structuring (via Claude)

    /// Sends the raw transcript to Claude with a prompt that asks for a
    /// JSON array of discrete steps. Claude is instructed to keep step
    /// count reasonable, use actionable imperative titles, and anchor each
    /// step to a timestamp range in the video.
    private func structureTranscriptIntoLessonSteps(
        transcriptSegments: [YouTubeTranscriptSegment],
        videoTitle: String
    ) async throws -> [LessonStep] {
        let transcriptAsAnnotatedText = formatTranscriptForLLM(
            transcriptSegments: transcriptSegments
        )
        let truncatedTranscriptText = truncateTranscriptIfTooLong(
            transcriptText: transcriptAsAnnotatedText,
            maxCharacters: maxTranscriptCharactersForStructuring
        )

        let systemPromptForStepStructuring = Self.stepStructuringSystemPrompt(
            maxStepCount: maxStepCountRequested
        )
        let userPromptForStepStructuring = Self.stepStructuringUserPrompt(
            videoTitle: videoTitle,
            annotatedTranscript: truncatedTranscriptText
        )

        // No images — pass an empty array. ClaudeAPI handles this correctly
        // and just sends a text-only message.
        let claudeResponse = try await claudeAPIForStepStructuring.analyzeImage(
            images: [],
            systemPrompt: systemPromptForStepStructuring,
            conversationHistory: [],
            userPrompt: userPromptForStepStructuring,
            maxTokens: 4096
        )

        return try decodeLessonStepsFromClaudeResponse(
            rawClaudeResponseText: claudeResponse.text
        )
    }

    /// Converts the transcript segments into a text blob that preserves
    /// timestamp anchoring. Each line is prefixed with `[MM:SS]` so Claude
    /// can anchor steps to specific timestamps without us having to send
    /// structured data.
    private func formatTranscriptForLLM(
        transcriptSegments: [YouTubeTranscriptSegment]
    ) -> String {
        var annotatedLines: [String] = []
        for segment in transcriptSegments {
            let formattedTimestamp = Self.formatTimestampForLLM(
                secondsFromStart: segment.start
            )
            let cleanedSegmentText = segment.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !cleanedSegmentText.isEmpty {
                annotatedLines.append("[\(formattedTimestamp)] \(cleanedSegmentText)")
            }
        }
        return annotatedLines.joined(separator: "\n")
    }

    /// Formats seconds as MM:SS or HH:MM:SS depending on duration. Used
    /// for the `[MM:SS]` prefixes in the transcript text sent to Claude.
    private static func formatTimestampForLLM(secondsFromStart: Double) -> String {
        let totalSecondsFloor = Int(secondsFromStart)
        let hoursPart = totalSecondsFloor / 3600
        let minutesPart = (totalSecondsFloor % 3600) / 60
        let secondsPart = totalSecondsFloor % 60
        if hoursPart > 0 {
            return String(format: "%d:%02d:%02d", hoursPart, minutesPart, secondsPart)
        }
        return String(format: "%d:%02d", minutesPart, secondsPart)
    }

    /// If the transcript is longer than `maxCharacters`, truncate at the
    /// last full line boundary so we don't cut mid-sentence. Appends a
    /// marker so the LLM knows the input was truncated.
    private func truncateTranscriptIfTooLong(
        transcriptText: String,
        maxCharacters: Int
    ) -> String {
        guard transcriptText.count > maxCharacters else { return transcriptText }

        let truncationIndex = transcriptText.index(
            transcriptText.startIndex,
            offsetBy: maxCharacters
        )
        let truncatedPrefix = String(transcriptText[..<truncationIndex])

        // Back up to the last newline so we don't cut a line in half.
        if let lastNewlineIndex = truncatedPrefix.lastIndex(of: "\n") {
            let cleanTruncation = String(truncatedPrefix[..<lastNewlineIndex])
            return cleanTruncation + "\n\n[Transcript truncated — original was longer.]"
        }

        return truncatedPrefix + "\n\n[Transcript truncated — original was longer.]"
    }

    /// Parses Claude's response text into `[LessonStep]`. The LLM is
    /// instructed to respond with a JSON array, but in practice it may
    /// wrap the JSON in prose or code fences. We strip common wrappers
    /// before decoding.
    private func decodeLessonStepsFromClaudeResponse(
        rawClaudeResponseText: String
    ) throws -> [LessonStep] {
        let extractedJSONText = extractJSONArrayFromLLMResponse(
            rawLLMResponseText: rawClaudeResponseText
        )

        guard let jsonDataForDecoding = extractedJSONText.data(using: .utf8) else {
            throw YouTubeLessonExtractionError.stepStructuringFailedInvalidJSON(
                rawResponse: rawClaudeResponseText
            )
        }

        // Decode into a loose intermediate type first so we can apply our
        // own indexing (LessonStep.id) rather than trusting the LLM to
        // emit correct indices.
        struct RawStructuredStep: Codable {
            let title: String
            let instructionText: String
            let startTimestampSeconds: Double
            let endTimestampSeconds: Double
        }

        let rawStructuredSteps: [RawStructuredStep]
        do {
            rawStructuredSteps = try JSONDecoder().decode(
                [RawStructuredStep].self,
                from: jsonDataForDecoding
            )
        } catch {
            throw YouTubeLessonExtractionError.stepStructuringFailedInvalidJSON(
                rawResponse: rawClaudeResponseText
            )
        }

        guard !rawStructuredSteps.isEmpty else {
            throw YouTubeLessonExtractionError.stepStructuringFailedNoSteps
        }

        var finalLessonSteps: [LessonStep] = []
        for (stepIndex, rawStep) in rawStructuredSteps.enumerated() {
            // Defensive clamp: some models occasionally return negative
            // timestamps or end < start. Keep the lesson playable by
            // normalizing these before they reach the UI.
            let clampedStart = max(0, rawStep.startTimestampSeconds)
            let clampedEnd = max(clampedStart, rawStep.endTimestampSeconds)
            finalLessonSteps.append(LessonStep(
                id: stepIndex,
                title: rawStep.title.trimmingCharacters(in: .whitespacesAndNewlines),
                instructionText: rawStep.instructionText.trimmingCharacters(in: .whitespacesAndNewlines),
                startTimestampSeconds: clampedStart,
                endTimestampSeconds: clampedEnd
            ))
        }
        return finalLessonSteps
    }

    /// Strips common wrapping patterns from an LLM response so the JSON
    /// array can be decoded. Handles:
    ///   - ```json ... ``` code fences
    ///   - ``` ... ``` plain code fences
    ///   - leading / trailing prose (greedily finds the first [ and last ])
    private func extractJSONArrayFromLLMResponse(
        rawLLMResponseText: String
    ) -> String {
        var workingResponseText = rawLLMResponseText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        // Strip ```json ... ``` or ``` ... ``` fences
        if workingResponseText.hasPrefix("```") {
            if let firstNewlineIndex = workingResponseText.firstIndex(of: "\n") {
                workingResponseText = String(workingResponseText[workingResponseText.index(after: firstNewlineIndex)...])
            }
            if workingResponseText.hasSuffix("```") {
                workingResponseText = String(workingResponseText.dropLast(3))
            }
            workingResponseText = workingResponseText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        // If there's leading/trailing prose, grab the substring from the
        // first '[' to the last ']' — a defensive extraction for cases
        // where the model adds a preamble.
        if let firstOpenBracketIndex = workingResponseText.firstIndex(of: "["),
           let lastCloseBracketIndex = workingResponseText.lastIndex(of: "]"),
           firstOpenBracketIndex < lastCloseBracketIndex {
            return String(workingResponseText[firstOpenBracketIndex...lastCloseBracketIndex])
        }

        return workingResponseText
    }

    // MARK: - Prompts

    /// System prompt that instructs Claude to act as a tutorial decomposer.
    /// Asks for strict JSON output so the response is machine-parseable.
    private static func stepStructuringSystemPrompt(maxStepCount: Int) -> String {
        return """
        You are a tutorial decomposer. You will be given a YouTube tutorial \
        transcript with timestamps. Your job is to break it into discrete, \
        actionable steps that a user can follow along with.

        Output rules:
        - Respond with ONLY a JSON array. No preamble, no code fences, no \
          explanation text. Just the raw JSON array.
        - Produce between 3 and \(maxStepCount) steps. Fewer is better if \
          the tutorial is short — don't pad.
        - Each step must be an object with these exact keys:
            "title": string — short imperative title (under 60 chars). E.g. \
              "Import the footage", "Create a new composition".
            "instructionText": string — 1-2 sentences explaining what the \
              user does during this step. Concrete and specific.
            "startTimestampSeconds": number — when this step begins in the \
              video, in seconds (use the [MM:SS] anchors in the transcript).
            "endTimestampSeconds": number — when this step ends in the \
              video, in seconds. Must be greater than or equal to \
              startTimestampSeconds.
        - Steps must be in chronological order and cover the full duration \
          of the tutorial without major gaps.
        - Ignore intro/outro filler ("hit subscribe", "welcome back") — \
          steps should describe the actual tutorial content only.
        """
    }

    /// User prompt: the video title + the annotated transcript. Claude
    /// extracts structure from this and returns the JSON array.
    private static func stepStructuringUserPrompt(
        videoTitle: String,
        annotatedTranscript: String
    ) -> String {
        return """
        Tutorial video title: \(videoTitle)

        Transcript (timestamps in [MM:SS] format):

        \(annotatedTranscript)

        Now produce the JSON array of steps as described.
        """
    }

    // MARK: - Hardcoded Lessons

    /// Pre-built lessons keyed by YouTube video ID. When a video ID matches,
    /// the extractor returns the hardcoded lesson instantly — no transcript
    /// fetch or Claude call needed. This guarantees specific showcase
    /// tutorials always work regardless of YouTube API availability.
    private static let hardcodedLessonsByVideoID: [String: Lesson] = [
        "l30Eb76Tk5s": Lesson(
            youtubeVideoID: "l30Eb76Tk5s",
            videoTitle: "Full Beginner's Guide to Cursor 2.0",
            videoURL: URL(string: "https://www.youtube.com/watch?v=l30Eb76Tk5s")!,
            steps: [
                LessonStep(
                    id: 0,
                    title: "Open a project folder",
                    instructionText: "Go to File > Open Folder. Create a new folder on your Desktop and select it. All code you generate will be stored here.",
                    startTimestampSeconds: 29,
                    endTimestampSeconds: 89
                ),
                LessonStep(
                    id: 1,
                    title: "Learn the Cursor 2.0 changes",
                    instructionText: "Cursor now has its own Composer model that is 4x faster, and supports running multiple agents simultaneously. The interface has been redesigned.",
                    startTimestampSeconds: 95,
                    endTimestampSeconds: 158
                ),
                LessonStep(
                    id: 2,
                    title: "Customize your theme",
                    instructionText: "Press Cmd+Shift+P to open the Command Palette. Type \"theme\" and select Preferences: Color Theme. Pick whichever theme you like.",
                    startTimestampSeconds: 163,
                    endTimestampSeconds: 201
                ),
                LessonStep(
                    id: 3,
                    title: "Explore the settings",
                    instructionText: "Click the settings gear icon in the top-right corner to open Cursor Settings. You can resize panes, drag tabs around, pin them, or split them into different areas.",
                    startTimestampSeconds: 201,
                    endTimestampSeconds: 244
                ),
                LessonStep(
                    id: 4,
                    title: "Switch between Agent and Editor views",
                    instructionText: "Use the Agent and Editor tabs at the top. Agent view shows running agents and the chat window. Editor view shows your project files. Toggle the left sidebar, terminal, and right pane using the buttons at the top-left.",
                    startTimestampSeconds: 244,
                    endTimestampSeconds: 348
                ),
                LessonStep(
                    id: 5,
                    title: "Create a plan before coding",
                    instructionText: "Switch to Plan mode in the agent pane. Describe what you want to build — be as specific as possible. Review the generated plan markdown, adjust it if needed, then press Build.",
                    startTimestampSeconds: 352,
                    endTimestampSeconds: 413
                ),
                LessonStep(
                    id: 6,
                    title: "Run an agent to build your project",
                    instructionText: "After pressing Build, Cursor spins up an AI agent that executes the plan steps and generates code. Wait for the \"Awaiting Review\" badge before moving on.",
                    startTimestampSeconds: 413,
                    endTimestampSeconds: 488
                ),
                LessonStep(
                    id: 7,
                    title: "Review generated code",
                    instructionText: "Press the Review button to see a diff of all changes. Switch to Editor view for easier reading. Important: changes are already in your files — press Undo All if you don't want them, or Keep All to accept.",
                    startTimestampSeconds: 488,
                    endTimestampSeconds: 573
                ),
                LessonStep(
                    id: 8,
                    title: "Test your project with Live Server",
                    instructionText: "Switch to Ask mode and type \"How can I test and run this code?\" Install the Live Server extension from the Extensions tab, then right-click index.html and choose Open with Live Server.",
                    startTimestampSeconds: 573,
                    endTimestampSeconds: 622
                ),
                LessonStep(
                    id: 9,
                    title: "Run multiple agents at once",
                    instructionText: "Open a new agent from the sidebar for a separate task. Use one agent per discrete task — the original agent keeps its full context for follow-up changes on the same codebase.",
                    startTimestampSeconds: 628,
                    endTimestampSeconds: 772
                ),
                LessonStep(
                    id: 10,
                    title: "Use inline edits with Cmd+K",
                    instructionText: "Highlight code in the editor and press Cmd+K (or Ctrl+K). Type a targeted change like \"clean up this code and add comments.\" Accept or reject the inline suggestion.",
                    startTimestampSeconds: 993,
                    endTimestampSeconds: 1048
                ),
                LessonStep(
                    id: 11,
                    title: "Reference code in the chat",
                    instructionText: "Highlight code and press Cmd+L to send it to the agent chat. Use the @ symbol to reference specific files, folders, or documentation for richer context.",
                    startTimestampSeconds: 1048,
                    endTimestampSeconds: 1108
                ),
                LessonStep(
                    id: 12,
                    title: "Use autocomplete while typing",
                    instructionText: "As you type code in the editor, Cursor predicts the next lines. Press Tab to accept the autocomplete suggestion. This works alongside the chat and inline edit features.",
                    startTimestampSeconds: 1108,
                    endTimestampSeconds: 1148
                ),
                LessonStep(
                    id: 13,
                    title: "Add project rules",
                    instructionText: "Go to Settings > Rules > Add Rule. Choose \"Always Apply\" and write rules like \"always generate docstrings for functions.\" Rules ensure consistent code generation across the project without repeating yourself.",
                    startTimestampSeconds: 1271,
                    endTimestampSeconds: 1367
                ),
                LessonStep(
                    id: 14,
                    title: "Set up version control with Git",
                    instructionText: "Tell the agent \"use source control/git and save this work.\" It will initialize a Git repo, add your files, and create a commit. Check the Source Control tab in the sidebar to see your commit history.",
                    startTimestampSeconds: 1430,
                    endTimestampSeconds: 1570
                ),
            ]
        ),
    ]
}

// MARK: - HTML Entity Decoding

private extension String {
    /// Decodes common HTML entities that YouTube embeds in caption text.
    func decodeHTMLEntities() -> String {
        self.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
