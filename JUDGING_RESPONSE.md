# ClaudeCursor — Judging Criteria Response

**Project:** ClaudeCursor — a macOS companion that sees your screen, hears your voice, and teaches you how to use any software through pointing, narration, and context-aware guidance.

**Tagline:** *The learning curve is the bottleneck. ClaudeCursor flattens it.*

---

## 1. Impact Potential

### The Problem, Stated Precisely

The pace of software change has outstripped the pace at which humans can learn it. Every year the tools we use at work, in school, in healthcare, and in civic life get more capable — and more complex. The people who fall furthest behind are not the people who refuse to learn; they are the people who cannot find a teacher at the exact moment they are stuck.

Traditional learning resources fail at the "last mile" of on-screen competence:

- **Video tutorials** are linear, generic, and frozen in time. A 2023 Xcode tutorial is already partially wrong. A MyChart walkthrough filmed on an iPhone does not match the Android patient's screen.
- **Written documentation** assumes you already know the vocabulary to search for what you don't know. This is the "unknown unknowns" trap.
- **Human tutors** are expensive, scheduled, and rarely available at 11 PM when a first-generation college student is finally sitting down to learn Xcode.
- **Generic chatbots** can describe steps in words, but they can't see your screen. They answer the question you asked, not the question your actual context demands.

The result is a world where capability is gated not by intelligence or effort, but by *access to in-the-moment help*. That gate is what ClaudeCursor removes.

### Who This Helps (Concrete, Not Abstract)

This is not a tool for "everyone." It is a tool for a specific set of people who share one property: they are trying to do something on a computer they have never done before. What varies is *who they are* and *what's at stake.*

**1. Older adults navigating digital healthcare and government services.**
Roughly one in four Americans over 65 either do not use the internet or use it with significant difficulty (Pew Research, 2024 data). Medicare.gov, MyChart, Social Security's online portals, and state unemployment systems are among the most complex consumer-facing interfaces in existence — and they're the interfaces that govern life-critical outcomes. An 72-year-old trying to schedule a telehealth appointment after a fall should not have to wait three days for her granddaughter to visit. ClaudeCursor can watch her screen, hear her ask "where do I click to see my test results?", and point — in real time, in her app, on her monitor.

