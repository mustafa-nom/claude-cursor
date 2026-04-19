/**
 * ClaudeCursor Proxy Worker
 *
 * Proxies requests to upstream APIs so the app never ships with raw API keys.
 * Keys are stored as Cloudflare secrets and injected server-side.
 *
 * Routes:
 *   POST /chat                → Anthropic Messages API (streaming + Computer Use beta)
 *   POST /tts                 → ElevenLabs TTS API
 *   POST /transcribe-token    → AssemblyAI short-lived websocket token
 *   POST /youtube-transcript  → YouTube Innertube ANDROID API + watch-page fallback
 *   POST /whisper             → OpenAI Whisper transcription (uncaptioned-video fallback)
 *   POST /web-search          → Tavily web search (wiki auto-research fallback)
 *   POST /fetch-url           → Arbitrary URL fetch with text extraction (wiki ingest)
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  OPENAI_API_KEY: string;
  TAVILY_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (url.pathname === "/youtube-transcript") {
        return await handleYouTubeTranscript(request, env);
      }

      if (url.pathname === "/whisper") {
        return await handleWhisper(request, env);
      }

      if (url.pathname === "/web-search") {
        return await handleWebSearch(request, env);
      }

      if (url.pathname === "/fetch-url") {
        return await handleFetchURL(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  // Forward the anthropic-beta header from the client if present.
  // This is needed for Computer Use requests (element detection).
  const headers: Record<string, string> = {
    "x-api-key": env.ANTHROPIC_API_KEY,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
  };
  const betaHeader = request.headers.get("anthropic-beta");
  if (betaHeader) {
    headers["anthropic-beta"] = betaHeader;
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers,
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}

/**
 * Fetches the caption track for a YouTube video via YouTube's internal
 * Innertube API (IOS client context), then downloads the caption
 * content in XML/JSON3 format. Returns structured segments so the Swift
 * client can build a lesson.
 *
 * Request body: { videoID: string, preferredLanguage?: string }
 * Response: { segments: TranscriptSegment[], hasCaptions: boolean,
 *             captionTrackDescription?: string, fallbackReason?: string }
 *
 * The old approach (probing video.google.com/timedtext directly) broke
 * in mid-2025 when YouTube added a proof-of-origin token (pot) requirement.
 * The Innertube /youtubei/v1/player endpoint returns pre-authenticated
 * caption baseUrls that already carry the necessary tokens.
 *
 * YouTube deprecated the ANDROID Innertube client for caption access in
 * early 2026, so we now use the IOS client context instead. If the IOS
 * Innertube path fails, we fall back to scraping the YouTube watch page
 * HTML for the ytInitialPlayerResponse JSON, which contains the same
 * captionTracks structure.
 */
