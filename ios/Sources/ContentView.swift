import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var backend: EmbeddedBackend

    var body: some View {
        ZStack {
            switch backend.state {
            case .stopped, .starting:
                LaunchView()
            case .needsPairing:
                PairingView(backend: backend)
            case .running:
                WebViewContainer(url: backend.baseURL, backend: backend)
                    .ignoresSafeArea(.container, edges: .bottom)
            case .error(let message):
                ErrorView(message: message, backend: backend)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

struct LaunchView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.5)
            Text("Starting OpenMessage…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    @ObservedObject var backend: EmbeddedBackend

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Something went wrong").font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // Deliberately no "restart backend" button: the Go runtime cannot be
            // torn down and re-hosted inside a live process, so relaunching the
            // app is the honest remedy. Re-pairing is offered because a dead
            // Google registration is the usual cause (see docs/agent-runbook.md).
            Button("Re-pair Google Messages") { backend.resetPairing() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the backend's embedded React UI — the same web app the Mac app shows,
/// served over loopback by the in-process Go server.
struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @ObservedObject var backend: EmbeddedBackend

    func makeCoordinator() -> Coordinator {
        Coordinator(backend: backend)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.nativeBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.add(context.coordinator, name: Coordinator.handlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // The UI is an app surface, not a document: rubber-banding past its edges
        // exposes the host background and reads as a rendering glitch.
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.backend = backend
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    /// The native bridge the web UI feature-detects, kept wire-compatible with
    /// the Mac app's: same handler name, same requestId envelope, same
    /// `__openMessageResolveNativeNotifications` resolution hook, so the React
    /// side runs unmodified.
    ///
    /// One deliberate difference: `OpenMessageNativeNotifications` is *not*
    /// defined here. Declaring it would tell the UI that native notification
    /// delivery exists, and on iOS it does not yet — the app is suspended while
    /// backgrounded, so there is nothing listening to raise a banner. Leaving it
    /// undefined lets the UI fall back rather than offer a dead toggle.
    private static let nativeBridgeScript = """
    (() => {
      if (window.OpenMessageNativeContacts && window.OpenMessageNativeApp) return;
      const pending = new Map();
      function request(type, extra = {}) {
        return new Promise((resolve, reject) => {
          const requestId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
          pending.set(requestId, { resolve, reject });
          window.webkit.messageHandlers.openmessageNotifications.postMessage({ type, requestId, ...extra });
        });
      }
      window.__openMessageResolveNativeNotifications = function(requestId, payload) {
        const pendingRequest = pending.get(requestId);
        if (!pendingRequest) return;
        pending.delete(requestId);
        pendingRequest.resolve(payload);
      };
      window.__openMessageRejectNativeNotifications = function(requestId, message) {
        const pendingRequest = pending.get(requestId);
        if (!pendingRequest) return;
        pending.delete(requestId);
        pendingRequest.reject(new Error(message || 'Notification bridge request failed'));
      };
      window.OpenMessageNativeContacts = {
        isNative: true,
        getAvatar(name, numbers = []) {
          return request('getAvatar', {
            name: typeof name === 'string' ? name : '',
            numbers: Array.isArray(numbers) ? numbers : [],
          });
        },
      };
      window.OpenMessageNativeApp = {
        isNative: true,
        startGooglePairing() {
          return request('startGooglePairing');
        },
      };
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        // nonisolated: read from the nonisolated WKScriptMessageHandler callback.
        nonisolated static let handlerName = "openmessageNotifications"

        var backend: EmbeddedBackend
        weak var webView: WKWebView?

        /// Created on first use, not at launch.
        ///
        /// Merely constructing a ContactsManager is enough to trip the Contacts
        /// TCC prompt — `CNContactStore` plus the `CNContactStoreDidChange`
        /// observer in its init are sufficient, no read required. Holding it as
        /// an app-level @StateObject therefore asked for Contacts on the
        /// *pairing* screen, before the user had connected anything. `lazy`
        /// defers that to the first getAvatar call, which is when the
        /// permission is actually needed and the reason for it is obvious.
        private lazy var contacts = ContactsManager()

        init(backend: EmbeddedBackend) {
            self.backend = backend
        }

        nonisolated func userContentController(_ controller: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            guard message.name == Self.handlerName,
                  let body = message.body as? [String: Any] else { return }
            let type = body["type"] as? String ?? ""
            let requestID = body["requestId"] as? String ?? ""

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case "getAvatar":
                    let name = body["name"] as? String ?? ""
                    let numbers = (body["numbers"] as? [String])
                        ?? ((body["numbers"] as? [Any])?.compactMap { $0 as? String } ?? [])
                    let dataURL = await self.contacts.avatarDataURL(name: name, numbers: numbers)
                    self.resolve(requestID: requestID,
                                 payload: ContactsManager.AvatarPayload(data_url: dataURL))
                case "startGooglePairing":
                    // On macOS this spawns a pairing subprocess. Here it drops
                    // back to the in-app pairing screen, which drives the same
                    // Gaia flow through the embedded library.
                    self.backend.resetPairing()
                    self.resolveEmpty(requestID: requestID)
                default:
                    self.reject(requestID: requestID, message: "Unsupported native bridge request on iOS")
                }
            }
        }

        private func resolve<T: Encodable>(requestID: String, payload: T) {
            guard let webView else { return }
            let encoder = JSONEncoder()
            guard
                let requestData = try? encoder.encode(requestID),
                let requestJSON = String(data: requestData, encoding: .utf8),
                let payloadData = try? encoder.encode(payload),
                let payloadJSON = String(data: payloadData, encoding: .utf8)
            else {
                reject(requestID: requestID, message: "Failed to encode native bridge payload")
                return
            }
            webView.evaluateJavaScript(
                "window.__openMessageResolveNativeNotifications(\(requestJSON), \(payloadJSON));")
        }

        private func resolveEmpty(requestID: String) {
            guard let webView, let data = try? JSONEncoder().encode(requestID),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.__openMessageResolveNativeNotifications(\(json), null);")
        }

        private func reject(requestID: String, message: String) {
            guard let webView,
                  let requestData = try? JSONEncoder().encode(requestID),
                  let requestJSON = String(data: requestData, encoding: .utf8),
                  let messageData = try? JSONEncoder().encode(message),
                  let messageJSON = String(data: messageData, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.__openMessageRejectNativeNotifications(\(requestJSON), \(messageJSON));")
        }
    }
}
