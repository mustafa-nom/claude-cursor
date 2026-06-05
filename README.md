# Claude Cursor

Your AI-native Mac companion that tutors you in any app with voice Q&A, live navigation tips, on-cursor pointing, and step-by-step tutorials.

## The problem & who it's for

**Problem:** Explaining software or getting unstuck usually means breaking flow-tabbing to a browser, re-describing your screen, or watching a generic tutorial that does not match your layout, monitor count, or exact app state.

**Who it is for:** People who learn by doing such as students, self-taught builders, support-heavy roles, and anyone who wants a patient, voice-first guide that stays beside their work instead of replacing it. It is built for *your* screen and *your* phrasing, not a one-size-fits-all screencast.

## Architecture (short version)

For the full technical breakdown, read [`CLAUDE.md`](CLAUDE.md). In short:
- **menu bar SwiftUI + AppKit** — the app shell
- **Worker-proxied** Claude / STT / TTS — keys never ship in the binary
- **ScreenCaptureKit** vision — sees your actual screen to ground answers and pointing
- **SSE** streaming — replies stream in live so the overlay stays responsive
- optional **Computer Use** + local automation behind **consent**
- local **wiki + SQLite** for memory and lessons

## Project structure

```
claude-cursor/           # Swift source
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy (`cc-proxy` in wrangler.toml)
  src/index.ts              # Routes: /chat, /tts, /transcribe-token, /youtube-transcript, /whisper, /web-search, /fetch-url
CLAUDE.md                # Full architecture doc (agents read this)
```

## How our solution works (technical overview)

Claude Cursor is a Mac app that lives in your menu bar (no dock icon). Ask it a question by voice or text, and it looks at your actual screen and helps you right where you're working: pointing at the exact button to click, explaining what's in front of you, or walking you through a task step by step. A transparent overlay floats on top of everything to point and label things, and it never steals focus from the app you're using.

How it works (high level)
1. You hold a hotkey and talk (or type a question).
2. The app captures your screen plus what you said and sends both to Claude.
3. Claude doesn't just reply with text. It takes real actions on screen: moves a pointer to the right spot, labels on-screen elements, pulls up a saved how-to, starts a tutorial, or (only with your permission) automates a sequence of clicks.
4. It remembers what you've done before in a local knowledge base, so it gets more useful on your specific Mac over time instead of starting fresh each session.

Two things stay true throughout: secret API keys never ship inside the app (it talks to the AI through a small proxy server you control), and anything high-impact like automating clicks is opt-in and asks for your consent each time.

Under the hood (for the technically curious)
- **App:** Swift (SwiftUI + AppKit), menu-bar only, with a non-activating cursor overlay so pointing and explanations never interrupt your work.
- **Screen vision:** ScreenCaptureKit (multi-monitor, can focus a single window).
- **Voice:** push-to-talk into a pluggable transcription layer (AssemblyAI by default; Whisper or Apple Speech optional). Replies can be read aloud via ElevenLabs.
- **The AI:** Claude runs as an agent using native tool calls (point at an element, explain the screen, query the local wiki, start a YouTube-based lesson, run automation). Responses stream in real time (SSE) to keep the overlay snappy.
- **Automation:** built on Anthropic's Computer Use. Loops are bounded, log telemetry, detect when they're stuck, and stop on the first blocked action. A deny-list of sensitive apps, per-action consent, and a kill switch gate the whole thing.
- **Memory:** past sessions and researched sources are compressed into local wiki pages (duplicates merged), stored in SQLite, and retrieved on later questions so knowledge compounds locally.

## What could go wrong, and what safeguards I've built in

| Risk | Mitigation |
|------|------------|
| **API keys in the binary** | Keys live only on the **Cloudflare Worker**; the app talks to your proxy endpoints. |
| **Unwanted clicks or typing** | Automation is **gated** behind settings; **consent UI** on the overlay before actions; **deny-list** for sensitive bundles; **kill switch** to halt a sequence; Computer Use loops **stop on refusal**. |
| **Sensitive data in screenshots or audio** | Anything you say or show may go to **cloud STT, LLM, and TTS** providers you configure. **Session logging** runs text through a **PII stripper** before wiki ingest; users should still avoid secrets on screen when recording. |
| **Server-side fetch abuse** | Worker **`/fetch-url`** is used for research/wiki ingest with **SSRF-oriented mitigations** (not a general open proxy). |
| **Over-trusting the model** | Pointing and steps are **assistive**; clipboard auto-copy **strips internal coordination tags** so pasted text stays clean. |

