//
//  RichMarkdownContent.swift
//  claude-cursor
//
//  Shared markdown + LaTeX rendering for surfaces that show Claude responses
//  (answer panel, chat transcript). Native `AttributedString` for common
//  markdown; WKWebView + MathJax + marked.js when the text contains math
//  delimiters or fenced code blocks.
//

import SwiftUI
import WebKit

// MARK: - Detection + AttributedString

enum RichMarkdownContent {
    /// Returns true when the text likely needs the MathJax web renderer.
    /// False positives only swap renderers; false negatives leave raw `$$`.
    static func containsLaTeXOrFencedCode(rawText: String) -> Bool {
        if rawText.contains("$$") { return true }
        if rawText.contains("\\("), rawText.contains("\\)") { return true }
        if rawText.contains("\\["), rawText.contains("\\]") { return true }
        if rawText.contains("```") { return true }
        return false
    }

    /// Parses markdown into `AttributedString`, falling back to plain text.
    static func attributedStringFromMarkdownLossy(rawText: String) -> AttributedString {
        guard !rawText.isEmpty else {
            return AttributedString("")
        }
        let markdownParsingOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsedAttributedString = try? AttributedString(
            markdown: rawText,
            options: markdownParsingOptions
        ) {
            return parsedAttributedString
        }
        return AttributedString(rawText)
    }
}

// MARK: - MathJax Web View

/// WKWebView-backed SwiftUI view: markdown via marked.js, LaTeX via MathJax.
/// CDN-hosted; same tradeoffs as the answer panel (expects network when math loads).
///
/// When `reportContentHeight` is non-nil (chat bubbles), the document height is
/// posted from JS after MathJax typesets so SwiftUI can size the web view to
/// fit and avoid nested scrolling inside the transcript `ScrollView`.
struct MathJaxMarkdownWebView: NSViewRepresentable {
    let responseText: String
    var reportContentHeight: Binding<CGFloat>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.suppressesIncrementalRendering = true

        if reportContentHeight != nil {
            webViewConfiguration.userContentController.add(
                context.coordinator,
                name: Coordinator.contentHeightMessageHandlerName
            )
        }

        let mathJaxWebView = WKWebView(
            frame: .zero,
            configuration: webViewConfiguration
        )
        mathJaxWebView.setValue(false, forKey: "drawsBackground")
        if reportContentHeight != nil {
            mathJaxWebView.navigationDelegate = context.coordinator
            // `WKWebView.scrollView` is UIKit-only. On macOS, `reportContentHeight`
            // sizes the web view to the document height so the transcript ScrollView
            // owns vertical scrolling.
        }

