//
//  CompanionToolRegistry.swift
//  claude-cursor
//
//  Central registry of tools that Claude can call during a voice turn.
//  Wraps every existing app subsystem (wiki retrieval, cursor pointing,
//  answer panel, clipboard copy, YouTube lessons, automation) behind a
//  JSON-schema surface so the model picks what to run per-question
//  instead of the user pre-toggling hard-off switches.
//
//  The registry is *stateless* except for one per-turn field:
//  `currentTurnScreenCaptures`. Voice pipeline sets it at the start of
//  each turn so `point_at_element` can resolve screenshot-pixel
//  coordinates against the right display. Reset after the turn ends.
//

import Foundation
import AppKit

@MainActor
final class CompanionToolRegistry {

    private weak var companionManager: CompanionManager?

    /// Screenshots captured at the start of the current voice turn.
    /// The `point_at_element` tool needs these to convert Claude's
    /// screenshot-pixel coordinates into a real on-screen location
    /// (see `CompanionManager.buildPointingTarget`). The voice pipeline
    /// assigns this before the tool loop begins and clears it after.
    var currentTurnScreenCaptures: [CompanionScreenCapture] = []

    /// Accumulated text Claude has generated so far in the current
    /// response. Some tools (`copy_response_to_clipboard`) default to
    /// this when the model doesn't pass explicit `text`. Set by the
    /// voice pipeline via `onTextChunk`.
    var accumulatedResponseTextSoFar: String = ""

    /// Pointing targets accumulated during the current turn via the
    /// `point_at_element` tool. Batched into
    /// `CompanionManager.activePointingTargets` at the end of the turn
    /// so the overlay sees one SwiftUI animation frame per turn, not
    /// per tool call.
    private var pointingTargetsAccumulatedThisTurn: [CompanionManager.PointingTarget] = []
    /// Upper bound for waiting on forward cursor flight completion.
    private let pointingFlightArrivalTimeoutNanoseconds: UInt64 = 1_800_000_000

    /// True while the body of `executeStartAutomationSequence` is
    /// executing (entry to exit, spanning consent + run). Catches the
    /// pathological case of two `start_automation_sequence` tool calls
    /// dispatched concurrently from the same Claude turn — Swift's
    /// `@MainActor` serialization should make this impossible in normal
    /// flow, so entry while already true is treated as a bug with
    /// `assertionFailure` in debug and a graceful reply in release.
    private var isAutomationToolCallInFlight = false

    /// True while the Computer Use agent loop is actually running (i.e.
    /// between the consent acceptance and the loop returning). A new
    /// automation tool call that lands in this window is the realistic
    /// "task B while task A loop is live" case — we reject it with a
    /// user-actionable status line rather than cancelling task A.
    private var isComputerUseAgentLoopRunning = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Turn Lifecycle

    /// Called at the start of each voice turn. Captures the screenshots
    /// the tools need and resets per-turn accumulators.
    func beginTurn(withScreenCaptures turnScreenCaptures: [CompanionScreenCapture]) {
        currentTurnScreenCaptures = turnScreenCaptures
        accumulatedResponseTextSoFar = ""
        pointingTargetsAccumulatedThisTurn.removeAll()
    }

    /// Called when the voice pipeline finishes streaming the response.
    /// Flushes accumulated pointing targets into CompanionManager and
    /// clears per-turn state.
    func endTurn() {
        guard let companionManager else { return }

        if pointingTargetsAccumulatedThisTurn.isEmpty {
            companionManager.activePointingTargets.removeAll()
        } else {
            companionManager.activePointingTargets = pointingTargetsAccumulatedThisTurn
        }

        currentTurnScreenCaptures = []
        accumulatedResponseTextSoFar = ""
        pointingTargetsAccumulatedThisTurn.removeAll()
    }

    /// True if `point_at_element` was called at least once during the
    /// current turn. Read by the voice pipeline after
    /// `analyzeImageStreamingWithTools` returns so the adaptive output
    /// router can classify the turn as `.navigation` without re-parsing
    /// legacy `[POINT:...]` tags out of the response text.
    var didPointingToolFireInCurrentTurn: Bool {
        !pointingTargetsAccumulatedThisTurn.isEmpty
    }

    // MARK: - Registry API

    /// Returns the tool set Claude can pick from for the current turn.
    /// A toggle being OFF removes the tool entirely — it's a hard gate.
    /// The user's "Wiki Knowledge" switch still works as they expect;
    /// we just removed the toggle gate on tools the user has always
    /// wanted available (cursor pointing, answer panel, clipboard).
    func availableToolsForCurrentTurn() -> [ClaudeToolDefinition] {
        guard let companionManager else { return [] }

        var tools: [ClaudeToolDefinition] = [
            pointAtElementToolDefinition(),
            explainScreenElementsToolDefinition(),
            openAnswerPanelToolDefinition(),
            copyResponseToClipboardToolDefinition(),
        ]

        // Only expose the YouTube lesson tool when the user has entered a
        // tutorial URL or a lesson is already active. This prevents Claude
        // from promising to "pull up a video" on vague tutorial-style
        // questions when no lesson infrastructure is ready.
        let hasExplicitTutorialURL = !companionManager.followAlongTutorialURL
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasExplicitTutorialURL || companionManager.lessonStateMachine.currentMode == .lesson {
            tools.append(startYouTubeLessonToolDefinition())
        }

        if companionManager.isWikiKnowledgeEnabled {
            tools.append(queryWikiToolDefinition())
            tools.append(researchTopicToolDefinition())
        }

        // Automation is available when the experimental flag is on OR when
        // tutor mode is enabled (the consent prompt is the safety gate).
        if companionManager.isAutomationExperimentalEnabled || companionManager.isTutorModeEnabled {
            tools.append(startAutomationSequenceToolDefinition())
        }

        return tools
    }

