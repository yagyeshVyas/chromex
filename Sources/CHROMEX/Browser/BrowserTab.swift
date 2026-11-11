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
    @Published var isDesktopMode: Bool
    @Published var groupID: UUID?
    @Published var isSecure: Bool = true
    private(set) var hasLoaded = false

    private weak var model: AppModel?
    private var progressObservation: NSKeyValueObservation?

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let downloadableExtensions: Set<String> = [
        "zip", "crx", "dmg", "pkg", "tar", "gz", "7z", "rar", "iso", "exe", "msi", "apk", "pdf"
    ]

    init(model: AppModel, isPrivate: Bool, desktopMode: Bool, configuration: WKWebViewConfiguration) {
        self.model = model
        self.isPrivate = isPrivate
        self.isDesktopMode = desktopMode
        self.title = isPrivate ? "Private" : "New Tab"
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
        webView.customUserAgent = desktopMode ? Self.desktopUserAgent : nil

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
        webView.reload()
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
            webView.reload()
        }
    }

    func snapshotTitle() -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (URL(string: urlString)?.host ?? "New Tab") : trimmed
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

    private func handleDownload(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard Self.downloadableExtensions.contains(ext) else { return false }
        model?.startDownload(url)
        return true
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: @preconcurrency WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        estimatedProgress = 0
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = 1
        syncNavigationState()
        model?.recordVisit(title: snapshotTitle(), urlString: urlString, isPrivate: isPrivate)
        model?.persistSession()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "The page's rendering process stopped. Reload to continue."
    }

    private func fail(with error: Error) {
        isLoading = false
        let nsError = error as NSError
        // A cancelled navigation is not an error worth showing.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        errorMessage = nsError.localizedDescription
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

        // target="_blank" arrives with no target frame.
        if navigationAction.targetFrame == nil {
            model?.openTab(url: url, select: true)
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" {
            if navigationAction.navigationType == .linkActivated, handleDownload(url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            model?.startDownload(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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
        let decision = model?.captureDecision(for: origin.host, type: permissionType) ?? .deny
        decisionHandler(decision == .allow ? .grant : .deny)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            model?.openTab(url: url, select: true)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        present(title: frame.request.url?.host ?? "Page", message: message, completion: completionHandler)
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

    private func present(title: String, message: String, completion: @escaping () -> Void) {
        guard let presenter = model?.presentingViewController else {
            completion()
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        presenter.present(alert, animated: true)
    }
}
