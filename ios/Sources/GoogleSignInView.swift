import SwiftUI
import WebKit

/// Embedded Google sign-in that harvests the cookies libgm's Gaia pairing needs.
///
/// This is the UIKit twin of the Mac app's GoogleSignInView. The cookie-harvest
/// logic is deliberately identical — SAPISID is what libgm signs its requests
/// with, so its appearance is the signal that a usable session exists — and only
/// the view-representable half differs (`makeUIView` rather than `makeNSView`).
///
/// Privacy: a non-persistent data store means the Google session is discarded
/// when pairing ends. The only thing that survives is the backend's session.json.
struct GoogleSignInView: UIViewRepresentable {
    var onCookiesReady: @MainActor (String) -> Void
    var onLoadError: (@MainActor (String) -> Void)?

    // Google's sign-in rejects user agents it does not recognise as a browser.
    // WKWebView on iPad omits the Version/Safari tokens by default, so present a
    // full desktop Safari UA — the desktop variant also keeps Google from
    // steering us into the mobile "open the app" flow, which never yields the
    // web cookies we need.
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmessages.google.com%2Fweb%2F")!

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesReady: onCookiesReady, onLoadError: onLoadError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: Self.signInURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookiesReady: @MainActor (String) -> Void
        private let onLoadError: (@MainActor (String) -> Void)?
        weak var webView: WKWebView?
        private var harvested = false

        init(onCookiesReady: @escaping @MainActor (String) -> Void,
             onLoadError: (@MainActor (String) -> Void)?) {
            self.onCookiesReady = onCookiesReady
            self.onLoadError = onLoadError
        }

        // Checked after every response (Set-Cookie already applied) and again on
        // didFinish: the sign-in redirect chain fires both, so SAPISID is caught
        // as soon as it exists rather than only at the end of the chain.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            checkCookies()
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportError(error)
        }

        private func reportError(_ error: Error) {
            let nsError = error as NSError
            // A redirect superseding an in-flight load is not a failure.
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            let message = error.localizedDescription
            Task { @MainActor in self.onLoadError?(message) }
        }

        private func checkCookies() {
            guard !harvested, let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let google = cookies.filter { $0.domain.contains("google.com") }
                guard google.contains(where: { $0.name == "SAPISID" }) else { return }
                var byName: [String: String] = [:]
                for cookie in google { byName[cookie.name] = cookie.value }
                let header = byName.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                self.deliver(header)
            }
        }

        private func deliver(_ header: String) {
            Task { @MainActor in
                guard !self.harvested else { return }
                self.harvested = true
                self.onCookiesReady(header)
            }
        }
    }
}
