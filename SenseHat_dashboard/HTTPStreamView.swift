import SwiftUI
import WebKit

enum HTTPStreamState: Equatable {
    case idle
    case loading
    case loaded
    case stopped
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .loading:
            return "Loading"
        case .loaded:
            return "Loaded"
        case .stopped:
            return "Stopped"
        case .failed:
            return "Error"
        }
    }
}

struct HTTPStreamView: UIViewRepresentable {
    let urlString: String?
    let reloadToken: Int
    let onStateChange: @MainActor (HTTPStreamState, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = true
        context.coordinator.attach(to: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.attach(to: uiView)
        context.coordinator.onStateChange = onStateChange
        context.coordinator.update(urlString: urlString, reloadToken: reloadToken)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var currentURL: String?
        private var currentReloadToken: Int?
        var onStateChange: (@MainActor (HTTPStreamState, String) -> Void)?

        func attach(to webView: WKWebView) {
            guard self.webView !== webView else {
                return
            }

            self.webView = webView
            webView.navigationDelegate = self
        }

        func update(urlString: String?, reloadToken: Int) {
            let trimmedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let webView else {
                return
            }

            guard let trimmedURL, !trimmedURL.isEmpty else {
                stop()
                currentURL = nil
                currentReloadToken = nil
                report(.idle, "Camera viewer ready for an HTTP URL.")
                return
            }

            guard let url = URL(string: trimmedURL) else {
                report(.failed, "The camera URL could not be parsed.")
                return
            }

            let isSameURL = currentURL == trimmedURL
            let isSameReloadToken = currentReloadToken == reloadToken
            guard !(isSameURL && isSameReloadToken) else {
                return
            }

            currentURL = trimmedURL
            currentReloadToken = reloadToken

            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            webView.load(request)
            report(.loading, "Loading camera feed from \(trimmedURL).")
        }

        func stop() {
            webView?.stopLoading()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            report(.loading, "Loading camera feed from \(currentURL ?? "the configured URL").")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(.loaded, "Displaying the HTTP camera feed from \(currentURL ?? "the configured URL").")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        private func reportFailure(_ error: Error) {
            let nsError = error as NSError

            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }

            report(.failed, "HTTP camera load failed: \(error.localizedDescription)")
        }

        private func report(_ state: HTTPStreamState, _ message: String) {
            Task { @MainActor in
                onStateChange?(state, message)
            }
        }
    }
}
