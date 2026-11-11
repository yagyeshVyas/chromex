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
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Tab state
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var showingTabSwitcher = false
    @Published var popupExtension: InstalledExtension?

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
    let extensions: ExtensionManager

    private let supportDirectory: URL
    private let stateURL: URL
    private var saveTask: Task<Void, Never>?
    private let historyLimit = 3_000

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
        wireExtensionRuntime()
        adBlocker.prepare()
        restoreSession()
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
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
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
        scheduleSave()
        return tab
    }

    func select(_ tab: BrowserTab) {
        selectedTabID = tab.id
        tab.ensureLoaded()
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            let next = tabs.indices.contains(index) ? tabs[index] : tabs.last
            selectedTabID = next?.id
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
        configuration.applicationNameForUserAgent = "CHROMEX/1.0"
        if preferences.blockAdsAndTrackers {
            adBlocker.attach(to: configuration)
        }
        configuration.userContentController.add(extensions.bridge, name: "chromexBridge")
        return configuration
    }

    func prepareContentScripts(for tab: BrowserTab, url: URL) {
        let controller = tab.webView.configuration.userContentController
        controller.removeAllUserScripts()
        let injections = extensions.injections(for: url, isPrivate: tab.isPrivate)
        for injection in injections {
            let time: WKUserScriptInjectionTime = injection.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd
            controller.addUserScript(WKUserScript(
                source: injection.source,
                injectionTime: time,
                forMainFrameOnly: !injection.allFrames
            ))
        }
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

    func startDownload(_ url: URL) {
        let filename = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let item = DownloadItem(
            filename: filename,
            sourceURLString: url.absoluteString,
            state: .inProgress
        )
        downloads.insert(item, at: 0)
        scheduleSave()

        URLSession.shared.downloadTask(with: url) { temporaryURL, _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.completeDownload(id: item.id, temporaryURL: temporaryURL, errorMessage: message)
            }
        }.resume()
    }

    private func completeDownload(id: UUID, temporaryURL: URL?, errorMessage: String?) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        guard let temporaryURL, errorMessage == nil else {
            downloads[index].state = .failed
            downloads[index].errorMessage = errorMessage ?? "The download could not be completed."
            scheduleSave()
            return
        }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsDirectory = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let unique = "\(UUID().uuidString.prefix(8))-\(downloads[index].filename)"
        let destination = downloadsDirectory.appendingPathComponent(unique)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
            let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
            downloads[index].byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            downloads[index].localPath = destination.path
            downloads[index].state = .completed
        } catch {
            downloads[index].state = .failed
            downloads[index].errorMessage = error.localizedDescription
        }
        scheduleSave()
    }

    func removeDownload(_ item: DownloadItem) {
        if let path = item.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        downloads.removeAll { $0.id == item.id }
        scheduleSave()
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

    /// Used by `WKUIDelegate` for camera and microphone capture.
    func captureDecision(for host: String?, type: SitePermissionType) -> PermissionDecision {
        guard let host else { return .deny }
        return decision(for: host, type: type) ?? .deny
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
        groups.append(TabGroup(name: name, colorHex: "#2E6BFF"))
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
        let session = tabs
            .filter { !$0.isPrivate }
            .compactMap { tab -> SessionTab? in
                guard !tab.urlString.isEmpty else { return nil }
                return SessionTab(urlString: tab.urlString, title: tab.snapshotTitle(), groupID: tab.groupID)
            }
        let current = tabs.map(\.id)
        UserDefaults.standard.set(current.count, forKey: "chromex.lastTabCount")
        pendingSession = session
        scheduleSave()
    }

    private var pendingSession: [SessionTab] = []

    private func restoreSession() {
        if preferences.homepage.isEmpty, let first = pendingSession.first,
           let url = URL(string: first.urlString) {
            let tab = BrowserTab(
                model: self,
                isPrivate: false,
                desktopMode: preferences.desktopModeByDefault,
                configuration: makeConfiguration(isPrivate: false)
            )
            tab.urlString = first.urlString
            tab.title = first.title
            tabs.append(tab)
            selectedTabID = tab.id
            tab.ensureLoaded()
            _ = url
        } else if let url = URLResolver.destination(for: preferences.homepage, engine: currentSearchEngine),
                  !preferences.homepage.isEmpty {
            openTab(url: url, select: true)
        } else {
            openTab(url: nil, select: true)
        }
    }

    // MARK: Extension wiring

    private func wireExtensionRuntime() {
        extensions.tabInfoProvider = { [weak self] record in
            guard let self, let tab = self.currentTab else { return [] }
            var info: [String: Any] = [
                "id": 0,
                "active": true,
                "windowId": 0,
                "index": 0,
                "incognito": tab.isPrivate,
                "title": tab.snapshotTitle()
            ]
            let broad = record.grants.contains("<all_urls>") || !record.grants.isEmpty
            if broad, !tab.urlString.isEmpty {
                info["url"] = tab.urlString
            }
            return [info]
        }
        extensions.openTabHandler = { [weak self] url in
            self?.openTab(url: url, select: true)
        }
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
        pendingSession = state.session
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
        let state = PersistedState(
            bookmarks: bookmarks,
            history: history,
            downloads: downloads,
            permissions: permissions,
            customEngines: customEngines,
            groups: groups,
            preferences: preferences,
            session: pendingSession
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Extension UI

    func openPopup(for record: InstalledExtension) {
        popupExtension = record
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
