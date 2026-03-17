import SwiftUI
import WebKit

/// WebKit browser view that displays a running Vibe application.
struct AppBrowserView: View {
    let appURL: URL
    var schemeHandler: VibeSchemeHandler? = nil
    let appName: String
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var currentURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = loadError {
                errorState(error)
            } else {
                ZStack {
                    WebView(url: appURL, schemeHandler: schemeHandler, isLoading: $isLoading, loadError: $loadError, currentURL: $currentURL)

                    if isLoading {
                        ProgressView("Connecting to \(appName)...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background.opacity(0.9))
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(loadError == nil ? .green : .red)
                .frame(width: 8, height: 8)

            Text(appName)
                .fontWeight(.medium)

            Spacer()

            if let currentURL {
                Text(currentURL.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Unable to Connect")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("The app may still be starting up.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Retry") {
                loadError = nil
                isLoading = true
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - WKWebView subclass with isolated undo manager
//
// WKWebView registers undo actions for every keystroke and propagates them
// through the responder chain, reaching the NSDocument that backs SwiftUI's
// FileDocument. This makes the document appear "Edited" whenever the user
// types in a web form — even if nothing was written to the container volume.
// Overriding undoManager with a private instance breaks that chain.
private final class VibeWebView: WKWebView {
    private let isolatedUndoManager = UndoManager()
    override var undoManager: UndoManager? { isolatedUndoManager }
}

/// NSViewRepresentable wrapping WKWebView.
struct WebView: NSViewRepresentable {
    let url: URL
    var schemeHandler: VibeSchemeHandler? = nil
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    @Binding var currentURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use a non-persistent data store so reopening a document never serves
        // cached content from a previous session.
        config.websiteDataStore = .nonPersistent()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if let handler = schemeHandler {
            config.setURLSchemeHandler(handler, forURLScheme: "vibe-app")
        }

        let webView = VibeWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.initialURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if the target URL actually changed (not on every SwiftUI redraw)
        if context.coordinator.initialURL != url {
            context.coordinator.initialURL = url
            context.coordinator.retryCount = 0
            webView.load(URLRequest(url: url))
        }
    }

    /// Called by SwiftUI when this view is removed from the hierarchy (e.g. when
    /// webViewID changes and forces a new WKWebView to be created). Nil-ing the
    /// navigation delegate stops any in-flight or pending callbacks from the old
    /// WKWebView from firing on the shared isLoading binding after the new one
    /// has already finished loading — which was causing isWebLoading to get stuck
    /// at true, blocking all pointer events via the ProgressView overlay.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        var retryCount = 0
        var initialURL: URL?
        private let maxRetries = 8

        init(_ parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.loadError = nil
            parent.currentURL = webView.url
            retryCount = 0
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            // -999 = cancelled (e.g. by a new load) — ignore silently
            if nsError.code == NSURLErrorCancelled {
                return
            }

            // Auto-retry for connection errors — container may still be starting
            if retryCount < maxRetries {
                retryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak webView] in
                    guard let webView, let url = self.initialURL else { return }
                    webView.load(URLRequest(url: url))
                }
            } else {
                parent.isLoading = false
                parent.loadError = error.localizedDescription
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            parent.isLoading = false
            parent.loadError = error.localizedDescription
        }
    }
}
