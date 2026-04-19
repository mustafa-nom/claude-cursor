//
//  VideoPiPController.swift
//  claude-cursor
//
//  Picture-in-picture YouTube player for lesson mode. A small non-activating
//  NSPanel in the bottom-right corner hosts a WKWebView that loads the
//  YouTube IFrame Player API. The companion drives the player via injected
//  JavaScript — initial load/resume seek only; manual step next/prev does not
//  move playback. Polling reports current time so the overlay can auto-advance
//  when playback crosses a step boundary.
//
//  Why WKWebView + IFrame API (not AVPlayer):
//    - YouTube's ToS prohibit downloading and replaying videos locally
//      via AVPlayer, but the IFrame Player API is explicitly supported
//      for embedding. For V2 we pick the compliant path.
//    - The IFrame API surfaces playback controls, state changes, and
//      timestamp seeking via a simple JS bridge.
//
//  Panel behavior:
//    - Non-activating (ignores focus stealing) so the user keeps typing
//      in their target app while the video plays.
//    - Sized ~360x240 (16:9), positioned bottom-right with a 24px margin
//      from the visible frame of the primary screen.
//    - Movable by window background so the user can drag it if it covers
//      something important.
//    - Rounded corners aligned with the lesson pill; no contrasting stroke
//      so the pill + PiP read as one stack when anchored below the tip.
//
//  Worker vs client: lesson *captions* and step extraction use the Cloudflare
//  worker (`/youtube-transcript`). PiP *playback* is entirely in this
//  WKWebView embed — redeploying the worker does not fix IFrame error 152.
//

import AppKit
import WebKit
import SwiftUI

// MARK: - Delegate

/// Updates `VideoPiPController` emits as the YouTube player runs. The
/// companion wires these into the lesson state machine so step advance
/// can be driven by playback position.
@MainActor
protocol VideoPiPControllerDelegate: AnyObject {
    /// Called roughly once a second while the video is playing. Carries
    /// the current playback position in seconds.
    func videoPiPController(
        _ controller: VideoPiPController,
        didReportCurrentTimeSeconds currentTimeSeconds: Double
    )

    /// Called when the player enters a new play state (playing/paused/ended).
    /// The companion can use `.ended` to mark the lesson complete.
    func videoPiPController(
        _ controller: VideoPiPController,
        didChangePlaybackState newPlaybackState: VideoPiPPlaybackState
    )
}

/// High-level playback states reported by the YouTube IFrame API.
enum VideoPiPPlaybackState: String {
    case unstarted
    case playing
    case paused
    case buffering
    case ended
    case cued
    case unknown
}

// MARK: - Controller

/// Lifecycle + JS bridge for the PiP YouTube player. Create once per
/// lesson; call `loadVideo(...)` to swap videos without reloading the
/// panel. The WKWebView is reused across loads because WKWebView init is
/// surprisingly expensive (100+ ms), so keeping a single instance keeps
/// video swaps snappy.
@MainActor
final class VideoPiPController: NSObject {

    weak var delegate: VideoPiPControllerDelegate?

    private var pipPanel: NSPanel?
    private var youtubeWebView: WKWebView?
    private let playbackMessageHandlerName = "videoPiPPlaybackBridge"

    /// Bottom-right placement margin from the visible screen edges, in
    /// points. Matches other floating companion surfaces (answer panel,
    /// proactive prompt).
    private let screenEdgeMargin: CGFloat = 24

    /// Panel dimensions tuned to 16:9 at a size that's readable without
    /// covering a meaningful portion of the target app.
    private let pipPanelWidth: CGFloat = 360
    private let pipPanelHeight: CGFloat = 220

    /// The YouTube video ID currently loaded in the player, or nil if no
    /// video has been loaded yet. Used to avoid redundant reloads when
    /// the companion re-enters a lesson it was already showing.
    private(set) var currentlyLoadedYouTubeVideoID: String?

    // MARK: - Public API

