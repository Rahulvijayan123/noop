import StrandDesign
import SwiftUI
import UIKit
import WebKit

// Open Generative UI for Sana (after CopilotKit/OpenIntelligentUI's `generateSandboxedUi`): the coach's visual
// pipeline can answer with a small HTML, CSS and JavaScript tool, which runs here in a web view that can reach
// nothing. The content security policy allows inline script and style only, so there is no network, no frames,
// no forms and no storage; every navigation after the first load is cancelled and pop-ups are refused. The tool
// talks to the app through one bridge: its height, and a follow-up question that is accepted only right after a
// real tap on the tool.

/// Sends a follow-up question as the user. Set by the bubble; nil where a tool must not ask anything.
private struct CoachSandboxSendKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }

extension EnvironmentValues {
    var coachSandboxSend: ((String) -> Void)? {
        get { self[CoachSandboxSendKey.self] }
        set { self[CoachSandboxSendKey.self] = newValue }
    }
}

struct CoachSandboxedUIView: View {
    let custom: CoachViz.Custom
    let title: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coachSandboxSend) private var send
    @State private var measured: CGFloat?

    static let minHeight: CGFloat = 120
    static let maxHeight: CGFloat = 640

    private var height: CGFloat {
        let wanted = measured ?? CGFloat(custom.height ?? 300)
        return min(Self.maxHeight, max(Self.minHeight, wanted))
    }

    var body: some View {
        CoachSandboxWebView(document: CoachSandboxDocument.html(custom, dark: colorScheme == .dark),
                            maxHeight: Self.maxHeight,
                            onHeight: { measured = $0 },
                            onSend: send)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Interactive tool: \(title)")
    }
}

// MARK: - Document

enum CoachSandboxDocument {
    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; "
        + "font-src data:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; "
        + "worker-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'"

    /// The whole page: policy first, then the app's theme, then the tool. The tool's CSS and script can't close
    /// their own element early.
    static func html(_ custom: CoachViz.Custom, dark: Bool) -> String {
        let css = custom.css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        let js = custom.js.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>\(theme(dark: dark))\(baseCSS)</style>
        <style>\(css)</style>
        </head><body><div id="nara-root">\(custom.html)</div>
        <script>try {
        \(js)
        } catch (e) { window.nara && window.nara._error(String(e && e.message || e)); }</script>
        <script>window.nara && window.nara.resize();</script>
        </body></html>
        """
    }

    private static func theme(dark: Bool) -> String {
        let style = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func css(_ color: Color, alpha: CGFloat? = nil) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).resolvedColor(with: style).getRed(&r, green: &g, blue: &b, alpha: &a)
            let channel = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
            return "rgba(\(channel(r)),\(channel(g)),\(channel(b)),\(String(format: "%.3f", alpha ?? a)))"
        }
        let series = CoachVizPalette.series.prefix(6).enumerated()
            .map { "--series-\($0.offset + 1):\(css($0.element));" }
            .joined()
        return ":root{color-scheme:\(dark ? "dark" : "light");"
            + "--text:\(css(StrandPalette.textPrimary));--text-2:\(css(StrandPalette.textSecondary));"
            + "--text-3:\(css(StrandPalette.textTertiary));--accent:\(css(StrandPalette.accent));"
            + "--accent-soft:\(css(StrandPalette.accent, alpha: 0.14));--on-accent:\(css(StrandPalette.surfaceBase));"
            + "--surface:\(css(StrandPalette.surfaceRaised));"
            + "--surface-inset:\(css(StrandPalette.surfaceInset));--hairline:\(css(StrandPalette.hairline));"
            + "--positive:\(css(StrandPalette.statusPositive));--warning:\(css(StrandPalette.statusWarning));"
            + "--critical:\(css(StrandPalette.statusCritical));\(series)"
            + "--radius:12px;--font:ui-rounded,-apple-system,system-ui,sans-serif;}"
    }

    private static let baseCSS = """
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    html,body{margin:0;padding:0;background:transparent;color:var(--text);font:15px/1.4 var(--font);-webkit-text-size-adjust:100%;-webkit-user-select:none;user-select:none}
    #nara-root{padding:2px 0 4px;display:flow-root}
    h1,h2,h3,h4{margin:0 0 6px;font-weight:600;line-height:1.25}h1{font-size:20px}h2{font-size:17px}h3,h4{font-size:15px}
    p{margin:0 0 8px}small,.muted{color:var(--text-3);font-size:13px}
    .value{font-size:28px;font-weight:600;font-variant-numeric:tabular-nums;color:var(--text)}
    .row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.stack{display:flex;flex-direction:column;gap:10px}
    .grid2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
    .box{background:var(--surface-inset);border-radius:var(--radius);padding:12px}
    .pill{display:inline-block;padding:3px 10px;border-radius:999px;background:var(--accent-soft);color:var(--accent);font-size:12px;font-weight:600}
    button{font:600 14px var(--font);color:var(--on-accent);background:var(--accent);border:0;border-radius:999px;padding:9px 16px;min-height:36px;cursor:pointer}
    button.secondary{background:var(--surface-inset);color:var(--text)}button:active{opacity:.75}button:disabled{opacity:.45}
    input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:30px;background:transparent;margin:0}
    input[type=range]::-webkit-slider-runnable-track{height:4px;border-radius:2px;background:var(--hairline)}
    input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:24px;height:24px;border-radius:50%;background:var(--accent);margin-top:-10px;box-shadow:0 1px 3px rgba(0,0,0,.25)}
    input[type=number],input[type=text],input[type=time],select{font:15px var(--font);color:var(--text);background:var(--surface-inset);border:1px solid var(--hairline);border-radius:10px;padding:8px 10px;min-height:36px}
    input[type=checkbox],input[type=radio]{accent-color:var(--accent);width:20px;height:20px}
    label{font-size:13px;color:var(--text-2)}
    svg text{fill:var(--text-2);font-family:var(--font)}canvas,svg,img{max-width:100%}
    """

    /// Runs before the tool: the bridge, height reports, and errors.
    static let bridge = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.nara.postMessage(m); } catch (e) {} };
      let last = 0;
      const measure = () => {
        const root = document.getElementById('nara-root');
        if (!root) return;
        const h = Math.ceil(root.getBoundingClientRect().height);
        if (Math.abs(h - last) >= 1) { last = h; post({ type: 'height', value: h }); }
      };
      Object.defineProperty(window, 'nara', { value: Object.freeze({
        send: (text) => post({ type: 'send', text: String(text == null ? '' : text).slice(0, 400) }),
        resize: () => requestAnimationFrame(measure),
        _error: (message) => post({ type: 'error', message: String(message).slice(0, 200) }),
      }), writable: false, configurable: false });
      window.addEventListener('error', (e) => post({ type: 'error', message: String(e.message).slice(0, 200) }));
      document.addEventListener('DOMContentLoaded', () => {
        measure();
        const root = document.getElementById('nara-root');
        if (root && window.ResizeObserver) new ResizeObserver(measure).observe(root);
      });
      window.addEventListener('load', measure);
    })();
    """
}

