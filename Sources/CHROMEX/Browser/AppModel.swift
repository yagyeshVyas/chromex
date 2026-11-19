import Foundation
import SwiftUI
import UIKit
import WebKit

/// Everything that survives a relaunch. One file, atomically replaced.
struct PersistedState: Codable, Sendable {
    var bookmarks: [Bookmark] = []
    var history: [HistoryEntry] = []
    var downloads: [DownloadItem] = []
    var permissions: [SitePermission] = []
    var customEngines: [SearchEngine] = []
    var groups: [TabGroup] = []
    var preferences: AppPreferences = AppPreferences()
    var session: [SessionTab] = []
    var sessionIndex: Int? = nil
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Tab state
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var showingTabSwitcher = false

    // MARK: Library state
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var downloads: [DownloadItem] = []
    @Published private(set) var permissions: [SitePermission] = []
    @Published private(set) var customEngines: [SearchEngine] = []
    @Published private(set) var groups: [TabGroup] = []
    @Published var preferences: AppPreferences = AppPreferences() {
        didSet { scheduleSave() }
    }

    // MARK: Services
    let adBlocker = AdBlocker()

    /// Content scripts run here, never in the page's own world: page JavaScript
    /// can then neither read the extension bridge token nor overwrite helpers.
    let contentWorld = WKContentWorld.world(name: "chromex-content")
    let extensions: ExtensionManager
    private(set) lazy var downloadsCenter: DownloadCenter = { DownloadCenter(model: self) }()

    private let supportDirectory: URL
    private let stateURL: URL
    private var saveTask: Task<Void, Never>?
    private let historyLimit = 3_000
    private var sessionSnapshot: [SessionTab] = []
    private var sessionSelectedIndex = 0

    // MARK: Init

    init() {
        let fileManager = FileManager.default
        let support = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory).appendingPathComponent("CHROMEX", isDirectory: true)
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        supportDirectory = support
        stateURL = support.appendingPathComponent("state.json")
        extensions = ExtensionManager(root: support.appendingPathComponent("Extensions", isDirectory: true))

