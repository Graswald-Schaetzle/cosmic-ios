import SwiftUI
import WebKit

struct MatterportWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.load(url: url, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(url: url, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MatterportWebView
        private var lastLoadedURL: URL?

        init(parent: MatterportWebView) {
            self.parent = parent
        }

        func load(url: URL, in webView: WKWebView) {
            guard lastLoadedURL != url else { return }
            lastLoadedURL = url
            parent.isLoading = true
            parent.errorMessage = nil
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.errorMessage = nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            handle(error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handle(error: error)
        }

        private func handle(error: Error) {
            parent.isLoading = false
            parent.errorMessage = error.localizedDescription
        }
    }
}
