# Claude Cursor

Your AI-native Mac companion that tutors you in any app with voice Q&A, live navigation tips, on-cursor pointing, and step-by-step tutorials.

## What problem you're solving and who it's for

**Problem:** Explaining software or getting unstuck usually means breaking flow—tabbing to a browser, re-describing your screen, or watching a generic tutorial that does not match your layout, monitor count, or exact app state.

**Who it is for:** People who learn by doing on a Mac—students, self-taught builders, support-heavy roles, and anyone who wants a patient, voice-first guide that stays beside their work instead of replacing it. It is built for *your* screen and *your* phrasing, not a one-size-fits-all screencast.

## How your solution works (technical overview)

Claude Cursor is a **menu bar-only** app (no dock icon): a custom `NSPanel` control surface plus a full-screen, non-activating **cursor overlay** so explanations and pointing never steal focus from the app you are using.

- **Voice in:** Push-to-talk (Control + Option) captures microphone audio; a **pluggable transcription** layer streams to AssemblyAI by default (OpenAI Whisper upload and Apple Speech are optional fallbacks).
- **Vision in:** When you engage the companion, **ScreenCaptureKit** grabs screenshots (multi-monitor and, in tutor flows, focused-window capture) and sends them with your transcript to **Claude** over **SSE** through a **Cloudflare Worker**—the app never holds your API keys.
- **Voice out:** Responses can be read aloud via **ElevenLabs** (also proxied through the Worker).
- **Pointing:** Claude can drive native tools such as **`point_at_element`** and multi-cursor **`explain_screen_elements`** so labels and arcs land on real coordinates across displays.
- **Optional automation:** **Anthropic Computer Use** is the default path for agent-style loops (resized screenshots, telemetry, stuck detection). A local CGEvent path remains a **debug-only escape hatch**. Both require **explicit product opt-in** (experimental automation or tutor mode) and **per-sequence consent** before synthetic input runs.
- **Memory and research (on device):** A local **wiki** under Application Support, **session logs** compressed into pages, **research ingest** (curated sources plus optional Tavily search and fetches through the Worker), and a **SQLite** pattern database back lesson and tutor behavior—see `CLAUDE.md` for the full map.

## What could go wrong, and what safeguards you've built in

| Risk | Mitigation |
|------|------------|
| **API keys in the binary** | Keys live only on the **Cloudflare Worker**; the app talks to your proxy endpoints. |
| **Unwanted clicks or typing** | Automation is **gated** behind settings; **consent UI** on the overlay before actions; **deny-list** for sensitive bundles; **kill switch** to halt a sequence; Computer Use loops **stop on refusal**. |
| **Sensitive data in screenshots or audio** | Anything you say or show may go to **cloud STT, LLM, and TTS** providers you configure. **Session logging** runs text through a **PII stripper** before wiki ingest; users should still avoid secrets on screen when recording. |
| **Server-side fetch abuse** | Worker **`/fetch-url`** is used for research/wiki ingest with **SSRF-oriented mitigations** (not a general open proxy). |
| **Over-trusting the model** | Pointing and steps are **assistive**; clipboard auto-copy **strips internal coordination tags** so pasted text stays clean. |

Nothing removes the need for judgment in high-stakes or regulated environments—treat the companion like a very fast intern with a view of your desk.

## How your project empowers rather than replaces people

The app is designed to **shorten the gap between question and action** on *your* machine: you stay in the driver’s seat, in the app you care about, while the companion **narrates, points, and (only with consent) automates**. Push-to-talk keeps control **rhythm-based**—you decide when you are “on the record.” Tutor and lesson modes bias toward **scaffolding** (what to look at next, why it matters) rather than black-box completion of your work. The local wiki and session summaries aim to **compound what you learned**, not to substitute for understanding.

## Any ethical considerations made when building this project

- **Transparency:** Screen and microphone data leave the device only when you use features that require them; third-party policies for Anthropic, AssemblyAI, ElevenLabs, and any optional providers still apply.
- **Consent and autonomy:** **Visual consent** and clear opt-ins for automation respect that **mouse and keyboard are high-impact channels**; refusal and timeout paths are first-class.
- **Privacy-aware logging:** **PII stripping** before session material is compressed into wiki pages reduces accidental long-term retention of secrets—while **not** claiming zero risk (e.g. phone numbers are intentionally not stripped; email domains are preserved for context).
- **Analytics:** **PostHog** is integrated for product usage insight; operators should disclose that in their own privacy posture if they ship forks.
- **Open source responsibility:** Forks inherit the same **power and risk** as any screen-aware assistant; documenting safeguards (as here) is part of the ethical baseline.

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

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture (short)

For the full technical breakdown, read [`CLAUDE.md`](CLAUDE.md). In one sentence: **menu bar SwiftUI + AppKit**, **Worker-proxied** Claude / STT / TTS, **ScreenCaptureKit** vision, **SSE** streaming, optional **Computer Use** and local automation behind **consent**, local **wiki + SQLite** for memory and lessons.

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

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