    /// Shows the PiP panel, creating it on first call and reusing it
    /// thereafter. If the requested video differs from the currently
    /// loaded one, rewrites the WKWebView's HTML to swap videos.
    func showAndLoadVideo(
        youtubeVideoID: String,
        startAtTimeSeconds: Double
    ) {
        if pipPanel == nil {
            createPiPPanelAndWebView()
        }

        let videoNeedsLoadOrReload = currentlyLoadedYouTubeVideoID != youtubeVideoID
        if videoNeedsLoadOrReload {
            loadYouTubeIFramePlayerHTML(
                youtubeVideoID: youtubeVideoID,
                initialStartTimeSeconds: startAtTimeSeconds
            )
            currentlyLoadedYouTubeVideoID = youtubeVideoID
        } else {
            seekToTimestamp(targetTimeSeconds: startAtTimeSeconds)
        }

        positionPiPPanelInBottomRight()
        pipPanel?.alphaValue = 0.0
        pipPanel?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.5
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pipPanel?.animator().alphaValue = 1.0
        }
    }

    /// Seeks the current video to the given timestamp. No-op if the player
    /// hasn't loaded yet.
    func seekToTimestamp(targetTimeSeconds: Double) {
        let clampedTargetSeconds = max(0, targetTimeSeconds)
        let javaScriptForSeek = """
        if (window.claudeCursorYouTubePlayer && \
        typeof window.claudeCursorYouTubePlayer.seekTo === 'function') {
            window.claudeCursorYouTubePlayer.seekTo(\(clampedTargetSeconds), true);
            window.claudeCursorYouTubePlayer.playVideo();
        }
        """
        youtubeWebView?.evaluateJavaScript(javaScriptForSeek, completionHandler: nil)
    }

    /// Pauses playback. Useful when the companion enters answer mode mid-
    /// lesson and needs the video quiet while the user reads.
    func pausePlayback() {
        let javaScriptForPause = """
        if (window.claudeCursorYouTubePlayer && \
        typeof window.claudeCursorYouTubePlayer.pauseVideo === 'function') {
            window.claudeCursorYouTubePlayer.pauseVideo();
        }
        """
        youtubeWebView?.evaluateJavaScript(javaScriptForPause, completionHandler: nil)
    }

    /// Resumes playback after a pause.
    func resumePlayback() {
        let javaScriptForResume = """
        if (window.claudeCursorYouTubePlayer && \
        typeof window.claudeCursorYouTubePlayer.playVideo === 'function') {
            window.claudeCursorYouTubePlayer.playVideo();
        }
        """
        youtubeWebView?.evaluateJavaScript(javaScriptForResume, completionHandler: nil)
    }

    /// Hides the PiP panel with a fade-out animation, then removes it from
    /// the screen. The WKWebView is preserved so the next show is instant.
    func hidePiPPanel() {
        pausePlayback()
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = 0.3
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeIn)
            pipPanel?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.pipPanel?.orderOut(nil)
        })
    }

    /// Whether the PiP panel is currently on-screen.
    var isPiPPanelVisible: Bool {
        pipPanel?.isVisible ?? false
    }

    // MARK: - Panel Creation

    private func createPiPPanelAndWebView() {
        let webViewConfiguration = WKWebViewConfiguration()

        // Allow inline playback inside the embedded iframe rather than
        // forcing native fullscreen. Without this, tapping play on the
        // embedded video on macOS would sometimes pop into a separate
        // fullscreen player, stealing focus.
        webViewConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webViewConfiguration.allowsAirPlayForMediaPlayback = false
        webViewConfiguration.mediaTypesRequiringUserActionForPlayback = []

        // JS → native bridge: WKWebView calls
        // window.webkit.messageHandlers[name].postMessage(payload)
        // which invokes `userContentController(_:didReceive:)` below.
        let contentController = WKUserContentController()
        contentController.add(self, name: playbackMessageHandlerName)
        webViewConfiguration.userContentController = contentController

        let webViewFrame = NSRect(
            x: 0, y: 0,
            width: pipPanelWidth, height: pipPanelHeight
        )
        let webView = WKWebView(frame: webViewFrame, configuration: webViewConfiguration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.cornerRadius = DS.CornerRadius.large
        webView.layer?.masksToBounds = true

        let panel = NSPanel(
            contentRect: webViewFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Wrap the web view in a container view that draws a subtle border
        // + rounded mask, giving the PiP a consistent floating-surface
        // aesthetic with the rest of the companion.
        let containerView = NSView(frame: webViewFrame)
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = DS.CornerRadius.large
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderWidth = 0
        // Match lesson pill chrome (`DS.Colors.surface2` #202221) so the
        // stack reads as one floating surface instead of a bordered video box.
        containerView.layer?.backgroundColor = NSColor(
            calibratedRed: 32.0 / 255.0,
            green: 34.0 / 255.0,
            blue: 33.0 / 255.0,
            alpha: 1.0
        ).cgColor
        containerView.addSubview(webView)

        panel.contentView = containerView

        pipPanel = panel
        youtubeWebView = webView
    }

    private func positionPiPPanelInBottomRight() {
        guard let pipPanel,
              let primaryScreen = NSScreen.main else { return }
        let visibleFrame = primaryScreen.visibleFrame
        let panelOriginX = visibleFrame.maxX - pipPanelWidth - screenEdgeMargin
        let panelOriginY = visibleFrame.minY + screenEdgeMargin
        pipPanel.setFrame(
            NSRect(
                x: panelOriginX,
                y: panelOriginY,
                width: pipPanelWidth,
                height: pipPanelHeight
            ),
            display: true
        )
    }

    /// Positions the PiP panel directly below a given anchor rect (in
    /// screen coordinates). Used during lesson mode so the video sits
    /// right below the step pill. The PiP is horizontally centered on
    /// the anchor with a small vertical gap (~7pt) so the tip and PiP read as
    /// separate surfaces, clamped to the visible frame so it never goes off-screen.
    func positionPiPPanelBelowRect(anchorRect: NSRect) {
        guard let pipPanel else { return }
        let anchorCenter = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screenContainingAnchor = NSScreen.screens.first { screen in
            NSMouseInRect(anchorCenter, screen.frame, false)
        } ?? NSScreen.main
        guard let targetScreen = screenContainingAnchor else { return }
        let visibleFrame = targetScreen.visibleFrame

        let pipCenterX = anchorRect.midX - (pipPanelWidth / 2)
        // In AppKit coordinates, "below" means lower Y value. The NSPanel
        // frame often extends below the visible rounded card (layout + shadow
        // slack); pull the PiP up with `anchorBottomPullUpCompensation`, then
        // add `gapBetweenPillAndVideo` so there is visible air between card and video.
        let gapBetweenPillAndVideo: CGFloat = 7
        let anchorBottomPullUpCompensation: CGFloat = 52
        let pipOriginY =
            anchorRect.minY - pipPanelHeight - gapBetweenPillAndVideo
            + anchorBottomPullUpCompensation

        let clampedOriginX = max(
            visibleFrame.minX + screenEdgeMargin,
            min(pipCenterX, visibleFrame.maxX - pipPanelWidth - screenEdgeMargin)
        )
        let clampedOriginY = max(
            visibleFrame.minY + screenEdgeMargin,
            pipOriginY
        )

        pipPanel.setFrame(
            NSRect(
                x: clampedOriginX,
                y: clampedOriginY,
                width: pipPanelWidth,
                height: pipPanelHeight
            ),
            display: true
        )
    }

    // MARK: - YouTube IFrame API Integration

    /// Loads the YouTube IFrame Player API into the WKWebView with a
    /// lightweight HTML shell. The shell exposes a single global
    /// `window.claudeCursorYouTubePlayer` once the player is ready, which
    /// the native side then calls into via `evaluateJavaScript`.
    ///
    /// The shell posts playback state changes and current-time updates
    /// back to native via the `videoPiPPlaybackBridge` message handler.
    private func loadYouTubeIFramePlayerHTML(
        youtubeVideoID: String,
        initialStartTimeSeconds: Double
    ) {
        let clampedInitialStartSeconds = max(0, initialStartTimeSeconds)
        let htmlShellWithInjectedVideoID = Self.youTubeIFramePlayerHTMLTemplate
            .replacingOccurrences(of: "__VIDEO_ID__", with: youtubeVideoID)
            .replacingOccurrences(
                of: "__START_SECONDS__",
                with: String(format: "%.2f", clampedInitialStartSeconds)
            )
        // Base URL + nocookie host: helps some WKWebView embed / referrer
        // checks (error 152) while staying on the supported IFrame API path.
        let syntheticBaseURL = URL(string: "https://www.youtube-nocookie.com")!
        youtubeWebView?.loadHTMLString(
            htmlShellWithInjectedVideoID,
            baseURL: syntheticBaseURL
        )
    }

    /// HTML page that hosts the YouTube IFrame Player and forwards state
    /// changes + current-time updates to the native side. Kept as a
    /// static template so the video ID and start timestamp can be injected
    /// via simple string replacement.
    private static let youTubeIFramePlayerHTMLTemplate: String = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="referrer" content="strict-origin-when-cross-origin">
      <style>
        html, body {
          margin: 0;
          padding: 0;
          width: 100%;
          height: 100%;
          background: #000;
          overflow: hidden;
        }
        #claude-cursor-player-container {
          width: 100%;
          height: 100%;
        }
      </style>
    </head>
    <body>
      <div id="claude-cursor-player-container"></div>
      <script>
        const playbackStateCodeToName = {
          '-1': 'unstarted',
          '0': 'ended',
          '1': 'playing',
          '2': 'paused',
          '3': 'buffering',
          '5': 'cued'
        };

        function postMessageToNative(messagePayload) {
          try {
            window.webkit.messageHandlers.videoPiPPlaybackBridge.postMessage(messagePayload);
          } catch (error) {
            // Native bridge not available — swallow silently, this HTML
            // could also be loaded in a plain browser for debugging.
          }
        }

        // Load the YouTube IFrame API. Its loader defines a global
        // onYouTubeIframeAPIReady function which we implement below.
        const iframeAPIScriptTag = document.createElement('script');
        iframeAPIScriptTag.src = 'https://www.youtube.com/iframe_api';
        document.head.appendChild(iframeAPIScriptTag);

        let currentTimePollingIntervalID = null;

        window.onYouTubeIframeAPIReady = function () {
          window.claudeCursorYouTubePlayer = new YT.Player(
            'claude-cursor-player-container',
            {
              height: '100%',
              width: '100%',
              videoId: '__VIDEO_ID__',
              playerVars: {
                autoplay: 1,
                controls: 1,
                modestbranding: 1,
                rel: 0,
                fs: 0,
                playsinline: 1,
                start: Math.floor(__START_SECONDS__),
                origin: 'https://www.youtube-nocookie.com',
                enablejsapi: 1
              },
              events: {
                onReady: function () {
                  window.claudeCursorYouTubePlayer.seekTo(__START_SECONDS__, true);
                  window.claudeCursorYouTubePlayer.playVideo();
                  postMessageToNative({ type: 'playerReady' });
                  startCurrentTimePolling();
                },
                onStateChange: function (stateChangeEvent) {
                  const stateName = playbackStateCodeToName[String(stateChangeEvent.data)]
                    || 'unknown';
                  postMessageToNative({
                    type: 'playbackStateChange',
                    stateName: stateName
                  });
                }
              }
            }
          );
        };

        // Poll current time ~4x per second. The YT API doesn't emit
        // timestamp updates natively, but we need them so native can
        // advance lesson steps when the user crosses a boundary.
        function startCurrentTimePolling() {
          if (currentTimePollingIntervalID !== null) {
            clearInterval(currentTimePollingIntervalID);
          }
          currentTimePollingIntervalID = setInterval(function () {
            if (!window.claudeCursorYouTubePlayer) return;
            if (typeof window.claudeCursorYouTubePlayer.getCurrentTime !== 'function') return;
            const currentTimeSeconds = window.claudeCursorYouTubePlayer.getCurrentTime();
            postMessageToNative({
              type: 'currentTimeUpdate',
              currentTimeSeconds: currentTimeSeconds
            });
          }, 250);
        }
      </script>
    </body>
    </html>
    """
}

// MARK: - WKScriptMessageHandler

extension VideoPiPController: WKScriptMessageHandler {
    /// Receives playback state changes and current-time updates from the
    /// YouTube IFrame Player shell. Routes each payload to the delegate
    /// so the companion can react (advance steps, mark lesson complete).
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive scriptMessage: WKScriptMessage
    ) {
        guard scriptMessage.name == "videoPiPPlaybackBridge",
              let messagePayload = scriptMessage.body as? [String: Any],
              let messageType = messagePayload["type"] as? String else {
            return
        }

        Task { @MainActor in
            self.routeIncomingBridgeMessage(
                messageType: messageType,
                messagePayload: messagePayload
            )
        }
    }

    @MainActor
    private func routeIncomingBridgeMessage(
        messageType: String,
        messagePayload: [String: Any]
    ) {
        switch messageType {
        case "currentTimeUpdate":
            if let currentTimeSeconds = messagePayload["currentTimeSeconds"] as? Double {
                delegate?.videoPiPController(
                    self,
                    didReportCurrentTimeSeconds: currentTimeSeconds
                )
            }
        case "playbackStateChange":
            let stateName = (messagePayload["stateName"] as? String) ?? "unknown"
            let playbackState = VideoPiPPlaybackState(rawValue: stateName) ?? .unknown
            delegate?.videoPiPController(
                self,
                didChangePlaybackState: playbackState
            )
        case "playerReady":
            // Useful for logging; no specific delegate hook needed.
            print("🎬 VideoPiPController: YouTube player ready")
        default:
            break
        }
    }
}
