//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

// MARK: - Tool-Use Types

/// Describes a tool Claude may call during a turn. The `inputSchemaJSON`
/// is a JSON Schema object (as a Swift dict) describing the tool's inputs
/// — Anthropic sends this to the model so it knows the required fields
/// and types. Field names mirror Anthropic's wire format exactly.
struct ClaudeToolDefinition {
    let name: String
    let description: String
    /// JSON Schema as a `[String: Any]` dict. Must be serializable via
    /// `JSONSerialization`. Example:
    /// `["type": "object", "properties": [...], "required": [...]]`.
    let inputSchemaJSON: [String: Any]
}

/// Assembled `tool_use` content block emitted by Claude during a stream.
/// `inputJSON` is the fully-parsed input dict (assembled from all the
/// `input_json_delta` chunks for this block index).
struct ClaudeToolUseBlock {
    let id: String        // "toolu_..."
    let name: String      // matching ClaudeToolDefinition.name
    let inputJSON: [String: Any]
}

/// Verification image attached to a `tool_result` content payload.
struct ClaudeToolResultVerificationImage {
    let imageData: Data
    let imageMediaType: String
}

/// The app's response to a single `tool_use` block. Sent back to Claude
/// as a `tool_result` content block on the next turn so the model can
/// read its tool output and continue reasoning.
struct ClaudeToolResultBlock {
    let toolUseID: String
    /// Stringified content Claude reads back. Can be plain text, JSON,
    /// or an error message. Multi-line is fine.
    let content: String
    let isError: Bool
    /// Optional post-action screenshots bundled with the text result so
    /// Claude can visually verify action outcomes across one or more
    /// displays before deciding whether to continue the tool loop.
    let verificationImages: [ClaudeToolResultVerificationImage]

    init(
        toolUseID: String,
        content: String,
        isError: Bool,
        verificationImages: [ClaudeToolResultVerificationImage] = []
    ) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
        self.verificationImages = verificationImages
    }
}