async function handleYouTubeTranscript(
  request: Request,
  _env: Env
): Promise<Response> {
  const requestJSON = (await request.json()) as {
    videoID?: string;
    preferredLanguage?: string;
  };
  const youtubeVideoID = requestJSON.videoID;
  const preferredLanguageCode = requestJSON.preferredLanguage || "en";

  if (!youtubeVideoID || typeof youtubeVideoID !== "string") {
    return new Response(
      JSON.stringify({ error: "videoID is required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const attemptLog: string[] = [];

  // --- Strategy 1: Direct Innertube IOS call (no watch page needed) ---
  // Calls the Innertube /player endpoint directly with a well-known API
  // key and IOS client context. Avoids the watch page fetch entirely,
  // which is critical for datacenter IPs (e.g. Cloudflare Workers) that
  // YouTube rate-limits on HTML page requests (429).
  let captionTracks = await fetchCaptionTracksViaDirectInnertube(
    youtubeVideoID,
    attemptLog
  );

  // --- Strategy 2: Watch page + Innertube IOS client ---
  // Fetch the watch page to get a dynamic API key, then call Innertube
  // with IOS context. Falls back here if the hardcoded API key in
  // Strategy 1 gets revoked.
  if (captionTracks === null || captionTracks.length === 0) {
    captionTracks = await fetchCaptionTracksViaWatchPageAndInnertube(
      youtubeVideoID,
      attemptLog
    );
  }

  // --- Strategy 3: Direct extraction from watch page HTML ---
  // Falls back to the ytInitialPlayerResponse embedded in the page.
  // These URLs may have exp=xpe and return empty, but it's worth trying.
  if (captionTracks === null || captionTracks.length === 0) {
    captionTracks = await fetchCaptionTracksViaWatchPageDirectExtraction(
      youtubeVideoID,
      attemptLog
    );
  }

  if (captionTracks === null || captionTracks.length === 0) {
    console.log(
      `[/youtube-transcript] no caption tracks for ${youtubeVideoID}: ${attemptLog.join(", ")}`
    );
    return new Response(
      JSON.stringify({
        segments: [],
        hasCaptions: false,
        fallbackReason: "no_caption_tracks_found",
        attemptLog,
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  }

  const selectedTrack = selectBestCaptionTrack(
    captionTracks,
    preferredLanguageCode
  );

  if (!selectedTrack) {
    console.log(
      `[/youtube-transcript] tracks found but none matched preferred language ${preferredLanguageCode} for ${youtubeVideoID}`
    );
    return new Response(
      JSON.stringify({
        segments: [],
        hasCaptions: false,
        fallbackReason: "no_matching_language_track",
        attemptLog,
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  }

  const trackDescription = `${selectedTrack.languageCode}${selectedTrack.isAutoGenerated ? "(asr)" : ""}`;

  const segments = await fetchTranscriptFromCaptionTrackURL(
    selectedTrack.baseUrl,
    youtubeVideoID,
    attemptLog
  );

  if (segments === null) {
    console.log(
      `[/youtube-transcript] caption track fetch/parse failed for ${youtubeVideoID}: ${attemptLog.join(", ")}`
    );
    return new Response(
      JSON.stringify({
        segments: [],
        hasCaptions: false,
        fallbackReason: "caption_content_fetch_failed",
        attemptLog,
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  }

  console.log(
    `[/youtube-transcript] success for ${youtubeVideoID}: ${trackDescription}, ${segments.length} segments`
  );

  return new Response(
    JSON.stringify({
      segments,
      hasCaptions: true,
      captionTrackDescription: trackDescription,
    }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

// MARK: - YouTube Innertube + Caption Track Helpers

interface CaptionTrackInfo {
  baseUrl: string;
  languageCode: string;
  isAutoGenerated: boolean;
  trackName: string;
}

const BROWSER_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const IOS_YOUTUBE_USER_AGENT =
  "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)";

// Well-known Innertube API key used by YouTube.js, yt-dlp, and other
// libraries. Works without fetching the watch page first — critical for
// datacenter IPs that YouTube rate-limits on HTML page requests.
const INNERTUBE_KNOWN_API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

/**
 * Calls Innertube /youtubei/v1/player directly with a well-known API key
 * and IOS client context. This avoids the watch page fetch entirely, which
 * is the only reliable path from datacenter IPs (Cloudflare Workers, etc.)
 * where YouTube aggressively rate-limits HTML page requests with 429s.
 *
 * If YouTube revokes this API key, we fall back to the watch-page-based
 * strategies which extract a fresh key from the page HTML.
 */
async function fetchCaptionTracksViaDirectInnertube(
  youtubeVideoID: string,
  attemptLog: string[]
): Promise<CaptionTrackInfo[] | null> {
  try {
    const innertubeURL = `https://www.youtube.com/youtubei/v1/player?key=${INNERTUBE_KNOWN_API_KEY}`;

    const innertubeRequestBody = {
      context: {
        client: {
          clientName: "IOS",
          clientVersion: "20.03.02",
          deviceMake: "Apple",
          deviceModel: "iPhone16,2",
          osName: "iPhone",
          osVersion: "18.2.1.22C161",
        },
      },
      videoId: youtubeVideoID,
    };

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10_000);

    const innertubeResponse = await fetch(innertubeURL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": IOS_YOUTUBE_USER_AGENT,
      },
      body: JSON.stringify(innertubeRequestBody),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!innertubeResponse.ok) {
      attemptLog.push(`direct_innertube:http_${innertubeResponse.status}`);
      return null;
    }

    const playerResponse = (await innertubeResponse.json()) as any;

    const playabilityStatus = playerResponse?.playabilityStatus?.status;
    if (playabilityStatus && playabilityStatus !== "OK") {
      attemptLog.push(`direct_innertube:playability_${playabilityStatus}`);
      return null;
    }

    const rawTracks =
      playerResponse?.captions?.playerCaptionsTracklistRenderer?.captionTracks;

    if (!rawTracks || !Array.isArray(rawTracks) || rawTracks.length === 0) {
      attemptLog.push("direct_innertube:no_caption_tracks");
      return null;
    }

    const parsedTracks: CaptionTrackInfo[] = rawTracks.map((track: any) => ({
      baseUrl: track.baseUrl as string,
      languageCode: (track.languageCode as string) || "unknown",
      isAutoGenerated: track.kind === "asr",
      trackName:
        track.name?.simpleText || track.name?.runs?.[0]?.text || "",
    }));

    attemptLog.push(`direct_innertube:ok_${parsedTracks.length}_tracks`);
    return parsedTracks;
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : String(error);
    attemptLog.push(`direct_innertube:error_${errorMessage}`);
    return null;
  }
}

/**
 * Fetches the YouTube watch page HTML, extracts the dynamic INNERTUBE_API_KEY,
 * then calls the Innertube /youtubei/v1/player endpoint with IOS client
 * context to get caption track metadata with valid auth tokens in the baseUrls.
 *
 * This two-step approach (watch page -> Innertube) is necessary because:
 *   - The hardcoded API key returns 400 "Precondition check failed" as of 2026
 *   - The API key extracted from the watch page works reliably
 *   - The IOS client context returns baseUrls without the `exp=xpe`/`pot`
 *     requirement that blocks direct timedtext access
 *
 * YouTube deprecated the ANDROID Innertube client for caption access in early
 * 2026. The IOS client (`clientName: "IOS"`) is the proven replacement, used
 * by yt-dlp, obsidian-yt-transcript, and other libraries.
 */
async function fetchCaptionTracksViaWatchPageAndInnertube(
  youtubeVideoID: string,
  attemptLog: string[]
): Promise<CaptionTrackInfo[] | null> {
  try {
    // Step 1: Fetch the watch page to get the dynamic API key
    const watchURL = `https://www.youtube.com/watch?v=${youtubeVideoID}&hl=en`;

    const pageController = new AbortController();
    const pageTimeoutId = setTimeout(() => pageController.abort(), 15_000);

    const watchPageResponse = await fetch(watchURL, {
      method: "GET",
      headers: {
        "User-Agent": BROWSER_USER_AGENT,
        Accept:
          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        Cookie: "CONSENT=PENDING+999",
      },
      signal: pageController.signal,
    });

    clearTimeout(pageTimeoutId);

    if (!watchPageResponse.ok) {
      attemptLog.push(`watch_page:http_${watchPageResponse.status}`);
      return null;
    }

    const htmlBody = await watchPageResponse.text();

    // Extract the dynamic INNERTUBE_API_KEY from the page HTML.
    const apiKeyMatch = htmlBody.match(
      /"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"/
    );

    if (!apiKeyMatch) {
      attemptLog.push("watch_page:no_innertube_api_key");
      return null;
    }

    const innertubeApiKey = apiKeyMatch[1];

    // Step 2: Call Innertube /youtubei/v1/player with IOS context
    const innertubeURL = `https://www.youtube.com/youtubei/v1/player?key=${innertubeApiKey}`;

    const innertubeRequestBody = {
      context: {
        client: {
          clientName: "IOS",
          clientVersion: "20.03.02",
          deviceMake: "Apple",
          deviceModel: "iPhone16,2",
          osName: "iPhone",
          osVersion: "18.2.1.22C161",
        },
      },
      videoId: youtubeVideoID,
    };

    const innertubeController = new AbortController();
    const innertubeTimeoutId = setTimeout(
      () => innertubeController.abort(),
      10_000
    );

    const innertubeResponse = await fetch(innertubeURL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": IOS_YOUTUBE_USER_AGENT,
      },
      body: JSON.stringify(innertubeRequestBody),
      signal: innertubeController.signal,
    });

    clearTimeout(innertubeTimeoutId);

    if (!innertubeResponse.ok) {
      attemptLog.push(`innertube:http_${innertubeResponse.status}`);
      return null;
    }

    const playerResponse = (await innertubeResponse.json()) as any;

    const playabilityStatus = playerResponse?.playabilityStatus?.status;
    if (playabilityStatus && playabilityStatus !== "OK") {
      attemptLog.push(`innertube:playability_${playabilityStatus}`);
      return null;
    }

    const rawTracks =
      playerResponse?.captions?.playerCaptionsTracklistRenderer?.captionTracks;

    if (!rawTracks || !Array.isArray(rawTracks) || rawTracks.length === 0) {
      attemptLog.push("innertube:no_caption_tracks");
      return null;
    }

    const parsedTracks: CaptionTrackInfo[] = rawTracks.map((track: any) => ({
      baseUrl: track.baseUrl as string,
      languageCode: (track.languageCode as string) || "unknown",
      isAutoGenerated: track.kind === "asr",
      trackName:
        track.name?.simpleText || track.name?.runs?.[0]?.text || "",
    }));

    attemptLog.push(`innertube:ok_${parsedTracks.length}_tracks`);
    return parsedTracks;
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : String(error);
    attemptLog.push(`innertube:error_${errorMessage}`);
    return null;
  }
}

/**
 * Fallback: extracts caption tracks directly from the ytInitialPlayerResponse
 * JSON embedded in the YouTube watch page HTML. These URLs may have the
 * exp=xpe flag which can cause empty responses, but we try them as a last
 * resort since the URL structure occasionally works for some videos.
 */
async function fetchCaptionTracksViaWatchPageDirectExtraction(
  youtubeVideoID: string,
  attemptLog: string[]
): Promise<CaptionTrackInfo[] | null> {
  try {
    const watchURL = `https://www.youtube.com/watch?v=${youtubeVideoID}&hl=en`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 15_000);

    const watchPageResponse = await fetch(watchURL, {
      method: "GET",
      headers: {
        "User-Agent": BROWSER_USER_AGENT,
        Accept:
          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        Cookie: "CONSENT=PENDING+999",
      },
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!watchPageResponse.ok) {
      attemptLog.push(`watch_page_direct:http_${watchPageResponse.status}`);
      return null;
    }

    const htmlBody = await watchPageResponse.text();

    const playerResponseMatch = htmlBody.match(
      /var\s+ytInitialPlayerResponse\s*=\s*(\{.+?\})\s*;\s*(?:var|<\/script>)/s
    );

    if (!playerResponseMatch) {
      attemptLog.push("watch_page_direct:no_ytInitialPlayerResponse");
      return null;
    }

    let playerResponse: any;
    try {
      playerResponse = JSON.parse(playerResponseMatch[1]);
    } catch {
      attemptLog.push("watch_page_direct:json_parse_failed");
      return null;
    }

    const rawTracks =
      playerResponse?.captions?.playerCaptionsTracklistRenderer?.captionTracks;

    if (!rawTracks || !Array.isArray(rawTracks) || rawTracks.length === 0) {
      attemptLog.push("watch_page_direct:no_caption_tracks");
      return null;
    }

    const parsedTracks: CaptionTrackInfo[] = rawTracks.map((track: any) => ({
      baseUrl: track.baseUrl as string,
      languageCode: (track.languageCode as string) || "unknown",
      isAutoGenerated: track.kind === "asr",
      trackName:
        track.name?.simpleText || track.name?.runs?.[0]?.text || "",
    }));

    attemptLog.push(`watch_page_direct:ok_${parsedTracks.length}_tracks`);
    return parsedTracks;
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : String(error);
    attemptLog.push(`watch_page_direct:error_${errorMessage}`);
    return null;
  }
}

/**
 * Picks the best caption track from the available list. Priority:
 *   1. Manual track matching preferred language (prefix match)
 *   2. Manual track in any language
 *   3. ASR track matching preferred language (prefix match)
 *   4. ASR track in any language
 *   5. First available track
 */
function selectBestCaptionTrack(
  tracks: CaptionTrackInfo[],
  preferredLanguageCode: string
): CaptionTrackInfo | null {
  if (tracks.length === 0) return null;

  const languageMatches = (trackLangCode: string) =>
    trackLangCode === preferredLanguageCode ||
    trackLangCode.startsWith(preferredLanguageCode + "-");

  const manualPreferredLanguage = tracks.find(
    (t) => !t.isAutoGenerated && languageMatches(t.languageCode)
  );
  if (manualPreferredLanguage) return manualPreferredLanguage;

  const manualAnyLanguage = tracks.find((t) => !t.isAutoGenerated);
  if (manualAnyLanguage) return manualAnyLanguage;

  const asrPreferredLanguage = tracks.find(
    (t) => t.isAutoGenerated && languageMatches(t.languageCode)
  );
  if (asrPreferredLanguage) return asrPreferredLanguage;

  const asrAnyLanguage = tracks.find((t) => t.isAutoGenerated);
  if (asrAnyLanguage) return asrAnyLanguage;

  return tracks[0];
}

/**
 * Fetches the actual caption content from a caption track baseUrl.
 * The ANDROID Innertube response includes baseUrls with fmt=srv3 by default.
 * We replace that with fmt=json3 to get structured JSON instead of XML.
 *
 * JSON3 format: { events: [{ tStartMs, dDurationMs, segs: [{ utf8 }] }] }
 */
async function fetchTranscriptFromCaptionTrackURL(
  captionBaseUrl: string,
  youtubeVideoID: string,
  attemptLog: string[]
): Promise<TranscriptSegment[] | null> {
  try {
    // Strip fmt=srv3 from the baseUrl (like youtube-transcript-api does).
    // Without a fmt param, the endpoint returns XML by default, which we
    // can parse reliably. We intentionally do NOT add fmt=json3 because
    // some caption URLs ignore the fmt override and return XML anyway.
    const captionFetchUrl = captionBaseUrl.replace(/&fmt=srv3/, "");

    console.log(
      `[/youtube-transcript] fetching caption content for ${youtubeVideoID}, url starts: ${captionFetchUrl.slice(0, 120)}...`
    );

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10_000);

    const captionResponse = await fetch(captionFetchUrl, {
      method: "GET",
      headers: {
        "User-Agent": BROWSER_USER_AGENT,
      },
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!captionResponse.ok) {
      attemptLog.push(`caption_fetch:http_${captionResponse.status}`);
      return null;
    }

    const responseText = await captionResponse.text();

    if (responseText.trim().length === 0) {
      attemptLog.push("caption_fetch:empty_response");
      return null;
    }

    // Try XML first (default format when fmt is stripped or absent)
    const xmlSegments = parseXMLCaptionsIntoSegments(responseText);
    if (xmlSegments.length > 0) {
      return xmlSegments;
    }

    // Try JSON3 as fallback (in case the URL returned JSON format)
    try {
      const json3Data = JSON.parse(responseText);
      const json3Segments = parseJSON3IntoSegments(json3Data);
      if (json3Segments.length > 0) {
        return json3Segments;
      }
    } catch {
      // Not JSON either
    }

    attemptLog.push(
      `caption_fetch:unparseable (first 100 chars: ${responseText.slice(0, 100)})`
    );
    return null;
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : String(error);
    attemptLog.push(`caption_fetch:error_${errorMessage}`);
    return null;
  }
}

// MARK: - JSON3 Caption Parsing

interface TranscriptSegment {
  start: number;
  duration: number;
  text: string;
}

/**
 * Parses YouTube's JSON3 caption format into structured segments.
 * JSON3 events look like:
 *   { tStartMs: 1234, dDurationMs: 5000, segs: [{ utf8: "Hello " }, { utf8: "world" }] }
 *
 * Events without a segs array are timing/style markers and are skipped.
 * Timestamps are in milliseconds and converted to seconds.
 */
function parseJSON3IntoSegments(json3Data: any): TranscriptSegment[] {
  const events = json3Data?.events;
  if (!Array.isArray(events)) return [];

  const segments: TranscriptSegment[] = [];

  for (const event of events) {
    if (!event.segs || !Array.isArray(event.segs)) continue;

    const segmentText = event.segs
      .map((seg: any) => seg.utf8 || "")
      .join("")
      .replace(/\n/g, " ")
      .trim();

    if (segmentText.length === 0) continue;

    const startSeconds =
      typeof event.tStartMs === "number" ? event.tStartMs / 1000 : 0;
    const durationSeconds =
      typeof event.dDurationMs === "number" ? event.dDurationMs / 1000 : 0;

    segments.push({
      start: startSeconds,
      duration: Math.max(0, durationSeconds),
      text: decodeHTMLEntities(segmentText),
    });
  }

  return segments;
}

/**
 * Fallback parser for XML/srv3 caption format. YouTube sometimes ignores
 * the fmt=json3 parameter and returns XML anyway (especially from
 * watch-page baseUrls). The XML format looks like:
 *   <transcript>
 *     <text start="1.23" dur="4.56">Caption text here</text>
 *     ...
 *   </transcript>
 */
function parseXMLCaptionsIntoSegments(xmlText: string): TranscriptSegment[] {
  const segments: TranscriptSegment[] = [];
  const textTagPattern = /<text\s+start="([^"]*)"(?:\s+dur="([^"]*)")?[^>]*>([\s\S]*?)<\/text>/g;

  let match: RegExpExecArray | null;
  while ((match = textTagPattern.exec(xmlText)) !== null) {
    const startSeconds = parseFloat(match[1]) || 0;
    const durationSeconds = parseFloat(match[2]) || 0;
    const rawCaptionText = match[3]
      .replace(/<[^>]*>/g, "")
      .replace(/\n/g, " ")
      .trim();

    if (rawCaptionText.length === 0) continue;

    segments.push({
      start: startSeconds,
      duration: Math.max(0, durationSeconds),
      text: decodeHTMLEntities(rawCaptionText),
    });
  }

  return segments;
}

/**
 * Decodes common HTML entities that YouTube sometimes embeds in caption text.
 */
function decodeHTMLEntities(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'");
}

/**
 * Proxies an audio payload to OpenAI's Whisper API for transcription. Used
 * as the fallback path when a YouTube video has no captions. The client
 * supplies the audio bytes (multipart/form-data with field "file") and
 * forwards additional form fields (model, response_format, etc.).
 */
async function handleWhisper(request: Request, env: Env): Promise<Response> {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.startsWith("multipart/form-data")) {
    return new Response(
      JSON.stringify({
        error: "Whisper requires multipart/form-data with a 'file' field",
      }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const response = await fetch(
    "https://api.openai.com/v1/audio/transcriptions",
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${env.OPENAI_API_KEY}`,
        // Do NOT set content-type here — fetch preserves the client's
        // multipart boundary when we pass request.body straight through.
        "content-type": contentType,
      },
      body: request.body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/whisper] OpenAI error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type":
        response.headers.get("content-type") || "application/json",
    },
  });
}

/**
 * Proxies a web search query to the Tavily API. Used by the wiki auto-
 * research pipeline when no curated doc source matches the query topic.
 *
 * Request body: {
 *   query: string,
 *   maxResults?: number,        // default 5, capped at 10
 *   searchDepth?: "basic" | "advanced",  // default "basic"
 *   includeAnswer?: boolean     // default false
 * }
 *
 * Response: Tavily's native JSON shape, pass-through from upstream.
 */
async function handleWebSearch(request: Request, env: Env): Promise<Response> {
  const requestPayload = (await request.json()) as {
    query?: string;
    maxResults?: number;
    searchDepth?: "basic" | "advanced";
    includeAnswer?: boolean;
  };

  const searchQueryString = requestPayload.query;
  if (!searchQueryString || typeof searchQueryString !== "string") {
    return new Response(
      JSON.stringify({ error: "query is required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // Clamp max_results so clients can't accidentally ask for 100+ results.
  // Tavily charges per-search not per-result, but keeping this bounded
  // prevents surprise response sizes.
  const cappedMaxResults = Math.min(
    10,
    Math.max(1, requestPayload.maxResults ?? 5)
  );

  const tavilyRequestBody = {
    api_key: env.TAVILY_API_KEY,
    query: searchQueryString,
    search_depth: requestPayload.searchDepth ?? "basic",
    max_results: cappedMaxResults,
    include_answer: requestPayload.includeAnswer ?? false,
    include_raw_content: false,
  };

  const tavilyResponse = await fetch("https://api.tavily.com/search", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(tavilyRequestBody),
  });

  if (!tavilyResponse.ok) {
    const errorBody = await tavilyResponse.text();
    console.error(`[/web-search] Tavily API error ${tavilyResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: tavilyResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(tavilyResponse.body, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Fetches an arbitrary URL server-side and returns the HTML body. Used by
 * the wiki ingest pipeline to pull curated doc pages without the client
 * needing to deal with CORS, redirects, or custom user-agent strings.
 *
 * Request body: {
 *   url: string,
 *   userAgent?: string  // optional override, defaults to a generic UA
 * }
 *
 * Response: {
 *   url: string,           // final URL after redirects
 *   status: number,        // upstream HTTP status
 *   contentType: string,
 *   body: string           // response body (HTML/plain text)
 * }
 *
 * Safety: only http(s) URLs are allowed. Localhost, private IPs, and
 * file:// URLs are rejected so this endpoint can't be abused to probe
 * internal networks (SSRF mitigation). Response body is truncated at
 * 500KB so a single call can't return an enormous payload.
 */
async function handleFetchURL(request: Request, env: Env): Promise<Response> {
  const requestPayload = (await request.json()) as {
    url?: string;
    userAgent?: string;
  };

  const targetURLString = requestPayload.url;
  if (!targetURLString || typeof targetURLString !== "string") {
    return new Response(
      JSON.stringify({ error: "url is required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  let parsedTargetURL: URL;
  try {
    parsedTargetURL = new URL(targetURLString);
  } catch {
    return new Response(
      JSON.stringify({ error: "url is not a valid URL" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // SSRF mitigation — only http(s), no localhost or private-range hosts.
  if (!(parsedTargetURL.protocol === "http:" || parsedTargetURL.protocol === "https:")) {
    return new Response(
      JSON.stringify({ error: "Only http and https URLs are allowed" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }
  const targetHostname = parsedTargetURL.hostname.toLowerCase();
  if (
    targetHostname === "localhost" ||
    targetHostname === "127.0.0.1" ||
    targetHostname === "::1" ||
    targetHostname.endsWith(".localhost") ||
    targetHostname.startsWith("10.") ||
    targetHostname.startsWith("192.168.") ||
    targetHostname.startsWith("169.254.") ||
    /^172\.(1[6-9]|2[0-9]|3[0-1])\./.test(targetHostname)
  ) {
    return new Response(
      JSON.stringify({ error: "Localhost and private-range URLs are blocked" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const userAgentForUpstream = requestPayload.userAgent
    ?? "ClaudeCursor/1.0 (+https://github.com/musnom/claudecursor)";

  const upstreamResponse = await fetch(parsedTargetURL.toString(), {
    method: "GET",
    headers: {
      "user-agent": userAgentForUpstream,
      accept: "text/html,application/xhtml+xml,text/plain,*/*",
    },
    redirect: "follow",
  });

  // Hard cap at 500KB so a huge upstream doesn't blow up the worker's
  // memory budget or the caller's download.
  const maxResponseBytesAllowed = 500 * 1024;
  const upstreamBodyText = await upstreamResponse.text();
  const truncatedBodyText = upstreamBodyText.length > maxResponseBytesAllowed
    ? upstreamBodyText.slice(0, maxResponseBytesAllowed)
    : upstreamBodyText;

  const responsePayload = {
    url: upstreamResponse.url,
    status: upstreamResponse.status,
    contentType: upstreamResponse.headers.get("content-type") ?? "text/plain",
    body: truncatedBodyText,
    wasTruncated: upstreamBodyText.length > maxResponseBytesAllowed,
  };

  return new Response(JSON.stringify(responsePayload), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
