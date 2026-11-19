import UIKit
import WebKit

/// One browser tab: a `WKWebView`, its navigation state, and the rules for how
/// it hands work back to the app model.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    @Published var title: String
    @Published var urlString: String
    @Published var estimatedProgress: Double = 0
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var errorMessage: String?
    @Published var pageError: PageError?
    @Published var isDesktopMode: Bool
    @Published var groupID: UUID?
    @Published var isSecure: Bool = true
    @Published var zoom: Double = 1
    private(set) var hasLoaded = false


    struct PageError: Equatable {
        var title: String
        var message: String
        var detail: String
        var host: String
    }

    private weak var model: AppModel?
    private var progressObservation: NSKeyValueObservation?
    private var filePanelCoordinator: FilePanelCoordinator?

    /// Desktop Chrome identity. Sites branch on this string; sending Safari's
    /// makes a "desktop mode" that still receives mobile layouts on some sites.
    static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/131.0.0.0 Safari/537.36"

    private static let downloadableExtensions: Set<String> = [
        "zip", "crx", "dmg", "pkg", "tar", "gz", "7z", "rar", "iso", "exe", "msi", "apk",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub", "mp3", "mp4", "mov", "wav"
    ]

    init(model: AppModel, isPrivate: Bool, desktopMode: Bool, configuration: WKWebViewConfiguration) {
        self.model = model
        self.isPrivate = isPrivate
        self.isDesktopMode = desktopMode
        self.title = isPrivate ? "New Private Tab" : "New Tab"
        self.urlString = ""
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.keyboardDismissMode = .interactive
        webView.customUserAgent = desktopMode ? Self.desktopUserAgent : nil
        webView.pageZoom = zoom

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.estimatedProgress = value
            }
        }
    }

    deinit {
        progressObservation?.invalidate()
    }

    // MARK: Navigation

    func prepareAndLoad(_ url: URL) {
        model?.prepareContentScripts(for: self, url: url)
        urlString = url.absoluteString
        isSecure = url.scheme?.lowercased() == "https"
        hasLoaded = true
        pageError = nil
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    /// Restored tabs keep their URL but do not load until the user selects them.
    func ensureLoaded() {
        guard !hasLoaded, let url = URL(string: urlString), !urlString.isEmpty else { return }
        prepareAndLoad(url)
    }

    func load(_ url: URL) {
        prepareAndLoad(url)
    }

    func reload() {
        pageError = nil
        errorMessage = nil
        if webView.url == nil, let url = URL(string: urlString), !urlString.isEmpty {
            load(url)
        } else {
            webView.reload()
        }
    }

    func stopLoading() {
        webView.stopLoading()
        isLoading = false
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func setDesktopMode(_ enabled: Bool) {
        guard enabled != isDesktopMode else { return }
        isDesktopMode = enabled
        webView.customUserAgent = enabled ? Self.desktopUserAgent : nil
        if hasLoaded {
            reload()
        }
    }

    func setZoom(_ value: Double) {
        let clamped = min(3.0, max(0.5, value))
        zoom = clamped
        webView.pageZoom = clamped
    }

    func find(_ text: String, forward: Bool) async -> Bool {
        guard !text.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        return await withCheckedContinuation { continuation in
            webView.find(text, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
    }

    func snapshotTitle() -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: urlString)?.host, !host.isEmpty { return host }
        return isPrivate ? "New Private Tab" : "New Tab"
    }

    func printable() {
        PagePrinter.print(webView: webView, in: model?.presentingViewController)
    }

    // MARK: Helpers

    private func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url {
            urlString = url.absoluteString
            isSecure = url.scheme?.lowercased() == "https"
        }
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            title = pageTitle
        }
    }

    private func isDownloadableFile(_ url: URL) -> Bool {
        Self.downloadableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Chrome's shape for a failed navigation: a title, one sentence, the code.
    private func makePageError(_ error: Error) -> PageError {
        let nsError = error as NSError
        let host = URL(string: urlString)?.host ?? ""
        guard nsError.domain == NSURLErrorDomain else {
            return PageError(
                title: "This page could not be loaded",
                message: nsError.localizedDescription,
                detail: "ERR_FAILED",
                host: host
            )
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return PageError(
                title: "You are offline",
                message: "Check your connection and try again.",
                detail: "ERR_INTERNET_DISCONNECTED",
                host: host
            )
        case NSURLErrorCannotFindHost:
            return PageError(
                title: "This site can't be reached",
                message: "\(host) could not be found. Check the address for typos.",
                detail: "ERR_NAME_NOT_RESOLVED",
                host: host
            )
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return PageError(
                title: "This site can't be reached",
                message: "\(host) refused to connect.",
                detail: "ERR_CONNECTION_REFUSED",
                host: host
            )
        case NSURLErrorTimedOut:
            return PageError(
                title: "This site can't be reached",
                message: "\(host) took too long to respond.",
                detail: "ERR_CONNECTION_TIMED_OUT",
                host: host
            )
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
            return PageError(
                title: "Your connection is not private",
                message: "The certificate for \(host) is not trusted by this device.",
                detail: "ERR_CERT_AUTHORITY_INVALID",
                host: host
            )
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return PageError(
                title: "This site can't provide a secure connection",
                message: "The site uses an unsupported protocol.",
                detail: "ERR_SSL_PROTOCOL_ERROR",
                host: host
            )
        default:
            return PageError(
                title: "This page could not be loaded",
                message: nsError.localizedDescription,
                detail: "ERR_FAILED",
                host: host
            )
        }
    }

    private func handleExternalScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        let allowed: Set<String> = [
            "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "map", "itms-apps",
            "webcal", "ssh", "vnc", "x-apple.systempreferences", "shortcuts"
        ]
        guard allowed.contains(scheme) else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }
}

