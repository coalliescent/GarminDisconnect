// WebChartView.swift
//
// Single WKWebView host that drives every chart in the app. There is exactly
// one of these in the application; it lives full-bleed beneath the toolbar in
// MainWindowController.
//
// JS contract:
//   `window.GarminDisconnect.render(payload)` — entry point. Dispatches on
//   `payload.chart` (a string id like "daily-steps-bar") and calls the matching
//   `renderXxx()` function in `charts.js`.
//
//   `window.GarminDisconnect.showTab(tabId)` — toggles which `<section>` is
//   visible. Called by Swift on tab segment change. The HTML host has one
//   section per top-level tab (overview/activities/wellness/sleep/sync); each
//   section contains the chart slots for that tab.
//
//   `window.webkit.messageHandlers.garminDisconnect.postMessage({event, …})` —
//   how the JS side talks back to Swift. Used for chart click events, the Sync
//   button, the activity-list row click, etc.
//
// Loading model:
//   - WKWebView loads `index.html` via `loadFileURL(_:allowingReadAccessTo:)`.
//     Without `allowingReadAccessTo`, sub-resource loads (Plotly.js, CSS) fail
//     with a CORS error.
//   - Payloads received before the page finished loading are queued and flushed
//     on `didFinish navigation:`.

import AppKit
import WebKit

/// Routes incoming JS messages to interested parties (e.g. SyncCoordinator).
/// MainWindowController registers as the delegate at startup.
protocol WebChartViewDelegate: AnyObject {
    func webChartView(_ view: WebChartView, didReceiveEvent event: String, payload: [String: Any])
}

final class WebChartView: NSView {

    // MARK: - State

    weak var delegate: WebChartViewDelegate?

    private let webView: WKWebView
    private var pageLoaded = false
    /// Payloads received before the page finished loading. Drained on `didFinish`.
    private var pendingPayloads: [[String: Any]] = []
    /// Most recent payload per chart-id, kept so a re-render after data refresh
    /// can use the cached structure if Swift didn't re-query.
    private var lastPayloadByChart: [String: [String: Any]] = [:]
    /// Tab to switch to once the page finishes loading. nil = use HTML default.
    private var pendingTab: String?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let userContent = WKUserContentController()
        config.userContentController = userContent

        webView = WKWebView(frame: frameRect, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")  // transparent → host bg
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        webView.navigationDelegate = navDelegate
        userContent.add(scriptHandler, name: "garminDisconnect")

        loadHostPage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Public API

    /// Submit a chart payload to be rendered. Safe to call before the WebView
    /// finishes loading — it'll be queued and flushed after page load.
    func render(_ payload: [String: Any]) {
        let chartID = (payload["chart"] as? String) ?? "<unknown>"
        lastPayloadByChart[chartID] = payload

        if !pageLoaded {
            pendingPayloads.append(payload)
            return
        }
        sendToJS(payload)
    }

    /// Submit many payloads in one go. Useful for tab loaders that produce
    /// several charts' worth of data at once.
    func render(_ payloads: [[String: Any]]) {
        for p in payloads { render(p) }
    }

    /// Switch which top-level tab section is visible in the HTML host.
    func showTab(_ tabID: String) {
        if !pageLoaded {
            pendingTab = tabID
            return
        }
        let escaped = tabID.replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.GarminDisconnect.showTab('\(escaped)')") { _, error in
            if let error = error {
                print("WebChartView: showTab(\(tabID)) failed: \(error)")
            }
        }
    }

    // MARK: - Loading the host page

    private func loadHostPage() {
        guard let webRoot = Bundle.main.resourceURL?
            .appendingPathComponent("web", isDirectory: true)
        else {
            showLoadFailure(reason: "Bundle has no Resources/web directory")
            return
        }
        let indexURL = webRoot.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            showLoadFailure(reason: "missing \(indexURL.path)")
            return
        }
        webView.loadFileURL(indexURL, allowingReadAccessTo: webRoot)
    }

    private func showLoadFailure(reason: String) {
        let html = """
            <html><body style="background:#1e1e1e;color:#dddddd;font-family:-apple-system;
            display:flex;align-items:center;justify-content:center;height:100vh;">
            <div style="text-align:center;">
                <h2 style="font-weight:300;">WebChartView failed to load</h2>
                <p style="color:#888;">\(reason)</p>
            </div></body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
        pageLoaded = true
    }

    // MARK: - JS bridge

    private func sendToJS(_ payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            print("WebChartView: failed to serialize payload to JSON: \(payload)")
            return
        }
        let js = """
            (function() {
              try {
                window.GarminDisconnect.render(\(json));
              } catch (e) {
                console.error('GarminDisconnect.render threw:', e);
                window.webkit.messageHandlers.garminDisconnect.postMessage({
                  event: 'renderError', error: String(e)
                });
              }
            })();
            """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("WebChartView: evaluateJavaScript failed: \(error)")
            }
        }
    }

    // MARK: - Delegates

    private lazy var navDelegate = NavDelegate(owner: self)
    private lazy var scriptHandler = ScriptHandler(owner: self)

    fileprivate func handlePageLoaded() {
        pageLoaded = true
        let queued = pendingPayloads
        pendingPayloads.removeAll()
        for p in queued { sendToJS(p) }
        if let tab = pendingTab {
            pendingTab = nil
            showTab(tab)
        }
    }

    fileprivate func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let event = dict["event"] as? String else {
            print("WebChartView: unrecognized message body: \(body)")
            return
        }
        delegate?.webChartView(self, didReceiveEvent: event, payload: dict)
    }
}

// MARK: - Nested helpers

private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: WebChartView?
    init(owner: WebChartView) { self.owner = owner }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.handlePageLoaded()
    }
    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        print("WebChartView: nav failed: \(error)")
        owner?.handlePageLoaded()
    }
}

private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebChartView?
    init(owner: WebChartView) { self.owner = owner }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.handleMessage(message.body)
    }
}