**2. Community college and first-generation students learning professional tooling.**
Xcode, Figma, Git, Jupyter, Blender, Unity, Excel with pivot tables, Salesforce, AWS Console — these are the tools that gatekeep access to ~$80K+ jobs in the U.S. economy. First-generation students rarely have a parent or mentor who can sit beside them and say "click the blue scheme selector at the top." Generic YouTube tutorials assume a homogeneous starting point that doesn't match their screen. ClaudeCursor's value proposition to this group is extremely concrete: *the thing your richer classmate has (a dad who's a software engineer), but available to everyone.*

**3. Career switchers and adult learners.**
The U.S. has roughly 50M working adults who will need to acquire substantial new digital skills over the next decade (BLS + OECD PIAAC estimates). Bootcamps and MOOCs have catastrophic completion rates — Stanford and MIT studies put MOOC completion under 10%, largely because learners get stuck on small, context-specific obstacles that a human tutor would resolve in 30 seconds. ClaudeCursor replaces the 30-second unblocker.

**4. People with learning differences and cognitive accessibility needs.**
For users with ADHD, dyslexia, or age-related cognitive decline, the multimodal design of ClaudeCursor — voice in, voice out, visual pointing, optional step-by-step lesson overlay — is not a nicety; it is the difference between "usable" and "unusable." Research on multimodal learning (Mayer's cognitive theory of multimedia learning) consistently finds that combined audio + visual pointing reduces extraneous cognitive load, particularly for novices.

**5. Non-native English speakers using English-language software.**
Claude's multilingual capability combined with screen-aware pointing means a Vietnamese-speaking small business owner can ask "làm sao để tạo hóa đơn?" and be pointed directly at the Invoice button in QuickBooks. This unlocks a massive underserved population — a user group that generic English-only tutorials exclude by default.

**6. Developers learning unfamiliar tools.**
Even highly technical users — the professed audience for AI tools — are constantly falling behind. A Rust developer learning Kubernetes. A frontend engineer opening Xcode for the first time. A designer trying to use a new 3D tool. The Stack Overflow developer survey consistently shows that "learning new technology quickly enough" is a top-3 stressor across seniority levels. ClaudeCursor compresses the time-to-first-working-build for any unfamiliar tool.

### Meaningful Help, Not Cosmetic Help

A critical judging question: *does this actually help, or does it just feel helpful?* We designed ClaudeCursor around three tests of meaningful help:

- **Reduces abandonment.** Stuck-on-a-small-thing is the #1 reason people abandon new tools. Being able to ask "what does this button do?" in plain voice and get a pointer at the answer keeps people in the flow.
- **Preserves learning.** ClaudeCursor defaults to *pointing and narrating* rather than *doing it for you*. The user still performs the action; Claude just removes the search cost. This is the difference between a calculator (tool that replaces skill) and a spell checker (tool that teaches you while it helps).
- **Compounding over time.** The wiki/memory system means the app learns your particular tools, terminology, and common tasks. A week in, it knows you work in Xcode and Figma; it knows which Git remote you push to; it answers faster and more relevantly. Learning has a compounding curve; so does ClaudeCursor.

### Realistic Reach

- **macOS install base:** ~100M active devices globally; overrepresented in higher education, creative industries, and the specific demographics we serve best (US students, designers, educators).
- **Menu bar deployment:** No dock icon, no main window, no onboarding friction. A single installer and the user is ready. This is the lowest-friction distribution model available on macOS.
- **Port surface:** Nothing in the core architecture is macOS-exclusive in principle. The screen capture and cursor overlay are OS-specific, but the Claude integration, voice pipeline, tool-use registry, wiki memory, and Computer Use loop port cleanly to Windows (via UIAutomation + CGEvent equivalents) and Linux. A mobile version is harder but not impossible — iOS Screen Time APIs + accessibility APIs provide the surface.
- **Cost at scale:** All API keys live on a Cloudflare Worker proxy. That architecture lets us broker API costs centrally — which means we can subsidize or tier for users who cannot afford API credits, instead of gating access entirely. This matters enormously for the populations above.

### Impact Areas Beyond the Obvious

Beyond the primary audiences, ClaudeCursor has credible applications in:

- **Disability services offices at universities.** A dedicated tutor for a student with a documented learning difference is expensive; ClaudeCursor is a supplement that works 24/7 across every piece of software the student uses.
- **Workforce retraining programs** (state-run, union-run, corporate L&D). These programs spend billions on generic video content; embedded in-context guidance converts better.
- **Senior centers and public libraries.** The digital divide in the 65+ cohort has social and economic consequences downstream — missed medical appointments, unclaimed benefits, social isolation. A library kiosk running ClaudeCursor is a force multiplier on librarian time.
- **Immigration and refugee services.** Filling out I-589, I-130, USCIS portals — these are notoriously dense interfaces with life-changing outcomes. A multilingual, screen-aware guide is transformative here.
- **Small business software adoption.** SMBs routinely buy QuickBooks, Square, Shopify, Salesforce and then underuse them because training is nonexistent. The ROI unlock is real.
- **Assistive technology research.** The multimodal design (voice + visual pointing + narration) is a natural test bed for research on human-AI learning interfaces.

---

## 2. Technical Execution

### Claude Is Core, Not Bolted On

The simplest test of whether Claude is "core" to a project: remove Claude. What remains? In ClaudeCursor's case, removing Claude removes the product. Without Claude you have a voice recorder that takes screenshots. Every non-trivial capability — understanding the screen, deciding where to point, writing a lesson plan, deciding whether to chat or automate, stripping PII from session logs, consolidating wiki pages — is a Claude call.

We use Claude across three distinct modalities, each chosen deliberately:

1. **Claude vision + SSE streaming chat** for the primary user-facing loop. Every push-to-talk interaction sends the transcript plus a screenshot of the user's screen to Claude; the response streams back as text (rendered in the cursor overlay or chat panel) and is simultaneously spoken via ElevenLabs TTS.
2. **Claude native tool-use** for structured actions. We define tools like `point_at_element`, `explain_screen_elements` (deploys up to 8 colored sub-cursors simultaneously for interface overviews), `research_topic`, and `start_automation_sequence`. Claude decides when to call them. This is what turns a chatbot into a companion — Claude doesn't just describe an answer, it moves a cursor onto the answer.
3. **Claude Computer Use API** (`computer_20251124` beta) for self-correcting agent loops. When a user opts into automation, the Computer Use loop takes per-step screenshots (resized to match declared tool geometry — a detail most integrations miss), feeds them back to Claude, and lets Claude re-plan on failure. Stuck detection via perceptual hashing breaks runaway loops.

### Architecture Decisions That Matter

**Cloudflare Worker API proxy.** No API keys ship in the app binary. Every Anthropic, ElevenLabs, AssemblyAI, Tavily, and OpenAI call is brokered through a Worker we control. This is both a security property (users can't extract keys) and a governance property (we can rate-limit, audit, and subsidize usage centrally).

**Pluggable transcription layer.** AssemblyAI streaming is primary (low latency, high accuracy), OpenAI Whisper upload is fallback, and Apple Speech is local-only fallback when offline. The provider protocol abstracts all three behind one interface so the push-to-talk pipeline is indifferent to which backend is serving.

**Shared URLSession for streaming.** Creating and invalidating a URLSession per streaming session corrupts the OS connection pool and produces "Socket is not connected" errors after a few rapid reconnections. We learned this the hard way and fixed it by keeping one long-lived session owned by the provider, not the session. This is the kind of detail that separates a demo from a product.

**Listen-only CGEvent tap for global push-to-talk.** AppKit's `NSEvent.addGlobalMonitorForEvents` drops modifier-combination events under background load. A listen-only `CGEventTap` at the HID level catches `ctrl+option` press/release reliably. This sounds small; it is the difference between a shortcut that works and one that doesn't.

**Non-activating `NSPanel` overlays.** The cursor overlay, companion panel, chat window, and proactive tutor prompt are all `NSPanel`s with `canBecomeKey = false` and `joinsAllSpaces`. That means they appear on top of the user's current app, point at things, and never steal focus. The user keeps typing in Xcode while Claude points at a menu item.

**Hybrid automation model.** The default automation path is Anthropic's Computer Use API — which gives self-correction, per-step screenshot feedback, and cache-aware token accounting. We *also* preserve a local one-shot CGEvent dispatcher as an escape hatch, accessible only through an Option-key-held debug submenu. Two paths, one consent flow. The escape hatch is exercised by a CI smoke test so it doesn't rot.

**Adaptive output router.** A pure classification enum decides, given a Claude response, which surface to render on: cursor overlay (navigation/pointing), lesson overlay (multi-step tutorials), answer panel (long-form markdown with LaTeX), or chat transcript. One pipeline, four UI surfaces, picked based on the response structure. This is a subtle but important decision — it means the same Claude response shape can render appropriately regardless of whether the user asked "where's the build button?" or "explain closures in Swift."

### Technical Innovations Worth Highlighting

- **Multi-cursor `explain_screen_elements`.** Up to 8 colored sub-cursors deploy simultaneously to label interface regions. Critical for interface overviews ("what am I even looking at?").
- **YouTube lesson extractor.** Turns an arbitrary YouTube URL into a structured `Lesson` with ordered `LessonStep`s and timestamp ranges. Transcript via direct Innertube IOS client call with Worker fallback; Claude decomposes transcript into actionable steps. A native PiP player seeks to the timestamp when the user enters each step.
- **Wiki memory system.** A Swift-native on-disk wiki under `~/Library/Application Support/ClaudeCursor/wiki/`. Sessions are PII-stripped, compressed by Claude into 0.7-confidence wiki pages, and retrieved by a weighted keyword scorer (title 4x, tags 3x, summary 2x, body 0.25x capped). A duplicate-page consolidator merges overlapping pages via Claude. This is a working, stateful long-term memory — not a placeholder.
- **Auto-research pipeline.** Reads a user-editable `doc-sources.json`, tries curated sources by keyword match, and falls back to Tavily web search. Fetches through SSRF-mitigated Worker proxy; HTML-strips and saves with frontmatter-cited origin. Plugs directly into the wiki.
- **Cache-aware telemetry.** Every Computer Use run logs the three Anthropic input-token buckets (cache_read, cache_creation, input) plus output tokens, wall-clock, and screenshot count into JSONL per-run files and a `rollup.log` one-liner. Schema-versioned (currently v2). This is the instrumentation a production AI system needs to actually be optimized.
- **Perceptual-hash stuck detection.** The Computer Use loop computes a perceptual hash of consecutive screenshots; if the screen isn't changing, the run is declared stuck and the loop breaks. Prevents runaway token spend on broken agent loops.
- **PII stripper.** Stateless regex-based scrubber for SSNs, credit card numbers, API keys, bearer tokens, JWTs, and `password=`-style secrets. Runs *before* session logs are compressed into the wiki. Email domains are preserved so Claude retains context; phone numbers are intentionally left alone (documented decision).

### Build Quality Signals

- Clean MVVM architecture with `@MainActor` isolation and async/await throughout.
- A shared `CursorPillBubble` + `CursorPillTypewriter` renderer factored out so nav-pointing and consent prompts use identical code paths — backed by 24 XCTest snapshot cases (6 states × 2 surfaces × 2 color modes) at `precision: 0.99` / `perceptualPrecision: 0.98`.
- A CI smoke test (`OneShotAutomationSmokeTest.swift`) that gates on `CI_SMOKE_TESTS_ENABLED=1` and verifies Chrome's address bar reflects the expected URL after a synthetic utterance. Keeps the automation escape hatch from rotting.
- SQLite-backed persistence (via built-in `libsqlite3`, no external dependency) for lesson progress, session metadata, tutor nudge rate limiting, confidence scores with time-based decay, and `computer_use_runs` analytics.

---

## 3. Ethical Alignment

Building an AI assistant that can *see your screen* and *control your computer* is a responsibility we took seriously. The design surface here is unusually dense with potential harms. We enumerate them here and describe the specific mitigations built into the codebase — not as afterthoughts but as first-class design decisions.

### Risk 1: Privacy — screenshots contain sensitive information

**The concern.** Every push-to-talk sends a screenshot to Claude. Screens contain passwords, medical records, financial data, private messages.

**Mitigations built in.**
- **No persistent storage of screenshots by default.** Screenshots are held in memory for the single request and discarded. The raw image is never written to disk in normal operation.
- **PII stripper before session compression.** When session logs are compressed into the wiki, the `PIIStripper` regex-replaces SSNs, credit cards, API keys, bearer tokens, JWTs, and `password=` secrets with deterministic placeholders. Email domains are preserved (documented trade-off for context retention); phone numbers are intentionally left alone and that choice is documented.
- **Cloudflare Worker proxy.** The app never talks directly to Anthropic, ElevenLabs, AssemblyAI, or OpenAI. All traffic goes through a Worker where we control logging, rate limits, and retention. API keys live as Worker secrets, never in the binary.
- **Screen recording permission is explicit.** macOS forces the user through the TCC permission flow; the app cannot capture without explicit consent, and the consent is revocable from System Settings at any time.

### Risk 2: Automation — an AI controlling the user's computer

**The concern.** Computer Use agent loops can take destructive actions. A misread screen plus a misfired click can do real damage (deleted files, sent emails, posted embarrassing content).

**Mitigations built in.**
- **Automation is opt-in, twice.** The feature is gated on either `isAutomationExperimentalEnabled` *or* `isTutorModeEnabled` being explicitly turned on in the menu bar panel. Then, every individual sequence requires per-sequence consent via the terracotta cursor-adjacent prompt (`CursorBubbleConsentPromptController`). The user says yes to *this specific automation*, not to automation in general.
- **Shared `AutomationSafetyPolicy` deny-list.** Banking apps, password managers, and other high-stakes bundles are denied at the action executor level. The Computer Use loop *breaks on first deny-list refusal* and surfaces a `ComputerUseRefusal` — the loop does not try to work around the block.
- **Kill switch.** `AutomationEngine.requestHaltOfCurrentSequence()` is reachable from the menu bar at all times. One click stops everything.
- **Before/after screenshot logging.** Every automation action writes before/after screenshots to `raw/automation-actions.log`. If something went wrong, it's auditable.
- **Default path is Computer Use API, not blind one-shot.** The Computer Use loop is self-correcting — it takes a fresh screenshot after each step and re-plans. The local one-shot CGEvent path (which is more dangerous because it doesn't verify outcomes) is demoted to a debug escape hatch hidden behind an Option-key-held submenu. The default experience is the safer one.
- **Perceptual-hash stuck detection** prevents runaway loops that rack up cost and risk on broken sequences.

### Risk 3: Learned helplessness — AI replacing skill instead of building it

**The concern.** It's easy to build an AI that makes users dependent. "Just ask Claude to do it for you" is a failure mode for an education product. A student who graduates having never learned Xcode, because ClaudeCursor clicked the buttons for them, is worse off than one who never used ClaudeCursor.

**Mitigations built in.**
- **Pointing, not doing, is the default.** The primary Claude tool is `point_at_element` — it moves a cursor to the right place and narrates what it is. The user still performs the action. This preserves motor memory and agency.
- **Tutor mode is designed around observation, not intervention.** The `UserActivityIdleDetector` only triggers a nudge after 3 seconds of idle (documented stuck state), and the `ProactiveTutorPromptController` asks the user before explaining. The system observes silently and intervenes only when invited.
- **The "empowerment not replacement" principle is in the interaction grammar.** The cursor points. The voice narrates. The user acts. Only when the user explicitly opts into automation does Claude click anything.
- **Lesson mode is structured like a real course.** Sequential steps, a thumbnail strip, previous/next controls. Users progress; they aren't served outcomes.

### Risk 4: Hallucination — Claude confidently pointing at the wrong thing

**The concern.** Vision models can misidentify UI elements. A confident wrong answer is worse than no answer, especially for novice users who trust the cursor because they don't yet know where things are.

**Mitigations built in.**
- **`ElementLocationDetector` validates coordinates** before the cursor flies. If the claimed location doesn't match something element-like in the screenshot, the tool call degrades gracefully instead of pointing at empty space.
- **Non-activating overlay.** If Claude is wrong, it is extremely easy to ignore — the cursor is a translucent label pill, not a modal, not a forced workflow. The user's real cursor and keyboard focus are untouched.
- **Multi-cursor `explain_screen_elements` shows reasoning.** When Claude labels eight elements at once, the user gets a visual audit of what Claude thinks it's seeing, which surfaces misidentifications early.

### Risk 5: Demographic and language bias

**The concern.** Claude's training data underrepresents certain languages, dialects, software ecosystems, and user demographics. An AI tutor that silently fails for some groups reinforces the gap it claims to close.

**Honest acknowledgment.** Claude is strongest in English and a set of major world languages. It is stronger on mainstream macOS/Windows software than on regional or niche tools. It may misidentify screens for users whose OS is in a language it's weaker in. We do not claim to have solved this; we flag it.

**Mitigations built in.**
- **Multilingual transcription.** AssemblyAI streaming supports dozens of languages; Apple Speech falls back to on-device locales.
- **Provider fallback chain.** If the primary transcription provider fails for a given language, the pipeline degrades to other providers rather than silently failing.
- **The Worker proxy is the lever for future equity work.** Because cost is brokered centrally, we can subsidize API credits for under-served language cohorts without asking users to pay more.

### Risk 6: Misuse — someone using the app for social engineering, fraud, scraping, or harassment

**The concern.** A general-purpose screen-aware, voice-driven automation tool is inherently dual-use.

**Mitigations built in.**
- **Deny-list on high-stakes bundles.** Password managers and banking apps are refused at the executor level.
- **Refusal breaks the loop on first hit.** Claude's own refusals surface as `ComputerUseRefusal` and are logged as `run_refused` JSONL events — the loop does not retry-until-it-complies. This is critical: many agent implementations loop until Claude caves, which undermines Anthropic's safety training. We do the opposite.
- **Auditability.** Every automation run produces a JSONL log plus a `rollup.log` line. A deployer can review the full action history of an install.
- **No credential autofill, no stored credentials.** The app never touches the system keychain or any password autofill surface.

### Risk 7: Cost asymmetry — AI access is expensive, and the people who most need it can afford it least

**The concern.** Without intervention, this becomes another tool that benefits the already-resourced.

**The structural answer.** The Worker proxy architecture decouples user cost from Anthropic's per-token pricing. A downstream deploy — a library system, a university, a workforce program, a nonprofit — can run the Worker with their own keys and subsidize usage for the population they serve. This is not a feature we built; it's a deployment shape the architecture enables by design.

---

## 4. Presentation

### The Story

**Act 1 — the universal experience.** *Every single person in this room has been stuck in front of a screen at some point, looking at a button they don't know what does, and felt stupid. That feeling is expensive. It keeps people out of jobs, off healthcare, off benefits, out of skilled work. The gap between "I want to do this thing on a computer" and "I did it" is the most underrated equity problem in tech.*

**Act 2 — why existing solutions don't close the gap.** Video tutorials are frozen in time and generic. Documentation assumes you know the vocabulary. Chatbots can describe but can't see. Tutors cost money and sleep. The gap stays open.

**Act 3 — the product.** ClaudeCursor sits in your menu bar. You hold `ctrl+option`, ask a question in plain voice, and a blue cursor flies to the answer on your screen while Claude narrates what it is. When you're really stuck, it can walk you through a YouTube tutorial step-by-step, pointing at each thing as the video talks about it. When you opt in, it can take the wheel briefly — with consent, with a kill switch, with a deny-list — and do a task for you. The entire product is built around one principle: *learning happens when someone can see what you see, at the moment you need them.*

**Act 4 — demo.** Live, on stage.

**Act 5 — what's at stake.** A grandmother books her own telehealth appointment. A community college student ships her first iOS app. A small business owner actually uses the CRM he's paying for. That's the outcome. That's the measurement.

### Suggested Demo Script (3 minutes)

1. **(0:00 – 0:30) Open Xcode from scratch.** "I've never opened Xcode before." Hold ctrl+option: *"How do I start a new iOS project?"* Cursor points at "Create New Project," narrates, you click. Cursor points at "App" template. You click. Cursor points at the product name field. Narrate the point: *Claude is not doing this for me. I'm doing it. It's just showing me where.*
2. **(0:30 – 1:15) Switch to MyChart on a second screen.** Same hotkey: *"Where do I see my lab results?"* Cursor jumps across monitors, lands on the right tab. Narrate: *My grandma can do this. She can ask in her own voice. She doesn't have to wait for me to drive over.*
3. **(1:15 – 2:00) Figma.** *"Review this mockup and point out three hierarchy issues."* Multi-cursor `explain_screen_elements` deploys three colored sub-cursors on the problem areas. Narrate: *It's not just pointing. It's teaching. It's design critique the way a senior designer would do it.*
4. **(2:00 – 2:40) Automation with consent.** Toggle experimental automation on. *"Fill in this form with the following information."* The terracotta consent pill appears. You accept. Claude fills three fields, stops on a CAPTCHA (deny-list / stuck detection). Narrate: *It asked before it did anything. It stopped when it wasn't sure. That's the design.*
5. **(2:40 – 3:00) The pitch line.** *"Every feature you just saw exists because somewhere, someone was stuck on something they wanted to learn. That person is our user. That's the whole product."*

### Key Differentiators (One-Liners)

- **Not ChatGPT with a screenshot.** ChatGPT describes; ClaudeCursor points. Pointing is the primitive. Narration is secondary. Automation is opt-in.
- **Not a ChatGPT wrapper.** Seven Claude-powered subsystems (chat, tool-use, Computer Use, wiki compression, session observation, page consolidation, cold-start recap), a hybrid automation model, a full voice pipeline with three-provider fallback, multi-monitor cursor overlay, YouTube lesson extractor, memory wiki, cache-aware telemetry — this is a *product*, not a prompt.
- **Designed around "empowerment, not replacement."** The default interaction is pointing. Automation is gated twice. Tutor mode observes before it intervenes. The grammar of the product is *show, don't do*.
- **Ethics isn't a slide, it's in the codebase.** PII stripping. Consent prompts. Deny-lists. Kill switch. Refusal-breaks-loop. Perceptual-hash stuck detection. Before/after logging. These are shipped, not aspirational.
- **Works with any app.** No integrations, no APIs, no partnerships required. If it runs on macOS, ClaudeCursor can teach you to use it.

### What Judges Will Likely Ask, and How to Answer

- *"Isn't this just accessibility software?"* — Accessibility is one use case, and an important one. But the problem is universal: anyone learning any new tool is temporarily "accessibility-impaired" by unfamiliarity. We're building a companion for *novices of any age*, not a tool for a single diagnosis.
- *"How is this different from Apple's upcoming Siri or Microsoft's Copilot?"* — Those are OS-vendor products that work within one ecosystem and optimize for task completion. ClaudeCursor is designed around pedagogy — *pointing so you learn* — and works on any app on macOS today. We also ship a hybrid automation model with meaningful safety work that first-party OS agents haven't publicly committed to.
- *"How do you make money?"* — Three credible paths: (1) consumer freemium with API subsidy, (2) institutional licenses for libraries, universities, workforce programs, and assistive-tech budgets, (3) white-label deployments for software vendors who want an embedded trainer in their product. We are not trying to answer this fully during a hackathon; the point is that credible paths exist.
- *"What's the moat?"* — The memory wiki + in-app telemetry + deep OS integration compound. A Claude wrapper is trivial to clone. A stateful, multimodal, screen-aware companion that has been trained on months of a specific user's tool usage is not.
- *"What could go wrong that you haven't thought about?"* — The honest answer: users who interpret Claude's narration as authoritative in domains where it isn't (medical, legal, financial). Today we rely on Claude's built-in caution plus the non-authoritative framing of the voice output. The next work is explicit domain-class detection and explicit "this is not advice" framing for those cases.

### Closing Line for the Pitch

*The ceiling on human capability isn't intelligence anymore; it's how fast we can learn the next tool. ClaudeCursor is the friend who sits next to you while you learn — for everyone who doesn't have one.*