        loadState()
        extensions.app = self
        adBlocker.prepare()
        restoreSession()
        AppLog.write("launch: \(tabs.count) tab(s), \(extensions.installed.count) extension(s)", tag: "app")
    }

    // MARK: Convenience

    var currentTab: BrowserTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var allSearchEngines: [SearchEngine] {
        SearchEngine.builtIns + customEngines
    }

    var currentSearchEngine: SearchEngine {
        allSearchEngines.first { $0.id == preferences.searchEngineID }
            ?? SearchEngine.builtIns[0]
    }

    var presentingViewController: UIViewController? {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, select: Bool = true, private isPrivate: Bool = false) -> BrowserTab {
        let tab = BrowserTab(
            model: self,
            isPrivate: isPrivate,
            desktopMode: preferences.desktopModeByDefault,
            configuration: makeConfiguration(isPrivate: isPrivate)
        )
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        if let url {
            tab.load(url)
        } else if !preferences.homepage.isEmpty,
                  let homeURL = URLResolver.destination(for: preferences.homepage, engine: currentSearchEngine) {
            tab.load(homeURL)
        }
        persistSession()
        return tab
    }

    /// Chrome's `target="_blank"` behaviour: a new tab in the strip, selected.
    func openTabInBackgroundOrSelect(url: URL) {
        if preferences.openLinksInNewTab {
            openTab(url: url, select: false)
        } else {
            openTab(url: url, select: true)
        }
    }

    func select(_ tab: BrowserTab) {
        selectedTabID = tab.id
        tab.ensureLoaded()
        persistSession()
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            let next = tabs.indices.contains(index) ? tabs[index] : tabs.last
            selectedTabID = next?.id
            next?.ensureLoaded()
        }
        if tabs.isEmpty {
            openTab(url: nil, select: true, private: tab.isPrivate)
        }
        persistSession()
    }

    func closeCurrentTab() {
        guard let currentTab else { return }
        closeTab(currentTab)
    }

    func submit(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URLResolver.destination(for: trimmed, engine: currentSearchEngine) else { return }
        if let tab = currentTab {
            tab.load(url)
        } else {
            openTab(url: url, select: true)
        }
    }

    func navigate(to url: URL) {
        currentTab?.load(url)
    }

    // MARK: Configuration

    private func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "CHROMEX/2.0"
        configuration.setURLSchemeHandler(extensions.schemeHandler, forURLScheme: ExtensionSchemeHandler.scheme)
        if preferences.blockAdsAndTrackers {
            adBlocker.attach(to: configuration)
        }
        configuration.userContentController.add(extensions.bridge, name: "chromexBridge")
        configuration.userContentController.add(nativeBridge, name: "chromexNative")
        return configuration
    }

    private lazy var nativeBridge: NativeBridge = {
        let bridge = NativeBridge()
        bridge.model = self
        return bridge
    }()

    func prepareContentScripts(for tab: BrowserTab, url: URL) {
        let controller = tab.webView.configuration.userContentController
        controller.removeAllUserScripts()
        let injections = extensions.injections(for: url, isPrivate: tab.isPrivate)
        for injection in injections {
            let time: WKUserScriptInjectionTime = injection.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd
            let world: WKContentWorld = injection.world == .main ? .page : contentWorld
            controller.addUserScript(WKUserScript(
                source: injection.source,
                injectionTime: time,
                forMainFrameOnly: !injection.allFrames,
                in: world
            ))
        }
    }

    func contentScriptsDidFinishLoading(in tab: BrowserTab) {
        extensions.navigationDidFinish(urlString: tab.urlString, isPrivate: tab.isPrivate)
    }

    // MARK: History

    func recordVisit(title: String, urlString: String, isPrivate: Bool) {
        guard !isPrivate, let url = URL(string: urlString), URLResolver.isWebURL(url) else { return }
        if let last = history.first, last.urlString == urlString,
           Date().timeIntervalSince(last.visitedAt) < 10 {
            return
        }
        history.insert(HistoryEntry(title: title, urlString: urlString), at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        scheduleSave()
    }

    func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func history(matching query: String) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(history.prefix(8)) }
        return history.filter {
            $0.title.lowercased().contains(needle) || $0.urlString.lowercased().contains(needle)
        }
    }

    /// One entry per host for the new-tab shortcut grid, newest first.
    var topSites: [HistoryEntry] {
        var seen = Set<String>()
        var result: [HistoryEntry] = []
        for entry in history {
            guard let host = URL(string: entry.urlString)?.host, !host.isEmpty else { continue }
            guard seen.insert(host.lowercased()).inserted else { continue }
            result.append(entry)
            if result.count == 8 { break }
        }
        return result
    }

    // MARK: Bookmarks

    func isBookmarked(urlString: String) -> Bool {
        bookmarks.contains { $0.urlString == urlString }
    }

    func toggleBookmark(title: String, urlString: String) {
        if let index = bookmarks.firstIndex(where: { $0.urlString == urlString }) {
            bookmarks.remove(at: index)
        } else if !urlString.isEmpty {
            bookmarks.insert(Bookmark(title: title, urlString: urlString), at: 0)
        }
        scheduleSave()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        scheduleSave()
    }

    // MARK: Downloads

    func insertDownload(_ item: DownloadItem) {
        downloads.insert(item, at: 0)
        scheduleSave()
    }

    func updateDownload(id: UUID, progress: Double) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].progress = progress
    }

    func renameDownload(id: UUID, filename: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].filename = filename
        scheduleSave()
    }

    func completeDownload(id: UUID, path: String?, byteCount: Int64) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        guard let path else {
            downloads[index].state = .failed
            downloads[index].errorMessage = "The download could not be saved."
            scheduleSave()
            return
        }
        downloads[index].localPath = path
        downloads[index].byteCount = byteCount
        downloads[index].progress = 1
        downloads[index].state = .completed
        scheduleSave()
    }

    func failDownload(id: UUID, message: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = .failed
        downloads[index].errorMessage = message
        scheduleSave()
    }

    func removeDownload(_ item: DownloadItem) {
        if let path = item.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        downloads.removeAll { $0.id == item.id }
        scheduleSave()
    }

    /// Direct transfer used for links, context-menu downloads and extension
    /// `chrome.downloads.download` calls. Returns the item id.
    @discardableResult
    func startURLSessionDownload(_ url: URL) -> UUID {
        let filename = DownloadCenter.safeFilename(url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        let item = DownloadItem(filename: filename, sourceURLString: url.absoluteString, state: .inProgress)
        insertDownload(item)

        URLSession.shared.downloadTask(with: url) { temporaryURL, _, error in
            // URLSession deletes the temporary file when this handler returns, so the
            // move has to happen here rather than after an actor hop.
            var savedPath: String?
            var failure = error?.localizedDescription

            if let temporaryURL, failure == nil {
                let fileManager = FileManager.default
                let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Downloads", isDirectory: true)
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(filename)")
                do {
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                    savedPath = destination.path
                } catch {
                    failure = error.localizedDescription
                }
            }

            let path = savedPath
            let message = failure
            let attributes = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let path, message == nil else {
                    self.failDownload(id: item.id, message: message ?? "The download could not be completed.")
                    return
                }
                self.completeDownload(id: item.id, path: path, byteCount: size)
            }
        }.resume()
        return item.id
    }

    // MARK: Permissions

    func decision(for host: String, type: SitePermissionType) -> PermissionDecision? {
        permissions.first { $0.host == host && $0.type == type }?.decision
    }

    func setDecision(_ decision: PermissionDecision, for host: String, type: SitePermissionType) {
        if let index = permissions.firstIndex(where: { $0.host == host && $0.type == type }) {
            permissions[index].decision = decision
            permissions[index].decidedAt = Date()
        } else {
            permissions.append(SitePermission(host: host, type: type, decision: decision))
        }
        scheduleSave()
    }

    /// Asks once per site and remembers the answer, like Chrome's site settings.
    func requestPermission(
        for host: String?,
        type: SitePermissionType,
        completion: @escaping (PermissionDecision) -> Void
    ) {
        guard let host, !host.isEmpty else {
            completion(.deny)
            return
        }
        if let stored = decision(for: host, type: type) {
            completion(stored)
            return
        }
        guard let presenter = presentingViewController else {
            completion(.deny)
            return
        }
        let alert = UIAlertController(
            title: "“\(host)” wants to use your \(type.displayName.lowercased())",
            message: "You can change this later in Settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Block", style: .cancel) { [weak self] _ in
            self?.setDecision(.deny, for: host, type: type)
            completion(.deny)
        })
        alert.addAction(UIAlertAction(title: "Allow", style: .default) { [weak self] _ in
            self?.setDecision(.allow, for: host, type: type)
            completion(.allow)
        })
        presenter.present(alert, animated: true)
    }

    // MARK: Search engines

    func addSearchEngine(name: String, template: String) {
        guard template.contains("%s") else { return }
        customEngines.append(SearchEngine(name: name, template: template, isBuiltIn: false))
        scheduleSave()
    }

    func removeSearchEngine(_ engine: SearchEngine) {
        guard !engine.isBuiltIn else { return }
        customEngines.removeAll { $0.id == engine.id }
        if preferences.searchEngineID == engine.id {
            preferences.searchEngineID = SearchEngine.builtIns[0].id
        }
        scheduleSave()
    }

    // MARK: Groups

    func createGroup(name: String) {
        groups.append(TabGroup(name: name, colorHex: "#1A73E8"))
        scheduleSave()
    }

    func removeGroup(_ group: TabGroup) {
        for tab in tabs where tab.groupID == group.id {
            tab.groupID = nil
        }
        groups.removeAll { $0.id == group.id }
        scheduleSave()
    }

    // MARK: Session

    func persistSession() {
        let restored = tabs.filter { !$0.isPrivate }
        sessionSnapshot = restored.map { tab in
            SessionTab(urlString: tab.urlString, title: tab.snapshotTitle(), groupID: tab.groupID)
        }
        sessionSelectedIndex = restored.firstIndex { $0.id == selectedTabID } ?? 0
        scheduleSave()
    }

    private func restoreSession() {
        let entries = sessionSnapshot
        let index = sessionSelectedIndex
        sessionSnapshot = []
        sessionSelectedIndex = 0

        guard !entries.isEmpty else {
            if !preferences.homepage.isEmpty,
               let url = URLResolver.destination(for: preferences.homepage, engine: currentSearchEngine) {
                openTab(url: url, select: true)
            } else {
                openTab(url: nil, select: true)
            }
            return
        }

        for entry in entries {
            let tab = BrowserTab(
                model: self,
                isPrivate: false,
                desktopMode: preferences.desktopModeByDefault,
                configuration: makeConfiguration(isPrivate: false)
            )
            tab.urlString = entry.urlString
            tab.title = entry.title.isEmpty ? "New Tab" : entry.title
            tab.groupID = entry.groupID
            tabs.append(tab)
        }
        let selected = min(max(0, index), tabs.count - 1)
        selectedTabID = tabs[selected].id
        // Chrome restores every tab, not just the focused one. WebKit keeps a
        // page suspended until it is shown, so loading them all is cheap.
        for tab in tabs {
            tab.ensureLoaded()
        }
    }

    // MARK: Browsing data

    /// Chrome's "Clear browsing data": history, cookies, caches and site data.
    /// Downloaded files stay on disk; the list entry is what goes.
    func clearBrowsingData(includeDownloadsList: Bool = false) {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            AppLog.write("website data cleared", tag: "privacy")
        }
        history.removeAll()
        permissions.removeAll()
        if includeDownloadsList {
            downloads.removeAll()
        }
        scheduleSave()
    }

    // MARK: Extension host surface

    var extensionTabs: [ExtensionTabInfo] {
        tabs.enumerated().map { index, tab in
            ExtensionTabInfo(
                id: index + 1,
                url: tab.urlString,
                title: tab.snapshotTitle(),
                isActive: tab.id == selectedTabID,
                isPrivate: tab.isPrivate,
                webView: tab.webView
            )
        }
    }

    func extensionOpenTab(url: URL, active: Bool) {
        openTab(url: url, select: active)
    }

    func extensionUpdateTab(id: Int, url: URL?) {
        guard let tab = tab(id: id) else { return }
        if let url { tab.load(url) }
        selectedTabID = tab.id
    }

    func extensionReloadTab(id: Int) {
        tab(id: id)?.reload()
    }

    func extensionCloseTab(id: Int) {
        guard let tab = tab(id: id) else { return }
        closeTab(tab)
    }

    func extensionEvaluateInTab(
        id: Int,
        script: String,
        inContentWorld: Bool,
        completion: @escaping (Any?) -> Void
    ) {
        guard let target = tab(id: id) else {
            completion(nil)
            return
        }
        let box = SendableBox(completion)
        if inContentWorld {
            target.webView.evaluateJavaScript(script, in: nil, in: contentWorld) { result in
                switch result {
                case .success(let value):
                    box.value(value)
                case .failure(let error):
                    AppLog.write("scripting.executeScript failed: \(error.localizedDescription)", tag: "ext")
                    box.value(nil)
                }
            }
        } else {
            target.webView.evaluateJavaScript(script) { result, error in
                if let error { AppLog.write("scripting.executeScript failed: \(error.localizedDescription)", tag: "ext") }
                box.value(result)
            }
        }
    }

    func tab(id: Int) -> BrowserTab? {
        guard id > 0, tabs.indices.contains(id - 1) else { return nil }
        return tabs[id - 1]
    }

    var activeContentWebView: WKWebView? {
        guard let currentTab, !currentTab.isPrivate else { return nil }
        return currentTab.webView
    }

    func dispatchToContent(_ payloadJSON: String) {
        guard let webView = activeContentWebView else { return }
        let script = "window.__chromexDispatch && window.__chromexDispatch(0, \(JSBridge.literal(payloadJSON)));"
        webView.evaluateJavaScript(script, in: nil, in: contentWorld, completionHandler: nil)
    }

    func notifyContentStorageChanged(_ changesJSON: String) {
        guard let webView = activeContentWebView else { return }
        webView.evaluateJavaScript(
            "window.__chromexStorageChanged && window.__chromexStorageChanged(\(JSBridge.literal(changesJSON)));",
            in: nil,
            in: contentWorld,
            completionHandler: nil
        )
    }

    // MARK: Persistence

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        bookmarks = state.bookmarks
        history = state.history
        downloads = state.downloads
        permissions = state.permissions
        customEngines = state.customEngines
        groups = state.groups
        preferences = state.preferences
        sessionSnapshot = state.session
        sessionSelectedIndex = state.sessionIndex ?? 0
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        persistSession()
        let state = PersistedState(
            bookmarks: bookmarks,
            history: history,
            downloads: downloads,
            permissions: permissions,
            customEngines: customEngines,
            groups: groups,
            preferences: preferences,
            session: sessionSnapshot,
            sessionIndex: sessionSelectedIndex
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Privacy summary

    var blockedRuleCount: Int {
        adBlocker.ruleCount
    }

    var sitePermissionSummary: [(SitePermissionType, Int)] {
        SitePermissionType.allCases.map { type in
            (type, Set(permissions.filter { $0.type == type }.map(\.host)).count)
        }
    }
}