Nothing removes the need for judgment in high-stakes or regulated environments—treat the companion like a very fast intern with a view of your desk.

## Ethical alignment and responsible use

We treated this as a **risk-aware desktop assistant**: anything that can see the screen or synthesize input deserves **intentional limits**, not “ship fast and hope.” The mitigations in **[What could go wrong](#what-could-go-wrong-and-what-safeguards-youve-built-in)** are the operational counterpart to the choices below.

- **Interaction-scoped memory, not ambient surveillance.** Session logs (`ObserverAgent`) record **text turns only when the companion actually handles a user↔assistant exchange**—there is no always-on transcript of the Mac. A session **starts on the first such turn** and **ends on idle or app quit** before optional wiki compression. That narrows what gets written to disk compared with continuous background logging.

- **Rhythm-based capture and honest cloud exposure.** **Push-to-talk** keeps the default mic path **user-gated**. Screenshots are taken to serve an **explicit** companion flow (hotkey, chat, tutor observation, automation step, etc.), not as a continuous upload pipeline. When you *do* use those features, audio, images, and model payloads may still reach **Anthropic**, **AssemblyAI**, **ElevenLabs**, and any optional providers you configure—third-party policies still apply.

- **Proactive tutor: ask first, then throttle.** Tutor nudges show a **yes/no** prompt before the model speaks. **SQLite**-backed rate limits cap how often nudges can fire and apply **backoff** after repeated declines so the product does not nag indefinitely.

- **Automation as a high-impact channel.** Experimental automation and tutor mode are **opt-ins**. **Per-sequence consent** on the overlay, a bundle **deny-list**, a **kill switch**, and **Computer Use refusal handling** (loop stops on first blocked action) treat mouse and keyboard as privileged—not something the model gets “for free.”

- **Logging hygiene without pretending the risk is zero.** **`PIIStripper`** runs **before** session text is appended to disk. **Wiki compression** skips very short sessions (fewer than two turns) to avoid noise and unnecessary Claude calls; published pages are **summaries**, not raw dumps. **Residual risk remains** by design—e.g. phone numbers are **not** stripped; email addresses keep **domains** for context—so users should still avoid secrets on screen or in speech.

- **Server-side fetch boundaries.** Worker **`/fetch-url`** (research / wiki ingest) uses **SSRF-oriented mitigations** so the infrastructure cannot be turned into a generic open proxy.

- **Analytics transparency.** **PostHog** is integrated for product insight; anyone shipping a fork should disclose that in their own privacy posture.

- **Open source responsibility.** Forks inherit the same capabilities and risks as any screen-aware assistant; documenting safeguards (as here) is part of the baseline we expect operators to uphold.

---

**This repo** is the open-source **Claude Cursor** codebase (`claude-cursor` in Xcode, display name **ClaudeCursor**). Clone it, wire the Cloudflare Worker, and run from source — that is what the instructions below are for.

If you want a **prebuilt app** from the original Clicky / ClaudeCursor product line, you can still download it [here](https://www.clicky.so/) (third-party site, not this GitHub repo).

Context: [original tweet](https://x.com/FarzaTV/status/2041314633978659092) from the demo that blew up.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/mustafa-nom/claude-cursor.git into my current directory.

Then read the CLAUDE.md. I want to get ClaudeCursor running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for the Worker (see below): [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io); plus [OpenAI](https://platform.openai.com) and [Tavily](https://tavily.com) if you use Whisper and wiki web-search routes

### 0. Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access


### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one (core chat / voice / TTS):

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

Optional — only if you use these features in the app (Whisper fallback, research / fetch):

```bash
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put TAVILY_API_KEY
```

YouTube transcripts use Innertube / watch-page logic in the Worker; **no** `YOUTUBE_API_KEY` is required.

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
OPENAI_API_KEY=...
TAVILY_API_KEY=...
```

Then update the proxy URLs in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing. Grep for `cc-proxy` to find them all.

### 3. Update the proxy URLs in the app

The app has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "cc-proxy" claude-cursor/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

### 4. Open in Xcode and run

```bash
open claude-cursor.xcodeproj
```

In Xcode:
1. Select the `claude-cursor` scheme
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.