    /// Dispatches a `tool_use` block to the corresponding subsystem
    /// wrapper. Called by `ClaudeAPI.analyzeImageStreamingWithTools`
    /// once for every tool call Claude emits. The returned
    /// `ClaudeToolResultBlock` becomes a `tool_result` content block
    /// on the next request, so Claude reads the result back.
    func executeToolCall(
        _ toolUseBlock: ClaudeToolUseBlock
    ) async -> ClaudeToolResultBlock {
        guard let companionManager else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "companion unavailable",
                isError: true
            )
        }

        switch toolUseBlock.name {
        case "query_wiki":
            return executeQueryWiki(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        case "research_topic":
            return await executeResearchTopic(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        case "point_at_element":
            return await executePointAtElement(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        case "open_answer_panel":
            return executeOpenAnswerPanel(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        case "copy_response_to_clipboard":
            return executeCopyResponseToClipboard(toolUseBlock: toolUseBlock)
        case "start_youtube_lesson":
            return await executeStartYouTubeLesson(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        case "start_automation_sequence":
            return await executeStartAutomationSequence(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        case "explain_screen_elements":
            return await executeExplainScreenElements(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager
            )
        default:
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "unknown tool: \(toolUseBlock.name)",
                isError: true
            )
        }
    }

    // MARK: - Tool Definitions

    private func queryWikiToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "query_wiki",
            description: """
            Look up the user's personal wiki for context on a topic before \
            answering. Use this when the question touches software, \
            workflows, or topics the user has worked on before. Returns a \
            packed context bundle you can read back in your response. \
            Example: query_wiki({keywords: ["UV unwrapping", "Blender"]}).
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "keywords": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "2-4 short keywords describing the topic."
                    ],
                    "max_characters": [
                        "type": "integer",
                        "description": "Max size of the returned bundle. Default 4000."
                    ]
                ],
                "required": ["keywords"]
            ]
        )
    }

    private func researchTopicToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "research_topic",
            description: """
            Fetch and index new documentation for a topic the user's wiki \
            does not already cover. Runs a curated-docs-first search (DaVinci \
            Resolve, Figma, VS Code, plus anything else configured in the \
            user's doc-sources.json) and falls back to Tavily web search. \
            Writes results into the user's wiki so future query_wiki calls \
            can cite them. Use when: (1) query_wiki returned no relevant \
            pages, OR (2) the user explicitly says "research X" / "look up \
            X" / "learn about X in <app>". May take 15–30 seconds — only \
            call when the extra grounding is worth the wait. Call at most \
            once per turn.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "topic": [
                        "type": "string",
                        "description": "The topic to research. Short phrase, e.g. 'DaVinci Resolve color grading', 'Figma auto layout constraints'."
                    ]
                ],
                "required": ["topic"]
            ]
        )
    }

    func pointAtElementToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "point_at_element",
            description: """
            Place a blue cursor + label pill on screen at the given \
            coordinates so the user can see exactly what you're pointing \
            at. Call MULTIPLE TIMES in one response to point at multiple \
            elements simultaneously — e.g., if you're describing a two-step \
            navigation, point at both steps. Coordinates are in screenshot \
            pixel space (see the image you were given). screen_number is \
            1-indexed and matches the screen label in the provided \
            screenshots.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "Screenshot-space X (pixels)."],
                    "y": ["type": "number", "description": "Screenshot-space Y (pixels)."],
                    "label": [
                        "type": "string",
                        "description": "Short label shown beside the cursor (e.g. 'Export')."
                    ],
                    "screen_number": [
                        "type": "integer",
                        "description": "1-indexed screen number. Defaults to the cursor screen."
                    ]
                ],
                "required": ["x", "y", "label"]
            ]
        )
    }

    private func explainScreenElementsToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "explain_screen_elements",
            description: """
            Deploy multiple colored cursors simultaneously to explain \
            several UI elements on screen at once. Use when the user \
            asks "how does this work?", "walk me through this", or \
            "what am I looking at?" — any question where pointing at \
            one thing isn't enough and an overview of the interface is \
            more helpful. Each element gets its own colored cursor with \
            a label. Order by priority: critical elements first. \
            Max 8 elements per call. Put your 1-3 sentence spoken overview \
            in `spoken_overview` — it is read aloud as soon as the cursors \
            appear. Your final assistant message after the tool should add \
            at most a short closing line if needed; do not repeat the same overview.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "spoken_overview": [
                        "type": "string",
                        "description": "1-3 sentences read aloud via TTS the moment the multi-cursor overlay appears. Write for the ear; no markdown."
                    ],
                    "elements": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "x": ["type": "number",
                                       "description": "Screenshot-space X (pixels)."],
                                "y": ["type": "number",
                                       "description": "Screenshot-space Y (pixels)."],
                                "label": ["type": "string",
                                           "description": "1-3 word element name."],
                                "description": ["type": "string",
                                                 "description": "1 sentence explaining what it does."],
                                "priority": ["type": "string",
                                              "enum": ["critical", "important", "helpful"],
                                              "description": "Visual importance: critical (red/orange), important (blue/purple), helpful (green/teal)."],
                                "screen_number": ["type": "integer",
                                                   "description": "1-indexed screen number. Defaults to cursor screen."]
                            ],
                            "required": ["x", "y", "label", "description", "priority"]
                        ],
                        "maxItems": 8
                    ]
                ],
                "required": ["spoken_overview", "elements"]
            ]
        )
    }

    private func openAnswerPanelToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "open_answer_panel",
            description: """
            Render a long-form response in the docked answer panel with \
            markdown + LaTeX + syntax-highlighted code. Use this for math \
            problems, multi-paragraph explanations, or anything with fenced \
            code blocks. Do NOT use for short conversational replies — \
            those should be spoken directly.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "content": [
                        "type": "string",
                        "description": "Full markdown content. Use $$...$$ for display math."
                    ]
                ],
                "required": ["content"]
            ]
        )
    }

    private func copyResponseToClipboardToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "copy_response_to_clipboard",
            description: """
            Copy text to the user's clipboard. Use when the user explicitly \
            asks 'copy this' or 'paste it into X' — don't auto-copy every \
            response. If `text` is omitted, the current streamed response \
            is used.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "Text to copy. Omit to copy the current response."
                    ]
                ]
            ]
        )
    }

    private func startYouTubeLessonToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "start_youtube_lesson",
            description: """
            Turn a YouTube tutorial URL into a step-by-step interactive \
            lesson with a floating step banner and picture-in-picture video. \
            Use when the user shares a YouTube URL and asks to be walked \
            through it.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "video_url": [
                        "type": "string",
                        "description": "Full YouTube URL (any standard shape)."
                    ]
                ],
                "required": ["video_url"]
            ]
        )
    }

    private func startAutomationSequenceToolDefinition() -> ClaudeToolDefinition {
        ClaudeToolDefinition(
            name: "start_automation_sequence",
            description: """
            Drive the user's mouse and keyboard through a sequence of \
            clicks and text inputs. Requires user consent via a prompt — \
            if they deny, the sequence is skipped. Only use when the user \
            explicitly asks 'do X for me' or approves a suggestion. NEVER \
            use for credentials, Terminal, or System Settings — those are \
            auto-blocked. Step coordinates are in screenshot pixel space.
            """,
            inputSchemaJSON: [
                "type": "object",
                "properties": [
                    "description": [
                        "type": "string",
                        "description": "One-sentence human description (shown on consent prompt)."
                    ],
                    "steps": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": ["type": "string"],
                                "x": ["type": "number"],
                                "y": ["type": "number"],
                                "type_text": [
                                    "type": "string",
                                    "description": "Optional text to type after the click."
                                ],
                                "screen_number": ["type": "integer"]
                            ],
                            "required": ["label", "x", "y"]
                        ]
                    ]
                ],
                "required": ["description", "steps"]
            ]
        )
    }

    // MARK: - Tool Executors

    private func executeQueryWiki(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) -> ClaudeToolResultBlock {
        let keywords = (toolUseBlock.inputJSON["keywords"] as? [String]) ?? []
        let maxCharacters = (toolUseBlock.inputJSON["max_characters"] as? Int) ?? 4000

        guard !keywords.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no keywords provided",
                isError: true
            )
        }

        let queryResult = companionManager.wikiQueryEngine.buildContextBundle(
            forTopicKeywords: keywords,
            maxCharacters: maxCharacters
        )

        if queryResult.contextBundle.isEmpty {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no wiki matches for: \(keywords.joined(separator: ", "))",
                isError: false
            )
        }

        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: queryResult.contextBundle,
            isError: false
        )
    }

    /// Runs the research ingest pipeline for a freeform topic. Waits for
    /// `ingestTopic` to finish so Claude's summary reply reflects what
    /// actually landed on disk, but kicks off the raw→pages compression in
    /// a detached Task so the tool returns promptly. Because compression
    /// runs async, a follow-up `query_wiki` call in the SAME turn may still
    /// miss the freshly-added page — the system prompt tells Claude to
    /// acknowledge the ingest rather than try to cite it inline.
    private func executeResearchTopic(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) async -> ClaudeToolResultBlock {
        let topicRaw = (toolUseBlock.inputJSON["topic"] as? String) ?? ""
        let topic = topicRaw.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "research_topic requires a non-empty 'topic' string.",
                isError: true
            )
        }

        do {
            let ingestedSources = try await companionManager
                .autoResearchPipeline.ingestTopic(topic)

            // Fire-and-forget compression so this tool call doesn't block
            // Claude for an additional ~5s. The raw sources are already on
            // disk under raw/sources/; the compressor updates the index in
            // the background, which query_wiki reads on subsequent turns.
            Task { [weak companionManager] in
                guard let companionManager else { return }
                await companionManager.researchSourceCompressor
                    .compressResearchSourcesIntoWikiPage(
                        forTopic: topic,
                        ingestedRawSources: ingestedSources
                    )
            }

            let summary = buildResearchToolResultSummary(
                topic: topic,
                ingestedSources: ingestedSources
            )
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: summary,
                isError: false
            )
        } catch {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "research_topic failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    /// Composes the short text summary that Claude reads back after a
    /// `research_topic` call finishes. Separates curated-docs hits from
    /// Tavily fallback hits and lists titles + URLs so Claude can cite
    /// provenance if the user asks.
    private func buildResearchToolResultSummary(
        topic: String,
        ingestedSources: [IngestedRawSource]
    ) -> String {
        guard !ingestedSources.isEmpty else {
            return "No sources could be ingested for '\(topic)'. The pipeline ran but produced no useful content — the topic may not match the user's curated doc-sources.json and web search turned up nothing fetchable."
        }

        let curatedHitCount = ingestedSources.filter {
            $0.sourceOrigin == .curatedDocumentationSource
        }.count
        let tavilyHitCount = ingestedSources.filter {
            $0.sourceOrigin == .tavilyWebSearchFallback
        }.count

        var originBreakdownParts: [String] = []
        if curatedHitCount > 0 {
            originBreakdownParts.append("\(curatedHitCount) from curated docs")
        }
        if tavilyHitCount > 0 {
            originBreakdownParts.append("\(tavilyHitCount) from web")
        }
        let originBreakdown = originBreakdownParts.isEmpty
            ? ""
            : " (\(originBreakdownParts.joined(separator: ", ")))"

        let sourceListLines = ingestedSources.map { source in
            "- \(source.sourceTitle) — \(source.sourceURL)"
        }.joined(separator: "\n")

        return """
        Ingested \(ingestedSources.count) source\(ingestedSources.count == 1 ? "" : "s") for '\(topic)'\(originBreakdown). The wiki page is being written in the background — it will be queryable on the next turn via query_wiki. Do NOT try to cite specifics from these sources in your current reply; just acknowledge that the material was pulled in.

        Sources:
        \(sourceListLines)
        """
    }

    private func executePointAtElement(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) async -> ClaudeToolResultBlock {
        let xInScreenshotPixels = (toolUseBlock.inputJSON["x"] as? Double)
            ?? Double(toolUseBlock.inputJSON["x"] as? Int ?? 0)
        let yInScreenshotPixels = (toolUseBlock.inputJSON["y"] as? Double)
            ?? Double(toolUseBlock.inputJSON["y"] as? Int ?? 0)
        let labelText = (toolUseBlock.inputJSON["label"] as? String) ?? ""
        let screenNumber = toolUseBlock.inputJSON["screen_number"] as? Int

        guard !currentTurnScreenCaptures.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no screenshots available to resolve coordinates",
                isError: true
            )
        }

        let pointingMatch = CompanionManager.PointingMatch(
            coordinate: CGPoint(x: xInScreenshotPixels, y: yInScreenshotPixels),
            elementLabel: labelText,
            screenNumber: screenNumber
        )

        guard let resolvedPointingTarget = CompanionManager.buildPointingTarget(
            fromMatch: pointingMatch,
            availableScreenCaptures: currentTurnScreenCaptures
        ) else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "couldn't resolve coordinate to a screen location",
                isError: true
            )
        }

        if Self.resolvedPointingTargetIsRedundantDuplicate(
            resolvedPointingTarget,
            ofAnyExistingIn: pointingTargetsAccumulatedThisTurn
        ) {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "duplicate point_at_element ignored (same label near an existing target)",
                isError: false
            )
        }

        let pointingArrivalWaitID = companionManager.beginAwaitingPrimaryPointingForwardArrival()
        pointingTargetsAccumulatedThisTurn.append(resolvedPointingTarget)

        // Publish immediately so the user sees the cursor fly to the
        // target mid-response — not after the whole turn finishes.
        companionManager.activePointingTargets = pointingTargetsAccumulatedThisTurn

        ClaudeCursorAnalytics.trackElementPointed(elementLabel: labelText)

        let didCursorFlightArrive = await companionManager.waitForPrimaryPointingForwardArrival(
            waitID: pointingArrivalWaitID,
            timeoutNanoseconds: pointingFlightArrivalTimeoutNanoseconds
        )
        let verificationCaptures = await captureScreensForVerification()
        let verificationSummary = verificationSummaryText(from: verificationCaptures)
        let arrivalSummary = didCursorFlightArrive
            ? "cursor flight reached the target before capture."
            : "verification capture timed out waiting for cursor arrival; screenshot may be slightly early."

        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: "pointed at \(labelText). \(arrivalSummary) \(verificationSummary)",
            isError: false,
            verificationImages: verificationImageBlocks(from: verificationCaptures)
        )
    }

    private func executeExplainScreenElements(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) async -> ClaudeToolResultBlock {
        guard let elementsArray = toolUseBlock.inputJSON["elements"] as? [[String: Any]],
              !elementsArray.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no elements provided",
                isError: true
            )
        }

        guard !currentTurnScreenCaptures.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no screenshots available to resolve coordinates",
                isError: true
            )
        }

        // Parse elements, resolve coordinates, and assign colors by priority.
        var resolvedElements: [CompanionManager.ExplainerElement] = []
        // Track how many elements per priority tier for color cycling.
        var colorCounterByPriority: [CompanionManager.ExplainerPriority: Int] = [:]

        for elementDict in elementsArray.prefix(8) {
            let xPixels = (elementDict["x"] as? Double)
                ?? Double(elementDict["x"] as? Int ?? 0)
            let yPixels = (elementDict["y"] as? Double)
                ?? Double(elementDict["y"] as? Int ?? 0)
            let labelText = (elementDict["label"] as? String) ?? ""
            let descriptionText = (elementDict["description"] as? String) ?? ""
            let priorityString = (elementDict["priority"] as? String) ?? "helpful"
            let screenNumber = elementDict["screen_number"] as? Int

            let priority = CompanionManager.ExplainerPriority.fromString(priorityString)

            let pointingMatch = CompanionManager.PointingMatch(
                coordinate: CGPoint(x: xPixels, y: yPixels),
                elementLabel: labelText,
                screenNumber: screenNumber
            )

            guard let resolvedTarget = CompanionManager.buildPointingTarget(
                fromMatch: pointingMatch,
                availableScreenCaptures: currentTurnScreenCaptures
            ) else { continue }

            // Pick a color from the priority tier, cycling within the tier's palette.
            let tierIndex = colorCounterByPriority[priority, default: 0]
            let colorIndices = priority.colorIndices
            let colorIndex = colorIndices[tierIndex % colorIndices.count]
            let assignedColor = DS.Colors.explainerCursorColors[colorIndex]
            colorCounterByPriority[priority] = tierIndex + 1

            resolvedElements.append(CompanionManager.ExplainerElement(
                screenLocation: resolvedTarget.screenLocation,
                displayFrame: resolvedTarget.displayFrame,
                labelText: labelText,
                descriptionText: descriptionText,
                priority: priority,
                assignedColor: assignedColor
            ))
        }

        guard !resolvedElements.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no elements could be resolved to screen locations",
                isError: true
            )
        }

        // Sort by priority (critical first) for stagger ordering.
        resolvedElements.sort { $0.priority > $1.priority }

        let spokenOverview = (toolUseBlock.inputJSON["spoken_overview"] as? String) ?? ""

        let group = CompanionManager.ExplainerCursorGroup(
            elements: resolvedElements,
            spokenOverview: spokenOverview,
            createdAt: Date()
        )
        companionManager.publishExplainerCursorGroup(group)

        let verificationCaptures = await captureScreensForVerification()
        let verificationSummary = verificationSummaryText(from: verificationCaptures)

        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: "explained \(resolvedElements.count) elements on screen. \(verificationSummary)",
            isError: false,
            verificationImages: verificationImageBlocks(from: verificationCaptures)
        )
    }

    private func executeOpenAnswerPanel(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) -> ClaudeToolResultBlock {
        let markdownContent = (toolUseBlock.inputJSON["content"] as? String) ?? ""

        guard !markdownContent.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no content provided",
                isError: true
            )
        }

        companionManager.answerPanelController.showAnswerPanel(
            withResponseText: markdownContent
        )

        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: "answer panel opened",
            isError: false
        )
    }

    private func executeCopyResponseToClipboard(
        toolUseBlock: ClaudeToolUseBlock
    ) -> ClaudeToolResultBlock {
        let explicitText = toolUseBlock.inputJSON["text"] as? String
        let textToCopy = (explicitText?.isEmpty == false)
            ? explicitText!
            : accumulatedResponseTextSoFar

        guard !textToCopy.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "nothing to copy",
                isError: true
            )
        }

        _ = ClipboardManager.copyResponseToClipboard(rawResponseText: textToCopy)
        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: "copied to clipboard",
            isError: false
        )
    }

    private func executeStartYouTubeLesson(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) async -> ClaudeToolResultBlock {
        let rawVideoURLString = (toolUseBlock.inputJSON["video_url"] as? String) ?? ""

        guard !rawVideoURLString.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no video URL provided",
                isError: true
            )
        }

        // `startFollowAlongTutorial` reads from the published URL field
        // (the menu-bar panel drives it the same way), so set it first.
        companionManager.followAlongTutorialURL = rawVideoURLString
        companionManager.startFollowAlongTutorial()

        // Give the lesson overlay a beat to materialize before capturing
        // the verification screenshot. 700ms is enough for the SwiftUI
        // hosting view fade-in plus the first step banner to appear.
        try? await Task.sleep(nanoseconds: 700_000_000)

        let verificationCaptures = await captureScreensForVerification()
        let verificationSummary = verificationSummaryText(from: verificationCaptures)

        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: "started lesson for \(rawVideoURLString). \(verificationSummary)",
            isError: false,
            verificationImages: verificationImageBlocks(from: verificationCaptures)
        )
    }

    private func executeStartAutomationSequence(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager
    ) async -> ClaudeToolResultBlock {
        // Task-B-mid-loop: a new utterance fires a new automation tool
        // call while the prior Computer Use loop is still executing. Don't
        // queue (surprising), don't cancel the live loop (surprising) —
        // let the user drive: wait for it to finish, or press Escape.
        if isComputerUseAgentLoopRunning {
            companionManager.computerUseAutomationStatusLine = "Automation in progress — wait or press Escape to halt"
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "Automation is already in progress. Wait for it to finish, or press Escape to halt the current run.",
                isError: false
            )
        }

        // Dispatch-level concurrency: should be unreachable under Swift's
        // @MainActor serialization. If it fires, the tool dispatcher has
        // a bug (likely parallel Task dispatch for a single Claude turn).
        if isAutomationToolCallInFlight {
            assertionFailure("Automation tool call dispatched while another was already in-flight — check tool call dispatch ordering in the main handler")
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "Automation already in progress for another task. This new request was ignored.",
                isError: false
            )
        }

        isAutomationToolCallInFlight = true
        defer { isAutomationToolCallInFlight = false }

        let sequenceDescription = (toolUseBlock.inputJSON["description"] as? String) ?? ""
        let rawStepDicts = (toolUseBlock.inputJSON["steps"] as? [[String: Any]]) ?? []

        guard !rawStepDicts.isEmpty else {
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "no steps provided",
                isError: true
            )
        }

        // Automation is gated behind the same opt-ins either way: Auto-click
        // (experimental) or Tutor mode, plus the per-sequence consent pill.
        // Computer Use is now the default path — one-shot CGEvent dispatch
        // only runs when `preferOneShotAutomationForDebugging` is flipped via
        // the hidden debug submenu. The one-shot path is kept as a reachable
        // escape hatch in case the Computer Use beta has an outage.
        let automationEligible = companionManager.isAutomationExperimentalEnabled
            || companionManager.isTutorModeEnabled
        if automationEligible, !companionManager.preferOneShotAutomationForDebugging {
            return await executeAutomationViaComputerUseAPI(
                toolUseBlock: toolUseBlock,
                companionManager: companionManager,
                sequenceDescription: sequenceDescription,
                rawStepDicts: rawStepDicts
            )
        }

        // One-shot CGEvent path: map each step's screenshot-pixel coord
        // to global AppKit space via the shared pointing-target math.
        var resolvedAutomationSteps: [AutomationStep] = []
        for stepDict in rawStepDicts {
            let stepLabel = (stepDict["label"] as? String) ?? ""
            let stepX = (stepDict["x"] as? Double) ?? Double(stepDict["x"] as? Int ?? 0)
            let stepY = (stepDict["y"] as? Double) ?? Double(stepDict["y"] as? Int ?? 0)
            let stepTextToType = stepDict["type_text"] as? String
            let stepScreenNumber = stepDict["screen_number"] as? Int

            let pointingMatch = CompanionManager.PointingMatch(
                coordinate: CGPoint(x: stepX, y: stepY),
                elementLabel: stepLabel,
                screenNumber: stepScreenNumber
            )
            let resolvedGlobalCoord = CompanionManager.buildPointingTarget(
                fromMatch: pointingMatch,
                availableScreenCaptures: currentTurnScreenCaptures
            )?.screenLocation

            resolvedAutomationSteps.append(AutomationStep(
                humanReadableLabel: stepLabel,
                screenCoordinate: resolvedGlobalCoord,
                textToTypeAfterClick: stepTextToType
            ))
        }

        // Automation is always allowed when tutor mode is on (consent prompt
        // is the gate), otherwise require the experimental flag.
        let isAutomationAllowed = companionManager.isAutomationExperimentalEnabled
            || companionManager.isTutorModeEnabled

        let sequenceResult = await companionManager.automationEngine
            .requestConsentAndRunAutomationSequence(
                sequenceHumanReadableDescription: sequenceDescription,
                automationSteps: resolvedAutomationSteps,
                isAutomationExperimentalEnabled: isAutomationAllowed
            )

        let humanReadableResultDescription: String
        switch sequenceResult {
        case .completedAllSteps:
            humanReadableResultDescription = "automation completed all \(resolvedAutomationSteps.count) steps"
        case .halted(let haltedAtStepIndex):
            humanReadableResultDescription = "user halted at step \(haltedAtStepIndex + 1)"
        case .denied(let blockedAppBundleIdentifier):
            humanReadableResultDescription = "blocked by deny-list app: \(blockedAppBundleIdentifier)"
        case .userRejectedConsent:
            humanReadableResultDescription = "User declined automation consent."
        case .userDidNotRespondToConsent:
            humanReadableResultDescription = "User did not respond to the automation consent prompt within 3 minutes. The request was not run."
        case .disabledByFlag:
            humanReadableResultDescription = "automation feature flag is off"
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        let verificationCaptures = await captureScreensForVerification()
        let verificationSummary = verificationSummaryText(from: verificationCaptures)

        return ClaudeToolResultBlock(
            toolUseID: toolUseBlock.id,
            content: "\(humanReadableResultDescription). \(verificationSummary)",
            isError: false,
            verificationImages: verificationImageBlocks(from: verificationCaptures)
        )
    }

    /// Runs the automation via Claude's Computer Use API agent loop.
    private func executeAutomationViaComputerUseAPI(
        toolUseBlock: ClaudeToolUseBlock,
        companionManager: CompanionManager,
        sequenceDescription: String,
        rawStepDicts: [[String: Any]]
    ) async -> ClaudeToolResultBlock {
        let consentOutcome = await companionManager.automationEngine
            .requestOneTimeConsentAsync(
                sequenceHumanReadableDescription: sequenceDescription
            )

        switch consentOutcome {
        case .accepted:
            break
        case .rejectedByUser:
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "User declined automation consent.",
                isError: false
            )
        case .didNotRespond:
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: "User did not respond to the automation consent prompt within 3 minutes. The request was not run.",
                isError: false
            )
        }

        // Mark the loop as running so any auto-click utterance that lands
        // while the agent is still stepping gets a clean "automation in
        // progress" reply instead of being silently queued or cancelling
        // the live run.
        isComputerUseAgentLoopRunning = true
        defer { isComputerUseAgentLoopRunning = false }

        let runIdentifier = UUID().uuidString
        let runMetrics = ComputerUseRunMetrics()
        runMetrics.resetStuckCounter()

        ComputerUseRunLogger.appendRunEvent(
            wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
            runID: runIdentifier,
            eventType: "run_started",
            payload: [
                "description": sequenceDescription,
            ]
        )

        let targetNSScreen = ComputerUseTargetDisplay.preferredNSScreenForAutomation()
        let displayNumber = ComputerUseTargetDisplay.displayNumber(for: targetNSScreen)

        let executor = companionManager.makeComputerUseActionExecutor(
            targetNSScreen: targetNSScreen,
            runMetrics: runMetrics,
            runIdentifier: runIdentifier
        )

        companionManager.automationEngine.isHaltRequested = false

        defer {
            companionManager.computerUseAutomationStatusLine = ""
        }

        do {
            let initialCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let bestInitialCapture = ComputerUseCaptureSelection.bestCapture(
                matchingTargetScreen: targetNSScreen,
                in: initialCaptures
            ) else {
                return ClaudeToolResultBlock(
                    toolUseID: toolUseBlock.id,
                    content: "computer use could not capture the target display — no fallback attempted.",
                    isError: true
                )
            }

            guard let resizedInitialJPEG = ComputerUseImageFormatting.jpegDataResizedForComputerUse(
                captureImageData: bestInitialCapture.imageData,
                displayWidthInPoints: Int(targetNSScreen.frame.width),
                displayHeightInPoints: Int(targetNSScreen.frame.height)
            ) else {
                return ClaudeToolResultBlock(
                    toolUseID: toolUseBlock.id,
                    content: "computer use failed to normalize the initial screenshot for the API.",
                    isError: true
                )
            }

            let initialBase64 = resizedInitialJPEG.base64EncodedString()
            let initialMediaType = ComputerUseImageFormatting.detectImageMediaType(for: resizedInitialJPEG)

            let checkpointHints = computerUseCheckpointHints(fromRawStepDicts: rawStepDicts)
            let taskBody = """
            \(sequenceDescription)

            \(checkpointHints)
            """

            let computerUseSystemPrompt = """
            you are claude cursor, automating a task on the user's macOS desktop. \
            the user has already given consent for this automation sequence. \
            complete the task described below by taking screenshots and performing \
            mouse clicks, keyboard input, and scrolling as needed. after each \
            action, verify the result in the screenshot before proceeding. \
            if something doesn't look right, try an alternative approach. \
            be precise with your clicks — verify element positions in each \
            screenshot before clicking. \
            after typing a URL or search query in an address or search field, submit with a key action for Return — never type the word return as text. \
            use the suggested checkpoints as anchors when they match what you see; \
            they were inferred from the same screen context but may be approximate.
            """

            let loopResult = try await companionManager.claudeAPI.runComputerUseAgentLoop(
                taskDescription: taskBody,
                systemPrompt: computerUseSystemPrompt,
                initialScreenshotBase64: initialBase64,
                initialScreenshotMediaType: initialMediaType,
                displayWidthPixels: executor.reportedDisplayWidthPixels,
                displayHeightPixels: executor.reportedDisplayHeightPixels,
                displayNumber: displayNumber,
                runMetrics: runMetrics,
                actionExecutor: executor,
                isHaltRequested: { companionManager.automationEngine.isHaltRequested },
                onStatusUpdate: { statusText in
                    companionManager.computerUseAutomationStatusLine = statusText
                    print("🖥️ Computer Use: \(statusText)")
                }
            )

            // Deny-list refusal: bundle-specific status line already
            // set by the loop's onStatusUpdate callback. Emit the
            // `run_refused` event with cache-aware telemetry + rollup
            // line, and return a specific tool-result string so Claude
            // knows the run stopped for safety reasons — not a bug.
            if let refusal = loopResult.refusal {
                let blockedBundleID = refusal.blockedBundleIdentifier
                let refusalSummary = "Automation blocked: \(blockedBundleID) is on the protected-apps list. The run stopped after \(loopResult.iterationsUsed) iterations. Do not retry this action."

                if companionManager.isPatternDatabaseOpen {
                    companionManager.patternDatabase.recordComputerUseRun(
                        runID: runIdentifier,
                        sessionID: companionManager.activePatternDatabaseSessionIdentifier,
                        finalStatus: "refused_deny_list",
                        iterationCount: loopResult.iterationsUsed,
                        frontmostBundleID: blockedBundleID,
                        summaryLine: String(refusalSummary.prefix(500))
                    )
                }

                var refusalPayload = runMetrics.telemetryPayload(
                    iterationsUsed: loopResult.iterationsUsed,
                    finalStatus: "refused_deny_list",
                    frontmostBundleID: blockedBundleID
                )
                refusalPayload["blocked_bundle_id"] = blockedBundleID
                refusalPayload["response_preview"] = String(loopResult.responseText.prefix(200))

                ComputerUseRunLogger.appendRunEvent(
                    wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
                    runID: runIdentifier,
                    eventType: "run_refused",
                    payload: refusalPayload
                )
                ComputerUseRunLogger.appendRollupSummary(
                    wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
                    runID: runIdentifier,
                    telemetryPayload: refusalPayload
                )

                return ClaudeToolResultBlock(
                    toolUseID: toolUseBlock.id,
                    content: refusalSummary,
                    isError: false
                )
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
            let verificationCaptures = await captureScreensForVerification()
            let verificationSummary = verificationSummaryText(from: verificationCaptures)

            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let finalStatusSummary = "computer use finished after \(loopResult.iterationsUsed) API iteration(s). \(loopResult.responseText)"
            let fullContent = "\(finalStatusSummary). \(verificationSummary)"

            let userHalted = loopResult.responseText.contains("[halted by user]")
            let stuckPaused = loopResult.responseText.contains("[automation paused:")
            let resolvedStatus: String
            if userHalted {
                resolvedStatus = "halted"
            } else if stuckPaused {
                resolvedStatus = "stuck_no_progress"
            } else {
                resolvedStatus = "completed"
            }

            if companionManager.isPatternDatabaseOpen {
                companionManager.patternDatabase.recordComputerUseRun(
                    runID: runIdentifier,
                    sessionID: companionManager.activePatternDatabaseSessionIdentifier,
                    finalStatus: resolvedStatus,
                    iterationCount: loopResult.iterationsUsed,
                    frontmostBundleID: bundleID,
                    summaryLine: String(fullContent.prefix(500))
                )
            }

            var completionPayload = runMetrics.telemetryPayload(
                iterationsUsed: loopResult.iterationsUsed,
                finalStatus: resolvedStatus,
                frontmostBundleID: bundleID
            )
            completionPayload["response_preview"] = String(loopResult.responseText.prefix(200))

            ComputerUseRunLogger.appendRunEvent(
                wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
                runID: runIdentifier,
                eventType: "run_completed",
                payload: completionPayload
            )
            ComputerUseRunLogger.appendRollupSummary(
                wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
                runID: runIdentifier,
                telemetryPayload: completionPayload
            )

            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: fullContent,
                isError: false,
                verificationImages: verificationImageBlocks(from: verificationCaptures)
            )
        } catch {
            print("⚠️ Computer Use API error: \(error)")
            let nsError = error as NSError
            let message = "computer use API failed (\(nsError.code)): \(nsError.localizedDescription). one-shot automation was not run automatically — tell the user what happened."
            let errorBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if companionManager.isPatternDatabaseOpen {
                companionManager.patternDatabase.recordComputerUseRun(
                    runID: runIdentifier,
                    sessionID: companionManager.activePatternDatabaseSessionIdentifier,
                    finalStatus: "api_error",
                    iterationCount: 0,
                    frontmostBundleID: errorBundleID,
                    summaryLine: String(message.prefix(500))
                )
            }
            var failurePayload = runMetrics.telemetryPayload(
                iterationsUsed: 0,
                finalStatus: "api_error",
                frontmostBundleID: errorBundleID
            )
            failurePayload["error"] = nsError.localizedDescription

            ComputerUseRunLogger.appendRunEvent(
                wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
                runID: runIdentifier,
                eventType: "run_failed",
                payload: failurePayload
            )
            ComputerUseRunLogger.appendRollupSummary(
                wikiRawDirectoryURL: companionManager.wikiManager.rawDirectoryURL,
                runID: runIdentifier,
                telemetryPayload: failurePayload
            )
            return ClaudeToolResultBlock(
                toolUseID: toolUseBlock.id,
                content: message,
                isError: true
            )
        }
    }

    /// Formats planner step coordinates as optional checkpoints for the Computer Use model.
    private func computerUseCheckpointHints(fromRawStepDicts rawStepDicts: [[String: Any]]) -> String {
        guard !rawStepDicts.isEmpty else {
            return ""
        }
        var lines: [String] = [
            "Suggested checkpoints from the planner (screenshot pixel space — verify on the image before trusting):",
        ]
        for (index, stepDict) in rawStepDicts.enumerated() {
            let label = (stepDict["label"] as? String) ?? "step \(index + 1)"
            let stepX = (stepDict["x"] as? Double) ?? Double(stepDict["x"] as? Int ?? 0)
            let stepY = (stepDict["y"] as? Double) ?? Double(stepDict["y"] as? Int ?? 0)
            let screenNumber = stepDict["screen_number"] as? Int
            let typeText = stepDict["type_text"] as? String
            var line = "\(index + 1). \(label) — approx. (\(Int(stepX)), \(Int(stepY)))"
            if let screenNumber {
                line += " on screen index \(screenNumber)"
            }
            if let typeText, !typeText.isEmpty {
                line += "; type after click: \"\(typeText)\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Verification Screenshot

    /// Captures fresh screenshots from every display after an action tool
    /// runs. Returning all screens gives Claude enough context to verify
    /// multi-monitor workflows in the same tool loop iteration.
    private func captureScreensForVerification() async -> [CompanionScreenCapture] {
        do {
            return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            print("⚠️ Tool verification screenshot failed: \(error)")
            return []
        }
    }

    private func verificationImageBlocks(
        from verificationCaptures: [CompanionScreenCapture]
    ) -> [ClaudeToolResultVerificationImage] {
        verificationCaptures.map { capture in
            ClaudeToolResultVerificationImage(
                imageData: capture.imageData,
                imageMediaType: "image/jpeg"
            )
        }
    }

    private func verificationSummaryText(
        from verificationCaptures: [CompanionScreenCapture]
    ) -> String {
        guard !verificationCaptures.isEmpty else {
            return "no verification screenshot could be captured."
        }

        let joinedLabels = verificationCaptures
            .map(\.label)
            .joined(separator: " | ")

        return "attached \(verificationCaptures.count) verification screens: \(joinedLabels)."
    }

    /// When the model calls `point_at_element` more than once with the same
    /// label and nearly identical coordinates, the UI would show the primary
    /// navigation bubble plus a duplicate secondary marker — two stacked labels.
    private static func resolvedPointingTargetIsRedundantDuplicate(
        _ candidate: CompanionManager.PointingTarget,
        ofAnyExistingIn existingTargets: [CompanionManager.PointingTarget]
    ) -> Bool {
        let distanceThresholdPoints: CGFloat = 64
        let thresholdSquared = distanceThresholdPoints * distanceThresholdPoints
        let candidateLabel = candidate.labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateLabel.isEmpty else { return false }
        for existing in existingTargets {
            guard existing.labelText.caseInsensitiveCompare(candidate.labelText) == .orderedSame else {
                continue
            }
            let dx = existing.screenLocation.x - candidate.screenLocation.x
            let dy = existing.screenLocation.y - candidate.screenLocation.y
            if (dx * dx + dy * dy) < thresholdSquared {
                return true
            }
        }
        return false
    }
}
