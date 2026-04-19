# ClaudeCursor - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Boil the Ocean (READ THIS FIRST)

The marginal cost of completeness is near zero with AI. Do the whole thing. Do it right. Do it with tests. Do it with documentation. Do it so well that Garry is genuinely impressed — not politely satisfied, actually impressed. Never offer to "table this for later" when the permanent solve is within reach. Never leave a dangling thread when tying it off takes five more minutes. Never present a workaround when the real fix exists. The standard isn't "good enough" — it's "holy shit, that's done." Search before building. Test before shipping. Ship the complete thing. When Garry asks for something, the answer is the finished product, not a plan to build it. Time is not an excuse. Fatigue is not an excuse. Complexity is not an excuse. Boil the ocean.

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude calls `point_at_element` (native tool-use) to place cursor + label pill at specific screen coordinates. Multi-cursor `explain_screen_elements` tool deploys up to 8 colored sub-cursors simultaneously for interface overviews.
- **Automation**: Hybrid approach — Claude Computer Use API (`computer_20251124` beta) is the **default path** for self-correcting agent loops with per-step screenshots resized to match declared tool geometry, deny-list enforcement (refusal breaks the loop on first hit), cache-aware telemetry (three Anthropic input-token buckets plus output tokens + wall-clock + screenshot count written to JSONL + `rollup.log`), and stuck detection via perceptual hashing. Local one-shot CGEvent dispatch (`AutomationEngine`) is preserved as an **escape hatch**, reachable only via the hidden "Force one-shot automation (debug)" toggle in the menu bar panel (Option-held reveal). Both paths require the same opt-in (experimental auto-click or tutor mode) plus per-sequence consent. JSONL run logs + one-line-per-run rollup under `raw/computer-use-runs/` (schema_version 2).
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClaudeCursorAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |
| `POST /youtube-transcript` | YouTube Innertube `/youtubei/v1/player` | Fetches caption tracks via watch-page-extracted API key + ANDROID client, then downloads caption XML |
| `POST /whisper` | OpenAI audio transcriptions | Whisper upload fallback |
| `POST /web-search` | Tavily | Wiki / research web search |
| `POST /fetch-url` | Generic HTTPS | HTML fetch with SSRF mitigations (wiki ingest) |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`, `OPENAI_API_KEY` (Whisper), `TAVILY_API_KEY` (web search). No `YOUTUBE_API_KEY` — transcript route uses Innertube only.
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show ClaudeCursor" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

Each row describes the file's responsibility. Line counts are intentionally omitted — they rot quickly and mislead readers into thinking a file is "big" or "small" when the relevant question is what it owns.

| File | Responsibility |
|------|----------------|
| `ClaudeCursorApp.swift` | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, overlay management, and the `preferOneShotAutomationForDebugging` flag (toggled via the hidden debug submenu). Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. Reads `CLAUDE_CURSOR_SMOKE_TEST_*` environment variables on `start()` so the CI smoke test in `OneShotAutomationSmokeTest.swift` can force one-shot mode and dispatch a synthetic utterance. |
| `MenuBarPanelManager.swift` | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | SwiftUI panel content for the menu bar dropdown. Styled with always-light `DS.CompanionPanel` paper tokens (distinct from dark overlay/chat). Shows companion status, push-to-talk instructions, model picker, tutor mode toggle, auto-copy toggle, permissions UI, DM feedback button, and quit button. Houses a hidden debug submenu revealed only while Option (⌥) is held — currently exposes the "Force one-shot automation (debug)" toggle as an escape hatch for the demoted CGEvent path. |
| `OverlayWindow.swift` | Full-screen transparent overlay hosting the blue cursor, nav pointing bubble (via shared `CursorPillBubble` + `CursorPillTypewriter`), pointing label pill, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CursorPillBubble.swift` | Shared SwiftUI renderer for the terracotta pill used by both the nav pointing bubble (`.intrinsic` sizing) and the cursor-adjacent consent prompt (`.constrained(maxWidth:)` sizing). The `scale` parameter drives the dynamic shadow only — callers apply `.scaleEffect(_:anchor:)` externally because nav and consent use different anchors. |
| `CursorPillTypewriter.swift` | `AsyncStream`-based typewriter for the cursor-adjacent pill. Cancels-and-replaces cleanly so a new stream can preempt an in-flight one without stranded `DispatchQueue.asyncAfter` closures mutating dead views. Shared by the nav bubble and the consent prompt. |
| `CompanionScreenCaptureUtility.swift` | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. Includes focused-window capture for tutor mode. |
| `BuddyDictationManager.swift` | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | Claude vision API client with streaming (SSE) and non-streaming modes plus the Computer Use agent loop. The loop folds Anthropic's `usage` block (cache_read / cache_creation / input / output) into `ComputerUseRunMetrics` each iteration and breaks on first deny-list refusal — returning a `ComputerUseAgentLoopResult` with an optional `ComputerUseRefusal` so the caller can emit a bundle-specific status line, `run_refused` JSONL event, and tool result. |
| `OpenAIAPI.swift` | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | Design system tokens — colors, corner radii, shared styles. Most UI uses dark-surface `DS.Colors`; the menu bar companion panel uses scoped always-light `DS.CompanionPanel`. Shared `DS.CornerRadius`, button styles, etc. |
| `ClaudeCursorAnalytics.swift` | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `UserActivityIdleDetector.swift` | Monitors keyboard/mouse activity and detects idle periods (3s threshold) for tutor mode observation triggers. |
| `LessonStateMachine.swift` | High-level companion mode arbitration. Manages transitions between Idle, Navigation, Tutor, Lesson, Answer, and Chat modes. Prevents conflicting modes from running simultaneously (e.g., tutor + lesson). |
| `WikiManager.swift` | Swift-native wiki file manager. Owns `~/Library/Application Support/ClaudeCursor/wiki/` directory, YAML frontmatter parsing, index.md/log.md/schema.md management, page/raw-source file I/O, and duplicate page detection for consolidation. Pure storage — retrieval lives in `WikiQueryEngine`. |
| `WikiQueryEngine.swift` | Read-only retrieval over the wiki. Ranks pages by weighted keyword matches (title 4x, tags 3x, summary 2x, body 0.25x capped), blends in frontmatter confidence, and packs top matches into a character-budgeted context bundle with truncation indicators. Short tool names allowlist prevents filtering of terms like "Git", "Go", "npm". Returns a structured `WikiQueryResult` with bundle text plus metadata (included pages, budget-constrained flag). |
| `PatternDatabase.swift` | SQLite3-backed persistence for lesson progress, session metadata, tutor nudge rate limiting, confidence scores with time-based decay, interaction outcome tracking, and `computer_use_runs` analytics. Uses built-in libsqlite3 (no external dependency). |
| `ChatWindowController.swift` | Floating `NSPanel` hosting a SwiftUI chat transcript view + text input. Typed messages route through the same pipeline as voice (screenshot + wiki context + Claude API). Toggled by the "Show chat" menu bar toggle. |
| `AnswerPanelView.swift` | Floating `NSPanel` that displays detailed, markdown-rendered responses for long-form answers. Shown when the adaptive router picks `.answer` mode. Persistence rules documented in the file header. |
| `RichMarkdownContent.swift` | Shared markdown + LaTeX rendering: `AttributedString` for inline markdown, `MathJaxMarkdownWebView` (marked.js + MathJax) for math delimiters and fenced code. Used by the answer panel and chat transcript bubbles. |
| `AdaptiveOutputRouter.swift` | Pure classification enum that decides which output surface a Claude response should render on: navigation (cursor pointing), lesson (step overlay), answer (persistent panel), or chat (cursor-follow bubble). Heuristic based on response structure + interaction mode. |
| `ClipboardManager.swift` | Centralizes auto-copy behavior. Strips internal coordination tags (`[POINT:...]`, `[STEP:...]`) before writing to the system pasteboard so users never paste raw tags. |
| `ProactiveTutorPromptController.swift` | Floating speech-bubble panel with inline y/n buttons for proactive tutor nudges. Mouse-accepting (unlike the cursor overlay) so the user can tap buttons, non-activating so focus stays in their current app. |
| `AppBundleConfiguration.swift` | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `YouTubeLessonExtractor.swift` | Turns a YouTube URL into a structured `Lesson` with ordered `LessonStep`s. Parses video IDs from all URL shapes, fetches transcript via direct Innertube IOS client call (primary) with Worker `/youtube-transcript` as fallback, and asks Claude to decompose the transcript into actionable steps with timestamp ranges. Stateless and text-only Claude call (no images). |
| `LessonOverlayView.swift` | Full-screen transparent lesson overlay. Pink/red pill step banner (top center) with step counter, title, instruction, previous/next controls and close button. Clickable thumbnail strip (bottom) for step navigation. Keyboard shortcuts via local NSEvent monitor (←/→/Esc). Non-activating NSPanel at floating level; transparent center passes clicks through to the target app. |
| `VideoPiPController.swift` | Picture-in-picture YouTube player. Bottom-right non-activating NSPanel wrapping a WKWebView loaded with a small HTML shell that hosts the YouTube IFrame Player. JS→native bridge reports playback state changes + current-time updates ~4x/second to a delegate. `seekToTimestamp`, `pausePlayback`, `resumePlayback` drive the player from native. |
| `AutoResearchPipeline.swift` | Topic-driven doc ingester. Reads user-editable `doc-sources.json` and tries curated sources first by keyword match. Falls back to Tavily web search via Worker `/web-search` if no curated source matches. Each page is fetched through Worker `/fetch-url`, HTML-stripped, and written to `raw/sources/` with frontmatter citing origin, URL, and fetch date. Wired into the `research_topic` tool and the "Research a topic" row in the menu bar panel. |
| `ResearchSourceCompressor.swift` | Bridges the research ingest layer to the query layer. Takes the raw sources `AutoResearchPipeline` writes to `raw/sources/` and compresses them into a single queryable wiki page under `pages/`. Uses `CryptoKit.SHA256` over sorted source URLs to produce stable filenames across app restarts. |
| `ObserverAgent.swift` | Session-scoped observer. Writes append-only `raw/sessions/session_<id>.md` logs for every user↔Claude turn (PII-stripped via `PIIStripper`), tracks frontmost apps + turn count, and on session end hands the log to `SessionCompressor` for wiki ingestion. |
| `SessionCompressor.swift` | Turns a raw session log into a compact wiki page via Claude. Parses a JSON schema (headline + 3–10 durable observations + task outcomes + tags), writes `pages/session-<id>.md` with 0.7 confidence, and indexes the page so `WikiQueryEngine` can retrieve it later. Also exposes `generateColdStartRecap(fromMostRecentSessionFileURL:)` for the warm return-visit greeting. |
| `WikiPageConsolidator.swift` | Merges duplicate or closely related wiki pages into a single consolidated page via Claude. Triggered after session compression when the new page overlaps with existing pages by tag or title similarity. |
| `PIIStripper.swift` | Stateless regex-based PII scrubber. Replaces SSNs, credit card numbers, API keys, bearer tokens, JWTs, and `password=`-style secrets with deterministic placeholders. Email addresses keep their domain so the assistant still has context. Phone numbers are intentionally NOT stripped. |
| `AutomationEngine.swift` | CGEvent dispatcher for guided automation. Synthesizes mouse clicks (left, right, double), keyboard input, scroll wheel, keyboard shortcuts, and mouse movement. One-time consent via `CursorBubbleConsentPromptController` (returns the `CursorBubbleConsentOutcome` enum — accepted / rejectedByUser / didNotRespond), shared `AutomationSafetyPolicy` deny-list, before/after screenshots, and an append-only `raw/automation-actions.log`. Kill switch via `requestHaltOfCurrentSequence()`. Methods exposed for `ComputerUseActionExecutor`. |
| `CursorBubbleConsentPromptController.swift` | Terracotta consent pill rendered on the cursor overlay. Uses the shared `CursorPillBubble` + `CursorPillTypewriter` so it streams characters the same way the nav bubble does. Handles in-place prompt replacement on a concurrent automation tool call (no orderOut flicker), Return/Escape keyboard shortcuts via a local NSEvent monitor, VoiceOver-aware accessibility announcements, and a single-resolve timeout that swaps content to "timed out — dismissing" before resolving `.didNotRespond`. |
| `ComputerUseSupport.swift` | Shared Computer Use helpers: aspect-ratio-matched JPEG resize, frontmost-window target display selection, `ComputerUseRunMetrics` (stuck counter plus wall-clock, screenshot count, and the three Anthropic input-token buckets + output tokens for cache-aware telemetry), and `ComputerUseRunLogger` which injects `schema_version: 2` into every JSONL event plus `appendRollupSummary` for the one-line-per-run `rollup.log`. |
| `ComputerUseActionExecutor.swift` | Maps Claude Computer Use API actions to `AutomationEngine` CGEvent dispatch. Resizes every screenshot to declared tool resolution, enforces the deny-list per action (surfacing `wasBlockedByDenyList` + `blockedBundleIdentifier` on the result so the loop can break on first hit), maps coordinates against the target `NSScreen`, attaches `ScreenshotDiffDetector` no-change hints, and increments the screenshot count on `ComputerUseRunMetrics`. |
| `CompanionToolRegistry.swift` | Claude tool-use registry and dispatcher. Hosts `executeStartAutomationSequence` which gates automation on `isAutomationExperimentalEnabled \|\| isTutorModeEnabled` and routes to Computer Use by default — one-shot CGEvent dispatch only runs when `preferOneShotAutomationForDebugging` is on. Emits `run_started` / `run_completed` / `run_refused` / `run_failed` JSONL events with cache telemetry payloads plus `rollup.log` summaries. |
| `claude-cursorTests/CursorPillBubbleSnapshotTests.swift` | 24 XCTest snapshot cases (6 states × 2 surfaces × 2 color modes) asserting perceptual identity between the shared `CursorPillBubble` and its pre-refactor behavior. Uses `pointfreeco/swift-snapshot-testing` at `precision: 0.99` + `perceptualPrecision: 0.98`. |
| `claude-cursorUITests/OneShotAutomationSmokeTest.swift` | CI smoke test for the demoted one-shot CGEvent path. Gated by `CI_SMOKE_TESTS_ENABLED=1` (XCTSkipUnless). Drives the app via `launchEnvironment` with `CLAUDE_CURSOR_SMOKE_TEST_ENABLED=1`, `CLAUDE_CURSOR_FORCE_ONE_SHOT_AUTOMATION=1`, and a test utterance; verifies Chrome's address bar reflects the expected URL. Keeps the escape hatch exercised so it doesn't rot. |
| `worker/src/index.ts` | Cloudflare Worker proxy. Routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token), `/youtube-transcript` (YouTube Innertube), `/whisper` (OpenAI Whisper), `/web-search` (Tavily), `/fetch-url` (generic URL fetch with SSRF mitigations). Forwards `anthropic-beta` header from client for Computer Use API support. |

## Build & Run

```bash
# Open in Xcode
open claude-cursor.xcodeproj

# Select the claude-cursor scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- The project has been renamed from "leanring-buddy" to "claude-cursor" — use "claude-cursor" for all paths and "ClaudeCursor" for display names
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
