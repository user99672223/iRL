import SwiftUI
import WebKit

/// Epic's web login in a non-persistent web view; Epic's redirect page shows a JSON body with a
/// one-use authorization code, which is traded for tokens (EpicAuth) and never logged.
struct EpicSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            EpicWebView { code in
                Task {
                    do { try await EpicAuth.shared.signIn(authorizationCode: code); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .navigationTitle("Epic Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .alert("Sign-in failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct EpicWebView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: EpicAuth.loginURL))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, EpicAuth.isRedirectPage(webView.url) else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                guard let self, !self.done, let text = result as? String, let code = EpicAuth.authorizationCode(in: text) else { return }
                self.done = true
                self.onCode(code)
            }
        }
    }
}
