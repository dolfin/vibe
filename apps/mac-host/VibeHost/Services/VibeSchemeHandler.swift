import WebKit

/// WKURLSchemeHandler that forwards vibe-app://app/<path> → http://<vmIP>:<containerPort>/<path>.
/// All activeTasks access happens on the main thread (WebKit guarantees start/stop on main).
final class VibeSchemeHandler: NSObject, WKURLSchemeHandler {
    let vmIP: String
    let containerPort: UInt16

    /// Keyed by ObjectIdentifier(urlSchemeTask). Accessed on main thread only.
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(vmIP: String, containerPort: UInt16) {
        self.vmIP = vmIP
        self.containerPort = containerPort
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let originalURL = urlSchemeTask.request.url,
              var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Rewrite vibe-app://app/path?query → http://vmIP:containerPort/path?query
        components.scheme = "http"
        components.host = vmIP
        components.port = Int(containerPort)

        guard let targetURL = components.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        var request = URLRequest(url: targetURL, timeoutInterval: 5)
        request.httpMethod = urlSchemeTask.request.httpMethod
        request.httpBody = urlSchemeTask.request.httpBody
        urlSchemeTask.request.allHTTPHeaderFields?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let taskKey = ObjectIdentifier(urlSchemeTask)

        let sessionTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.activeTasks[taskKey] != nil else { return }
                self.activeTasks[taskKey] = nil

                if let error {
                    urlSchemeTask.didFailWithError(error)
                    return
                }
                if let response { urlSchemeTask.didReceive(response) }
                if let data { urlSchemeTask.didReceive(data) }
                urlSchemeTask.didFinish()
            }
        }

        activeTasks[taskKey] = sessionTask
        sessionTask.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