        context.coordinator.loadedResponseText = responseText
        mathJaxWebView.loadHTMLString(
            buildMathJaxHTMLShell(
                forResponseText: responseText,
                reportsIntrinsicHeightToNative: reportContentHeight != nil
            ),
            baseURL: nil
        )
        return mathJaxWebView
    }

    func updateNSView(_ mathJaxWebView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedResponseText != responseText else { return }
        context.coordinator.loadedResponseText = responseText
        mathJaxWebView.loadHTMLString(
            buildMathJaxHTMLShell(
                forResponseText: responseText,
                reportsIntrinsicHeightToNative: reportContentHeight != nil
            ),
            baseURL: nil
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let contentHeightMessageHandlerName = "claudeCursorMathJaxContentHeight"

        var parent: MathJaxMarkdownWebView
        var loadedResponseText: String = ""

        init(_ parent: MathJaxMarkdownWebView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.contentHeightMessageHandlerName,
                  let body = message.body as? NSNumber else { return }
            let heightPoints = CGFloat(truncating: body)
            let minimumChatMathBubbleHeight: CGFloat = 96
            let clampedHeight = max(minimumChatMathBubbleHeight, heightPoints)
            DispatchQueue.main.async { [weak self] in
                self?.parent.reportContentHeight?.wrappedValue = clampedHeight
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard parent.reportContentHeight != nil else { return }
            reportHeightViaJavaScript(webView: webView)
        }

        private func reportHeightViaJavaScript(webView: WKWebView) {
            let heightScript = """
            (function() {
                var body = document.body;
                var html = document.documentElement;
                return Math.max(
                    body.scrollHeight, body.offsetHeight,
                    html.clientHeight, html.scrollHeight, html.offsetHeight
                );
            })();
            """
            webView.evaluateJavaScript(heightScript) { [weak self] result, _ in
                guard let self,
                      let number = result as? NSNumber else { return }
                let heightPoints = CGFloat(truncating: number)
                let minimumChatMathBubbleHeight: CGFloat = 96
                let clampedHeight = max(minimumChatMathBubbleHeight, heightPoints)
                DispatchQueue.main.async {
                    self.parent.reportContentHeight?.wrappedValue = clampedHeight
                }
            }
        }
    }

    private func buildMathJaxHTMLShell(
        forResponseText responseText: String,
        reportsIntrinsicHeightToNative: Bool
    ) -> String {
        let escapedResponseText = responseText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "</", with: "<\\/")

        let handlerName = Coordinator.contentHeightMessageHandlerName
        let bodyScript: String
        if reportsIntrinsicHeightToNative {
            bodyScript = """
            function reportMathJaxContentHeightForChat() {
                var body = document.body;
                var html = document.documentElement;
                var height = Math.max(
                    body.scrollHeight, body.offsetHeight,
                    html.clientHeight, html.scrollHeight, html.offsetHeight
                );
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers["\(handlerName)"]) {
                    window.webkit.messageHandlers["\(handlerName)"].postMessage(height);
                }
            }
            const rawResponseText = `\(escapedResponseText)`;
            const renderedHTML = marked.parse(rawResponseText, { breaks: true });
            document.getElementById('responseBody').innerHTML = renderedHTML;
            if (window.MathJax && window.MathJax.typesetPromise) {
                window.MathJax.typesetPromise()
                    .then(function () { reportMathJaxContentHeightForChat(); })
                    .catch(function () { reportMathJaxContentHeightForChat(); });
            } else {
                reportMathJaxContentHeightForChat();
            }
            setTimeout(reportMathJaxContentHeightForChat, 450);
            setTimeout(reportMathJaxContentHeightForChat, 1200);
            """
        } else {
            bodyScript = """
            const rawResponseText = `\(escapedResponseText)`;
            const renderedHTML = marked.parse(rawResponseText, { breaks: true });
            document.getElementById('responseBody').innerHTML = renderedHTML;
            if (window.MathJax && window.MathJax.typesetPromise) {
                window.MathJax.typesetPromise();
            }
            """
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body {
                margin: 0;
                padding: 14px 16px;
                background: transparent;
                color: rgba(255,255,255,0.92);
                font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                line-height: 1.55;
                -webkit-font-smoothing: antialiased;
            }
            h1, h2, h3 { margin: 0.8em 0 0.4em 0; color: rgba(255,255,255,0.98); }
            h1 { font-size: 1.25em; }
            h2 { font-size: 1.12em; }
            h3 { font-size: 1.02em; font-weight: 600; }
            p { margin: 0.4em 0; }
            ul, ol { margin: 0.4em 0; padding-left: 1.3em; }
            li { margin: 0.15em 0; }
            code {
                font-family: "SF Mono", Menlo, Consolas, monospace;
                font-size: 0.92em;
                background: rgba(255,255,255,0.08);
                padding: 1px 5px;
                border-radius: 4px;
            }
            pre {
                background: rgba(255,255,255,0.06);
                border: 1px solid rgba(255,255,255,0.08);
                border-radius: 6px;
                padding: 10px 12px;
                overflow-x: auto;
                font-size: 0.92em;
            }
            pre code {
                background: transparent;
                padding: 0;
            }
            a { color: #6bb8ff; }
            blockquote {
                margin: 0.6em 0;
                padding: 0.2em 0.9em;
                border-left: 2px solid rgba(255,255,255,0.2);
                color: rgba(255,255,255,0.75);
            }
            .MathJax { color: rgba(255,255,255,0.95); }
        </style>
        <script>
            window.MathJax = {
                tex: {
                    inlineMath: [['\\\\(', '\\\\)']],
                    displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']]
                },
                svg: { fontCache: 'global' }
            };
        </script>
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js" async></script>
        </head>
        <body>
        <div id="responseBody"></div>
        <script>
        \(bodyScript)
        </script>
        </body>
        </html>
        """
    }
}