/// Per-content-block accumulator for an in-flight `tool_use` block.
/// The SSE stream chunks the tool's input JSON across many
/// `input_json_delta` events — we concatenate the partial strings here
/// and parse the complete object on `content_block_stop`.
private struct InFlightToolUseBlockBuilder {
    var id: String
    var name: String
    var accumulatedInputJSONString: String = ""
}

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "claude-sonnet-4-6") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await MainActor.run {
                    onTextChunk(currentAccumulatedText)
                }
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        maxTokens: Int = 256
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    // MARK: - Tool-Use Streaming

    /// Maximum number of tool-use iterations before we force-exit the loop.
    /// Prevents runaway token spend in pathological ping-pong flows.
    private static let maximumToolUseIterationsForVisionTools: Int = 5
    /// Output token budget for each streamed tool-use iteration.
    private static let maxOutputTokensForToolStreamingIteration: Int = 2048

    /// Streaming vision request that supports Anthropic's native `tool_use`
    /// loop. Each time Claude emits tool calls, we execute them via the
    /// `executeToolCall` closure, feed the results back as `tool_result`
    /// blocks, and let Claude continue reasoning. The loop terminates when
    /// Claude produces a final text-only response (stop_reason == "end_turn")
    /// or when the iteration cap fires.
    ///
    /// `onTextChunk` receives the full accumulated text across every
    /// iteration, so the UI sees Claude's "thinking out loud" between
    /// tool calls as well as the final answer.
    func analyzeImageStreamingWithTools(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        availableTools: [ClaudeToolDefinition],
        executeToolCall: @MainActor @Sendable (ClaudeToolUseBlock) async -> ClaudeToolResultBlock,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        // Seed the conversation with the priors + the current user turn
        // (images + prompt). This array is appended to on every iteration:
        // assistant tool_use blocks + user tool_result blocks each round.
        var runningMessagesArray: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            runningMessagesArray.append(["role": "user", "content": userPlaceholder])
            runningMessagesArray.append(["role": "assistant", "content": assistantResponse])
        }

        var currentUserTurnContentBlocks: [[String: Any]] = []
        for image in images {
            currentUserTurnContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentUserTurnContentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        currentUserTurnContentBlocks.append(["type": "text", "text": userPrompt])
        runningMessagesArray.append([
            "role": "user",
            "content": currentUserTurnContentBlocks
        ])

        // Tools wire format expects snake_case keys.
        let toolsJSONArray: [[String: Any]] = availableTools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchemaJSON
            ]
        }

        // Accumulates EVERY text_delta across all iterations. The UI sees
        // Claude's between-tool-call narration as well as the final answer.
        var accumulatedFinalResponseText: String = ""

        for iterationIndex in 0..<Self.maximumToolUseIterationsForVisionTools {
            // Build + send the request for this iteration.
            let iterationRequestBody: [String: Any] = [
                "model": model,
                "max_tokens": Self.maxOutputTokensForToolStreamingIteration,
                "stream": true,
                "system": systemPrompt,
                "tools": toolsJSONArray,
                "messages": runningMessagesArray
            ]

            var iterationRequest = makeAPIRequest()
            let iterationBodyData = try JSONSerialization.data(
                withJSONObject: iterationRequestBody
            )
            iterationRequest.httpBody = iterationBodyData

            print(
                "🔧 Claude tool-streaming request (iteration \(iterationIndex + 1)/\(Self.maximumToolUseIterationsForVisionTools)): "
                + "tools=\(availableTools.count), messages=\(runningMessagesArray.count)"
            )

            let (iterationByteStream, iterationResponse) = try await session.bytes(
                for: iterationRequest
            )

            guard let iterationHTTPResponse = iterationResponse as? HTTPURLResponse else {
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                )
            }

            guard (200...299).contains(iterationHTTPResponse.statusCode) else {
                var errorBodyChunks: [String] = []
                for try await errorBodyLine in iterationByteStream.lines {
                    errorBodyChunks.append(errorBodyLine)
                }
                let errorBody = errorBodyChunks.joined(separator: "\n")
                throw NSError(
                    domain: "ClaudeAPI",
                    code: iterationHTTPResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "API Error (\(iterationHTTPResponse.statusCode)): \(errorBody)"]
                )
            }

            // Per-iteration state. Content blocks arrive interleaved (indexed
            // by `index` field). We track:
            //   - Per-index tool_use builders (accumulating input_json_delta).
            //   - Per-index text accumulators (the assistant content we replay).
            var inFlightToolUseBuildersByBlockIndex: [Int: InFlightToolUseBlockBuilder] = [:]
            var completedToolUseBlocks: [ClaudeToolUseBlock] = []
            var assistantContentBlocksForReplay: [[String: Any]] = []
            var assistantTextAccumulatorsByBlockIndex: [Int: String] = [:]
            var iterationStopReason: String?

            for try await sseLine in iterationByteStream.lines {
                guard sseLine.hasPrefix("data: ") else { continue }
                let eventJSONString = String(sseLine.dropFirst(6))
                guard eventJSONString != "[DONE]" else { break }

                guard let eventData = eventJSONString.data(using: .utf8),
                      let eventPayload = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                      let eventType = eventPayload["type"] as? String else {
                    continue
                }

                switch eventType {
                case "message_delta":
                    if let deltaPayload = eventPayload["delta"] as? [String: Any],
                       let stopReason = deltaPayload["stop_reason"] as? String {
                        iterationStopReason = stopReason
                    } else if let stopReason = eventPayload["stop_reason"] as? String {
                        iterationStopReason = stopReason
                    }

                case "content_block_start":
                    guard let blockIndex = eventPayload["index"] as? Int,
                          let contentBlock = eventPayload["content_block"] as? [String: Any],
                          let blockType = contentBlock["type"] as? String else {
                        continue
                    }
                    if blockType == "tool_use" {
                        let toolUseID = (contentBlock["id"] as? String) ?? ""
                        let toolName = (contentBlock["name"] as? String) ?? ""
                        inFlightToolUseBuildersByBlockIndex[blockIndex] = InFlightToolUseBlockBuilder(
                            id: toolUseID,
                            name: toolName
                        )
                    } else if blockType == "text" {
                        assistantTextAccumulatorsByBlockIndex[blockIndex] = ""
                    }

                case "content_block_delta":
                    guard let blockIndex = eventPayload["index"] as? Int,
                          let delta = eventPayload["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String else {
                        continue
                    }
                    if deltaType == "text_delta", let textChunk = delta["text"] as? String {
                        accumulatedFinalResponseText += textChunk
                        assistantTextAccumulatorsByBlockIndex[blockIndex, default: ""] += textChunk
                        let snapshotOfAccumulatedText = accumulatedFinalResponseText
                        await MainActor.run {
                            onTextChunk(snapshotOfAccumulatedText)
                        }
                    } else if deltaType == "input_json_delta",
                              let partialJSONChunk = delta["partial_json"] as? String {
                        inFlightToolUseBuildersByBlockIndex[blockIndex]?
                            .accumulatedInputJSONString.append(partialJSONChunk)
                    }

                case "content_block_stop":
                    guard let blockIndex = eventPayload["index"] as? Int else { continue }

                    // If this block was a tool_use, parse the assembled JSON
                    // and record it for execution after the stream finishes.
                    if var finishedToolUseBuilder = inFlightToolUseBuildersByBlockIndex[blockIndex] {
                        // Anthropic sends an empty string when the tool takes
                        // no input — treat that as an empty object.
                        if finishedToolUseBuilder.accumulatedInputJSONString.isEmpty {
                            finishedToolUseBuilder.accumulatedInputJSONString = "{}"
                        }
                        let parsedInputDict: [String: Any] = {
                            guard let inputJSONData = finishedToolUseBuilder.accumulatedInputJSONString
                                    .data(using: .utf8),
                                  let parsedDict = try? JSONSerialization.jsonObject(with: inputJSONData)
                                    as? [String: Any] else {
                                return [:]
                            }
                            return parsedDict
                        }()

                        completedToolUseBlocks.append(ClaudeToolUseBlock(
                            id: finishedToolUseBuilder.id,
                            name: finishedToolUseBuilder.name,
                            inputJSON: parsedInputDict
                        ))

                        // Record this block in the assistant message we'll
                        // replay on the next iteration.
                        assistantContentBlocksForReplay.append([
                            "type": "tool_use",
                            "id": finishedToolUseBuilder.id,
                            "name": finishedToolUseBuilder.name,
                            "input": parsedInputDict
                        ])

                        inFlightToolUseBuildersByBlockIndex.removeValue(forKey: blockIndex)
                    } else if let finishedTextSoFar = assistantTextAccumulatorsByBlockIndex[blockIndex] {
                        if !finishedTextSoFar.isEmpty {
                            assistantContentBlocksForReplay.append([
                                "type": "text",
                                "text": finishedTextSoFar
                            ])
                        }
                        assistantTextAccumulatorsByBlockIndex.removeValue(forKey: blockIndex)
                    }

                case "message_stop":
                    // End of this iteration's stream. The loop below decides
                    // whether to do another round.
                    break

                default:
                    continue
                }
            }

            // Decide whether to continue the tool-use loop.
            let didEmitToolCalls = !completedToolUseBlocks.isEmpty
            let isFinalIteration = iterationIndex == Self.maximumToolUseIterationsForVisionTools - 1

            if !didEmitToolCalls {
                // Model produced a plain text response — we're done.
                print(
                    "✅ Claude tool-streaming completed naturally at iteration \(iterationIndex + 1) "
                    + "(stop_reason=\(iterationStopReason ?? "unknown"))"
                )
                break
            }

            if isFinalIteration {
                // Budget exhausted. Don't execute the tools; the response
                // text we've streamed so far is what the user gets.
                print(
                    "⚠️ Claude tool-use budget exhausted after \(Self.maximumToolUseIterationsForVisionTools) iterations "
                    + "(stop_reason=\(iterationStopReason ?? "unknown"), pending_tool_calls=\(completedToolUseBlocks.count))"
                )
                break
            }

            // Record the assistant message (text + tool_use blocks) exactly
            // as Claude produced it. The next request must replay this so
            // Claude sees what it said and matches tool_result IDs.
            runningMessagesArray.append([
                "role": "assistant",
                "content": assistantContentBlocksForReplay
            ])

            // Execute each tool call. Results come back as tool_result blocks
            // in a single user message, in the same order Claude requested.
            var toolResultContentBlocks: [[String: Any]] = []
            for pendingToolUseBlock in completedToolUseBlocks {
                let executionResult = await executeToolCall(pendingToolUseBlock)

                // Build the tool_result payload. Anthropic accepts either a
                // plain string OR an array of text / image content blocks;
                // we use the array form whenever verification screenshots
                // are attached so Claude can SEE post-action screen state.
                let toolResultPayload: Any
                if executionResult.verificationImages.isEmpty {
                    toolResultPayload = executionResult.content
                } else {
                    var toolResultContentBlocks: [[String: Any]] = [[
                        "type": "text",
                        "text": executionResult.content
                    ]]

                    for verificationImage in executionResult.verificationImages {
                        toolResultContentBlocks.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": verificationImage.imageMediaType,
                                "data": verificationImage.imageData.base64EncodedString()
                            ]
                        ])
                    }

                    toolResultPayload = toolResultContentBlocks
                }

                toolResultContentBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": executionResult.toolUseID,
                    "content": toolResultPayload,
                    "is_error": executionResult.isError
                ])
            }
            runningMessagesArray.append([
                "role": "user",
                "content": toolResultContentBlocks
            ])
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        return (text: accumulatedFinalResponseText, duration: totalDuration)
    }

    // MARK: - Computer Use Agent Loop

    private static let computerUseBetaHeader = "computer-use-2025-11-24"
    private static let computerUseToolVersion = "computer_20251124"
    private static let maximumComputerUseIterations = 15
    private static let computerUseStuckActionThreshold = 3

    /// Details of a deny-list refusal that ended a Computer Use loop. Set
    /// on `ComputerUseAgentLoopResult.refusal` when the action executor
    /// refuses an action because the frontmost app is on the safety
    /// deny-list. The caller uses this to (a) surface a bundle-specific
    /// status line, (b) emit the `run_refused` JSONL event with the
    /// blocked bundle id + iteration count, and (c) return a specific
    /// tool-result string to Claude so it doesn't retry.
    struct ComputerUseRefusal {
        let blockedBundleIdentifier: String
        let iterationsAtRefusal: Int
    }

    /// Result envelope for a finished Computer Use agent loop. `refusal`
    /// is `nil` for normal completions (end_turn, halt, iteration cap,
    /// stuck-detection pause) and populated only when the executor's
    /// deny-list check fired.
    struct ComputerUseAgentLoopResult {
        let responseText: String
        let iterationsUsed: Int
        let refusal: ComputerUseRefusal?
    }

    /// Runs a Computer Use agent loop: sends a task prompt + initial
    /// screenshot to Claude with the `computer_20251124` tool, executes
    /// each action locally via `actionExecutor`, feeds screenshots back,
    /// and repeats until Claude declares the task done, the iteration
    /// cap fires, or the action executor refuses an action because the
    /// frontmost app is on the safety deny-list. On refusal the loop
    /// breaks on first hit — the deny-list is a protected-apps guard,
    /// not a transient failure, so retrying is never the right answer.
    /// Token usage from each response is folded into `runMetrics` so the
    /// caller can emit cache-aware telemetry on completion.
    func runComputerUseAgentLoop(
        taskDescription: String,
        systemPrompt: String,
        initialScreenshotBase64: String,
        initialScreenshotMediaType: String,
        displayWidthPixels: Int,
        displayHeightPixels: Int,
        displayNumber: Int,
        runMetrics: ComputerUseRunMetrics,
        actionExecutor: ComputerUseActionExecutor,
        isHaltRequested: @MainActor () -> Bool,
        onStatusUpdate: @MainActor (String) -> Void
    ) async throws -> ComputerUseAgentLoopResult {

        var messagesArray: [[String: Any]] = []

        messagesArray.append([
            "role": "user",
            "content": [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": initialScreenshotMediaType,
                        "data": initialScreenshotBase64
                    ]
                ],
                ["type": "text", "text": taskDescription]
            ]
        ])

        let computerUseTool: [String: Any] = [
            "type": Self.computerUseToolVersion,
            "name": "computer",
            "display_width_px": displayWidthPixels,
            "display_height_px": displayHeightPixels,
            "display_number": displayNumber
        ]

        var accumulatedSpokenText = ""
        var iterationsUsed = 0
        /// Set once the action executor refuses an action because the
        /// frontmost app is on the safety deny-list. We break immediately
        /// on first hit (see the tool-execution loop below) and surface
        /// the refusal to the caller via the return envelope so it can
        /// emit the bundle-specific JSONL event and tool result.
        var capturedRefusal: ComputerUseRefusal?

        for iterationIndex in 0..<Self.maximumComputerUseIterations {
            if await MainActor.run { isHaltRequested() } {
                accumulatedSpokenText += " [halted by user]"
                break
            }

            let requestBody: [String: Any] = [
                "model": model,
                "max_tokens": 4096,
                "system": systemPrompt,
                "tools": [computerUseTool],
                "messages": messagesArray
            ]

            var request = makeComputerUseAPIRequest()
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            print("🖥️ Computer Use iteration \(iterationIndex + 1)/\(Self.maximumComputerUseIterations)")
            iterationsUsed = iterationIndex + 1
            let statusLine = "Computer Use step \(iterationIndex + 1)/\(Self.maximumComputerUseIterations)"
            await MainActor.run {
                onStatusUpdate(statusLine)
            }

            let (responseData, httpResponse) = try await session.data(for: request)

            guard let httpURLResponse = httpResponse as? HTTPURLResponse,
                  (200...299).contains(httpURLResponse.statusCode) else {
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? -1
                let errorBody = String(data: responseData, encoding: .utf8) ?? "unknown error"
                throw NSError(
                    domain: "ClaudeAPI.ComputerUse",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Computer Use API error (\(statusCode)): \(errorBody)"]
                )
            }

            guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let contentBlocks = responseJSON["content"] as? [[String: Any]] else {
                throw NSError(
                    domain: "ClaudeAPI.ComputerUse",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to parse Computer Use response"]
                )
            }

            // Fold Anthropic's `usage` block into the run metrics so the
            // caller's `run_completed` / `run_refused` event gets the
            // three input-token buckets (uncached / cache_read / cache_creation)
            // plus output_tokens without the caller having to parse the
            // raw response itself.
            runMetrics.addUsageFromResponseJSON(usageDict: responseJSON["usage"] as? [String: Any])

            let stopReason = (responseJSON["stop_reason"] as? String) ?? ""

            // Accumulate text blocks and collect tool_use blocks.
            var toolUseBlocks: [[String: Any]] = []
            var assistantContentForReplay: [[String: Any]] = []

            for block in contentBlocks {
                let blockType = (block["type"] as? String) ?? ""
                if blockType == "text", let text = block["text"] as? String {
                    accumulatedSpokenText += text
                }
                assistantContentForReplay.append(block)
                if blockType == "tool_use" {
                    toolUseBlocks.append(block)
                }
            }

            messagesArray.append([
                "role": "assistant",
                "content": assistantContentForReplay
            ])

            if toolUseBlocks.isEmpty || stopReason == "end_turn" {
                break
            }

            // Execute each tool call and collect results.
            var toolResultBlocks: [[String: Any]] = []
            for toolBlock in toolUseBlocks {
                let toolUseID = (toolBlock["id"] as? String) ?? ""
                let inputDict = (toolBlock["input"] as? [String: Any]) ?? [:]

                if await MainActor.run { isHaltRequested() } {
                    toolResultBlocks.append([
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "content": "halted by user",
                        "is_error": true
                    ])
                    break
                }

                let result = await actionExecutor.executeAction(actionDict: inputDict)

                // Deny-list hit: capture the bundle id + iteration count
                // for the caller and stop sending more actions. We still
                // produce a tool_result block so Claude has a transcript
                // of why it stopped, but we break the loop after this
                // iteration's tool_result is appended. Retrying a
                // protected app is never the right answer — if the user
                // wanted that, they'd whitelist it.
                if result.wasBlockedByDenyList, capturedRefusal == nil {
                    let blockedBundleIdentifier = result.blockedBundleIdentifier ?? ""
                    capturedRefusal = ComputerUseRefusal(
                        blockedBundleIdentifier: blockedBundleIdentifier,
                        iterationsAtRefusal: iterationsUsed
                    )
                    let protectedAppStatusLine = "cannot automate \(blockedBundleIdentifier) — protected app"
                    await MainActor.run {
                        onStatusUpdate(protectedAppStatusLine)
                    }
                }

                var toolResultContent: Any
                if let screenshotBase64 = result.screenshotBase64 {
                    toolResultContent = [
                        ["type": "text", "text": result.resultText],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": result.screenshotMediaType,
                                "data": screenshotBase64
                            ]
                        ]
                    ] as [[String: Any]]
                } else {
                    toolResultContent = result.resultText
                }

                toolResultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolUseID,
                    "content": toolResultContent,
                    "is_error": result.isError
                ])

                // Break out of the per-iteration tool loop on refusal so
                // we don't execute sibling tool_use blocks from the same
                // response against a protected app.
                if capturedRefusal != nil {
                    break
                }
            }

            messagesArray.append([
                "role": "user",
                "content": toolResultBlocks
            ])

            // Refusal ends the agent loop on first hit. See the plan:
            // two-consecutive-refusals is a retry pattern that's never
            // the right answer. Drop out before we round-trip another
            // request to Claude.
            if capturedRefusal != nil {
                break
            }

            if runMetrics.consecutiveActionsWithoutMeaningfulScreenChange >= Self.computerUseStuckActionThreshold {
                accumulatedSpokenText += " [automation paused: the screen did not meaningfully update after several actions — try a different approach or ask the user to click the intended control]"
                break
            }
        }

        let trimmed = accumulatedSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ComputerUseAgentLoopResult(
            responseText: trimmed,
            iterationsUsed: iterationsUsed,
            refusal: capturedRefusal
        )
    }

    private func makeComputerUseAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.computerUseBetaHeader, forHTTPHeaderField: "anthropic-beta")
        return request
    }
}
