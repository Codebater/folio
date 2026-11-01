import SwiftUI
import WebKit
import FolioReader

/// Where the page says the reader is (sent on scroll and page turns).
struct ReaderPagePosition: Equatable {
    var blockID: String?
    var offset: Int
    var progress: Double
    var page: Int
    var pages: Int
}

enum ReaderEvent {
    case ready(ReaderPagePosition)
    case position(ReaderPagePosition)
    case tap(blockID: String?, offset: Int, zone: String)
    case userScroll
}

/// Commands from Swift to the page's `window.folio` API. The reader script
/// runs in WebKit's isolated `.defaultClient` content world, so it works even
/// though the page itself may not run JavaScript.
@MainActor
final class ReaderBridge {
    weak var webView: WKWebView?

    private func call(_ body: String, _ arguments: [String: Any] = [:]) {
        webView?.callAsyncJavaScript("if (window.folio) { \(body) }", arguments: arguments, in: nil, in: .defaultClient,
                                     completionHandler: nil)
    }

    func highlight(blockID: String, range: Range<Int>?, sentence: Range<Int>? = nil, follow: Bool) {
        call("window.folio.highlight(b, s, e, f, ss, se)",
             ["b": blockID, "s": range?.lowerBound ?? 0, "e": range?.upperBound ?? 0, "f": follow,
              "ss": sentence?.lowerBound ?? 0, "se": sentence?.upperBound ?? 0])
    }

    func clearHighlight() { call("window.folio.clearHighlight()") }

    func scroll(to blockID: String, offset: Int, animated: Bool = false) {
        call("window.folio.scrollToBlock(b, o, a)", ["b": blockID, "o": offset, "a": animated])
    }

    func apply(_ settings: ReaderSettings) {
        var variables: [String: String] = [:]
        for pair in ReaderHTMLRenderer.cssVariables(for: settings).split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { variables[String(parts[0])] = String(parts[1]) }
        }
        call("window.folio.applySettings(v, p)", ["v": variables, "p": settings.layout == .paginated])
    }

    func nextPage() { call("window.folio.nextPage()") }
    func previousPage() { call("window.folio.previousPage()") }
}

struct ReaderWebView: UIViewRepresentable {
    let html: String
    let bridge: ReaderBridge
    let imageHandler: FolioImageSchemeHandler
    var onEvent: (ReaderEvent) -> Void
    var onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Publisher markup is already sanitized and re-rendered; on top of
        // that, the page's own JavaScript is switched off entirely.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(imageHandler, forURLScheme: FolioImageSchemeHandler.scheme)
        configuration.dataDetectorTypes = []
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: ReaderAssets.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "folio")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.decelerationRate = .normal
        #if DEBUG
        webView.isInspectable = true
        #endif
        bridge.webView = webView
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "folio", contentWorld: .defaultClient)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKScriptMessageHandler, @preconcurrency WKNavigationDelegate {
        var parent: ReaderWebView
        var loadedHTML = ""

        init(parent: ReaderWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            func int(_ key: String) -> Int { (body[key] as? NSNumber)?.intValue ?? 0 }
            let position = ReaderPagePosition(blockID: body["block"] as? String, offset: int("offset"),
                                              progress: (body["progress"] as? NSNumber)?.doubleValue ?? 0,
                                              page: int("page"), pages: max(1, int("pages")))
            switch type {
            case "ready": parent.onEvent(.ready(position))
            case "position": parent.onEvent(.position(position))
            case "tap": parent.onEvent(.tap(blockID: body["block"] as? String, offset: int("offset"), zone: body["zone"] as? String ?? "center"))
            case "userScroll": parent.onEvent(.userScroll)
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated, let url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                parent.onLink(url)
                return .cancel
            }
            // Only the page Folio loaded itself (about:blank + HTML string) may load.
            return url?.scheme == "about" ? .allow : .cancel
        }
    }
}