// MARK: - Web view

private struct CoachSandboxWebView: UIViewRepresentable {
    let document: String
    let maxHeight: CGFloat
    let onHeight: (CGFloat) -> Void
    let onSend: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let c = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.dataDetectorTypes = []
        config.userContentController.addUserScript(
            WKUserScript(source: CoachSandboxDocument.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(WeakScriptHandler(c), name: "nara")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = c
        web.uiDelegate = c
        let touches = CoachSandboxTouchRecognizer()
        touches.onTouch = { [weak c] in c?.lastTouch = Date() }
        web.addGestureRecognizer(touches)
        c.web = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onHeight = onHeight
        c.onSend = onSend
        c.maxHeight = maxHeight
        guard c.loadedDocument != document else { return }
        c.load(document)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nara")
        web.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var onHeight: (CGFloat) -> Void = { _ in }
        var onSend: ((String) -> Void)?
        var maxHeight: CGFloat = 640
        var lastTouch = Date.distantPast
        private(set) var loadedDocument: String?
        private var allowNextLoad = false
        private var lastSend = Date.distantPast

        /// A follow-up is accepted only this soon after a finger was on the tool, and no more often than this.
        private static let touchWindow: TimeInterval = 2
        private static let sendCooldown: TimeInterval = 2

        func load(_ document: String) {
            loadedDocument = document
            allowNextLoad = true
            web?.loadHTMLString(document, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isDocument = navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.absoluteString == "about:blank"
            if allowNextLoad, isDocument {
                allowNextLoad = false
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let document = loadedDocument { load(document) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "height":
                guard let value = (body["value"] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return }
                let height = CGFloat(value)
                web?.scrollView.isScrollEnabled = height > maxHeight
                DispatchQueue.main.async { [onHeight] in onHeight(height) }
            case "send":
                guard let onSend, let raw = body["text"] as? String else { return }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let now = Date()
                guard (1...300).contains(text.count),
                      now.timeIntervalSince(lastTouch) <= Self.touchWindow,
                      now.timeIntervalSince(lastSend) >= Self.sendCooldown else { return }
                lastSend = now
                onSend(text)
            default:
                break
            }
        }
    }
}

/// Breaks the retain cycle the content controller would otherwise hold on the coordinator.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Notes every finger that lands on the tool without taking part in recognition, and stands the tab swipe down
/// while it is there, so dragging a slider sideways never changes tabs.
private final class CoachSandboxTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: () -> Void = {}
    private var scrubbing = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        if !scrubbing {
            scrubbing = true
            HorizontalScrubSurface.beginScrub()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { onTouch() }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func reset() {
        super.reset()
        if scrubbing {
            scrubbing = false
            HorizontalScrubSurface.endScrub()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
