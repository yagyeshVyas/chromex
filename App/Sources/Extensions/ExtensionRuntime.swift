import Foundation
import WebKit

// MARK: - Small JS helpers

enum JSBridge {
    /// Encodes a Swift string as a JavaScript string literal, quotes included.
    static func literal(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[\"\"]".utf8)
        guard let text = String(data: data, encoding: .utf8), text.count >= 2 else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// Encodes a JSON object as a JavaScript string literal containing JSON.
    static func jsonLiteral(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return literal(text)
    }

    static func stringify(_ value: Any?) -> String {
        guard let value else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "null"
    }
}

// MARK: - chromex-extension:// scheme

/// Serves packaged extension resources. This is a private scheme, not a secure
/// context: extension pages therefore avoid `crypto.subtle` and service workers,
/// and the UI says so where it matters.
@MainActor
final class ExtensionSchemeHandler: NSObject, @preconcurrency WKURLSchemeHandler {
    static let scheme = "chromex-extension"

    private var roots: [String: URL] = [:]

    func register(extensionID: String, directory: URL) {
        roots[extensionID] = directory.standardizedFileURL
    }

    func unregister(extensionID: String) {
        roots[extensionID] = nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host?.lowercased() else {
            fail(urlSchemeTask, code: 400)
            return
        }
        guard let root = roots[host] else {
            fail(urlSchemeTask, code: 404)
            return
        }

        var relative = url.path
        if relative.isEmpty || relative == "/" { relative = "/index.html" }
        let candidate = root.appendingPathComponent(String(relative.dropFirst())).standardizedFileURL
        let rootPath = root.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
            fail(urlSchemeTask, code: 403)
            return
        }

        var fileURL = candidate
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            fail(urlSchemeTask, code: 404)
            return
        }
        if isDirectory.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            fail(urlSchemeTask, code: 404)
            return
        }

        var headers: [String: String] = [
            "Content-Type": Self.mimeType(for: fileURL.pathExtension),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ]
        if fileURL.pathExtension.lowercased() == "html" || fileURL.pathExtension.lowercased() == "htm" {
            // Remote script is refused; packaged resources are the only scripts.
            headers["Content-Security-Policy"] =
                "default-src 'self' chromex-extension: data: blob:; " +
                "script-src 'self' chromex-extension:; " +
                "style-src 'self' 'unsafe-inline' chromex-extension:; " +
                "img-src 'self' chromex-extension: data: blob:; " +
                "object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
        if let response { urlSchemeTask.didReceive(response) }
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to cancel: reads are synchronous and small.
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil) else {
            return
        }
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Bridge handler

/// Receives every message from extension JavaScript. Message bodies are
/// validated by `ExtensionManager` against a per-injection capability token.
@MainActor
final class ExtensionBridge: NSObject, @preconcurrency WKScriptMessageHandler {
    weak var manager: ExtensionManager?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "chromexBridge", let body = message.body as? [String: Any] else { return }
        manager?.handleBridgeMessage(body, from: message.webView)
    }
}

// MARK: - Background page host

/// A hidden web view that hosts an extension's background script. MV3 service
/// workers do not exist on iOS; a non-persistent page with the same script is the
/// closest honest equivalent, and it stops when the app is suspended.
@MainActor
final class ExtensionBackgroundRuntime: NSObject, WKNavigationDelegate {
    let extensionID: String
    private let webView: WKWebView
    private var pending: [(requestID: Int, payload: String)] = []
    private(set) var isReady = false
    /// Called when a queued message is finally delivered and no listener answers it.
    var onUnhandled: ((Int) -> Void)?

    init(
        extensionID: String,
        manifest: ExtensionManifest,
        directory: URL,
        schemeHandler: ExtensionSchemeHandler,
        bridge: ExtensionBridge,
        token: String,
        shim: String
    ) {
        self.extensionID = extensionID

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ExtensionSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(bridge, name: "chromexBridge")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        webView.navigationDelegate = self

        let document = ExtensionShim.backgroundDocument(scriptPaths: manifest.backgroundScripts)
        let base = URL(string: "\(ExtensionSchemeHandler.scheme)://\(extensionID)/background.html")
        if let page = manifest.backgroundPage, let pageURL = URL(string: "\(ExtensionSchemeHandler.scheme)://\(extensionID)/\(page)") {
            webView.load(URLRequest(url: pageURL))
        } else if !manifest.backgroundScripts.isEmpty {
            webView.loadHTMLString(document, baseURL: base)
        }
        _ = directory
    }

    func dispatch(requestID: Int, payloadJSON: String, completion: @escaping (String?) -> Void) {
        guard isReady else {
            pending.append((requestID, payloadJSON))
            completion(nil)
            return
        }
        evaluate(requestID: requestID, payloadJSON: payloadJSON, completion: completion)
    }

    private func evaluate(requestID: Int, payloadJSON: String, completion: @escaping (String?) -> Void) {
        let script = "window.__chromexDispatch(\(requestID), \(JSBridge.literal(payloadJSON)));"
        webView.evaluateJavaScript(script) { result, _ in
            let value = result as? String
            Task { @MainActor in
                completion(value)
            }
        }
    }

    private func flushPending() {
        let queued = pending
        pending.removeAll()
        for item in queued {
            evaluate(requestID: item.requestID, payloadJSON: item.payload) { [weak self] result in
                if result == "__none__" {
                    self?.onUnhandled?(item.requestID)
                }
            }
        }
    }

    /// Best-effort `storage.onChanged` for the background page. Content scripts
    /// are not notified in this build and the compatibility table says so.
    func notifyStorageChanged(_ changesJSON: String) {
        guard isReady else { return }
        let script = "window.__chromexStorageChanged && window.__chromexStorageChanged(\(JSBridge.literal(changesJSON)));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        flushPending()
    }

    func stop() {
        webView.stopLoading()
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    }
}