// MARK: - Blob downloads

extension BrowserTab {
    /// WebKit hands `blob:` navigations to the app, but there is no `WKDownload`
    /// for them. The page reads the blob and posts a data URL to the native bridge.
    fileprivate func startBlobDownload(_ url: URL) {
        let name = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let script = """
        (function () {
          try {
            fetch(\(JSBridge.literal(url.absoluteString))).then(function (response) {
              return response.blob();
            }).then(function (blob) {
              var reader = new FileReader();
              reader.onload = function () {
                window.webkit.messageHandlers.chromexNative.postMessage({
                  kind: "blobDownload",
                  name: \(JSBridge.literal(name)),
                  mime: blob.type || "",
                  data: reader.result
                });
              };
              reader.readAsDataURL(blob);
            }).catch(function (error) {
              window.webkit.messageHandlers.chromexNative.postMessage({ kind: "log", message: "blob fetch failed: " + error });
            });
          } catch (error) {
            window.webkit.messageHandlers.chromexNative.postMessage({ kind: "log", message: "blob start failed: " + error });
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: @preconcurrency WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        estimatedProgress = 0
        errorMessage = nil
        pageError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = 1
        syncNavigationState()
        model?.recordVisit(title: snapshotTitle(), urlString: urlString, isPrivate: isPrivate)
        model?.contentScriptsDidFinishLoading(in: self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        pageError = PageError(
            title: "This page crashed",
            message: "The rendering process stopped. Reload to continue.",
            detail: "ERR_RENDERER_GONE",
            host: URL(string: urlString)?.host ?? ""
        )
    }

    private func fail(with error: Error) {
        isLoading = false
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        pageError = makePageError(error)
        AppLog.write("navigation failed: \(urlString) — \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)", tag: "nav")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        // target="_blank" arrives with no target frame.
        if navigationAction.targetFrame == nil {
            model?.openTabInBackgroundOrSelect(url: url)
            decisionHandler(.cancel)
            return
        }

        if scheme == "blob" {
            startBlobDownload(url)
            decisionHandler(.cancel)
            return
        }

        if scheme == "data" {
            decisionHandler(.cancel)
            return
        }

        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" {
            if navigationAction.navigationType == .linkActivated,
               isDownloadableFile(url) {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
            return
        }

        if handleExternalScheme(url) {
            decisionHandler(.cancel)
            return
        }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        if let http = response as? HTTPURLResponse {
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if disposition.contains("attachment") {
                decisionHandler(.download)
                return
            }
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        model?.downloadsCenter.adopt(download, suggestedName: download.originalRequest?.url?.lastPathComponent)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        model?.downloadsCenter.adopt(download)
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: @preconcurrency WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let permissionType: SitePermissionType
        switch type {
        case .camera:
            permissionType = .camera
        case .microphone:
            permissionType = .microphone
        case .cameraAndMicrophone:
            permissionType = .camera
        @unknown default:
            permissionType = .camera
        }
        guard let model else {
            decisionHandler(.deny)
            return
        }
        model.requestPermission(for: origin.host, type: permissionType) { decision in
            decisionHandler(decision == .allow ? .grant : .deny)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let model else {
            decisionHandler(.deny)
            return
        }
        model.requestPermission(for: origin.host, type: .location) { decision in
            decisionHandler(decision == .allow ? .grant : .deny)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if navigationAction.shouldPerformDownload {
                model?.startURLSessionDownload(url)
            } else {
                model?.openTabInBackgroundOrSelect(url: url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        guard let presenter = model?.presentingViewController else {
            completionHandler(nil)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        let coordinator = FilePanelCoordinator(completion: completionHandler)
        picker.delegate = coordinator
        filePanelCoordinator = coordinator
        presenter.present(picker, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        let linkURL = elementInfo.linkURL
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: linkURL)
        }
        completionHandler(configuration)
    }

    private func menu(for linkURL: URL?) -> UIMenu {
        var actions: [UIAction] = []
        if let linkURL {
            actions.append(UIAction(title: "Open Link in New Tab", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak self] _ in
                self?.model?.openTab(url: linkURL, select: false)
            })
            actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
                self?.model?.openTab(url: linkURL, select: true)
            })
            actions.append(UIAction(title: "Copy Link Address", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = linkURL.absoluteString
            })
            actions.append(UIAction(title: "Download Link", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.model?.startURLSessionDownload(linkURL)
            })
        } else if let pageURL = webView.url {
            actions.append(UIAction(title: "Copy Page Address", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = pageURL.absoluteString
            })
        }
        actions.append(UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.reload()
        })
        return UIMenu(title: linkURL?.absoluteString ?? "", children: actions)
    }

    private func presentAlert(title: String, message: String, completion: @escaping () -> Void) {
        guard let presenter = model?.presentingViewController else {
            completion()
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        presentAlert(title: frame.request.url?.host ?? "Page", message: message, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let presenter = model?.presentingViewController else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: frame.request.url?.host ?? "Page", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard let presenter = model?.presentingViewController else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: frame.request.url?.host ?? "Page", message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }
}

// MARK: - File picker retention

private final class FilePanelCoordinator: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]?) -> Void

    init(completion: @escaping ([URL]?) -> Void) {
        self.completion = completion
        super.init()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}

// MARK: - Native message bridge

/// Receives messages that browser pages and extension pages send straight to the
/// app (blob downloads, JavaScript errors, clipboard requests).
@MainActor
final class NativeBridge: NSObject, @preconcurrency WKScriptMessageHandler {
    weak var model: AppModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "chromexNative",
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }

        switch kind {
        case "blobDownload":
            model?.downloadsCenter.saveDataURL(
                body["data"] as? String ?? "",
                suggestedName: body["name"] as? String,
                mimeType: body["mime"] as? String
            )
        case "log":
            AppLog.write(body["message"] as? String ?? "", tag: "js")
        case "clipboardWrite":
            UIPasteboard.general.string = body["text"] as? String ?? ""
            reply(on: message.webView, id: body["id"], value: "true")
        case "clipboardRead":
            let text = UIPasteboard.general.string ?? ""
            reply(on: message.webView, id: body["id"], value: JSBridge.literal(text))
        default:
            break
        }
    }

    private func reply(on webView: WKWebView?, id: Any?, value: String) {
        guard let webView else { return }
        let identifier = (id as? NSNumber)?.intValue ?? (id as? Int) ?? 0
        let script = "window.__chromexNativeReply && window.__chromexNativeReply(" + String(identifier) + ", " + value + ");"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
