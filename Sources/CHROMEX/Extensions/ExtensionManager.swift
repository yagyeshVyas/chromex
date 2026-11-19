import Foundation
import UIKit
import WebKit

// MARK: - Installed record

struct InstalledExtension: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var displayName: String
    var version: String
    var isEnabled: Bool
    var installedAt: Date
    var sourceKind: String
    var signatureVerified: Bool
    var manifestData: Data
    var report: CompatibilityReport
    var grants: [String]

    var manifest: ExtensionManifest? {
        try? ManifestParser.parse(data: manifestData)
    }

    var manifestJSON: String? {
        String(data: manifestData, encoding: .utf8)
    }

    var manifestObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
    }

    /// Host patterns the user consented to: declared hosts plus content-script matches.
    static func requestedGrants(for manifest: ExtensionManifest) -> [String] {
        manifest.requestedHostPatterns
    }
}

// MARK: - Injection description

/// A script ready to be turned into a `WKUserScript`.
struct ScriptInjection: Sendable, Hashable {
    var source: String
    var runAt: RunAt
    var allFrames: Bool
    var world: ContentWorldKind = .isolated
}

/// A live tab as extensions see it.
struct ExtensionTabInfo {
    var id: Int
    var url: String
    var title: String
    var isActive: Bool
    var isPrivate: Bool
    var webView: WKWebView
}

// MARK: - Storage

/// Per-extension key/value storage, persisted as JSON.
///
/// `storage.sync` and `storage.session` are deliberately mapped onto local
/// storage: iOS has no Chrome sync service and this build makes no promise of one.
@MainActor
final class ExtensionStorage {
    private let fileURL: URL
    private var values: [String: Any] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            values = dictionary
        }
    }

    func snapshot(for keys: Any?) -> [String: Any] {
        guard let keys else { return values }
        if let single = keys as? String {
            guard let value = values[single] else { return [:] }
            return [single: value]
        }
        if let list = keys as? [String] {
            var result: [String: Any] = [:]
            for key in list where values[key] != nil {
                result[key] = values[key]
            }
            return result
        }
        if let defaults = keys as? [String: Any] {
            var result = defaults
            for (key, value) in values where defaults[key] != nil {
                result[key] = value
            }
            return result
        }
        return [:]
    }

    @discardableResult
    func set(_ items: [String: Any]) -> [String: Any] {
        var changes: [String: Any] = [:]
        for (key, value) in items {
            changes[key] = ["oldValue": values[key] ?? NSNull(), "newValue": value]
            values[key] = value
        }
        persist()
        return changes
    }

    @discardableResult
    func remove(_ keys: [String]) -> [String: Any] {
        var changes: [String: Any] = [:]
        for key in keys {
            changes[key] = ["oldValue": values[key] ?? NSNull(), "newValue": NSNull()]
            values.removeValue(forKey: key)
        }
        persist()
        return changes
    }

    @discardableResult
    func clear() -> [String: Any] {
        var changes: [String: Any] = [:]
        for (key, value) in values {
            changes[key] = ["oldValue": value, "newValue": NSNull()]
        }
        values.removeAll()
        persist()
        return changes
    }

    func byteCount() -> Int {
        (try? Data(contentsOf: fileURL).count) ?? 0
    }

    private func persist() {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Alarm bookkeeping

struct AlarmSpec {
    var name: String
    var scheduledTime: Date
    var periodInMinutes: Double?
}

// MARK: - Manager

@MainActor
final class ExtensionManager: ObservableObject {
    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var diagnostics: [String] = []

    let root: URL
    let schemeHandler = ExtensionSchemeHandler()

    /// The host app. Weak so the model owns the manager, not the other way round.
    weak var app: AppModel?

    private(set) lazy var bridge: ExtensionBridge = {
        let bridge = ExtensionBridge()
        bridge.manager = self
        return bridge
    }()

    private var runtimes: [String: ExtensionBackgroundRuntime] = [:]
    private var storages: [String: ExtensionStorage] = [:]
    private var tokens: [String: String] = [:]
    private var tokenOrder: [String] = []
    /// Bounded so a long browsing session cannot grow the capability table without limit.
    private let maxTokens = 2_000
    /// Cached content-script sources, so navigation does not read the filesystem on
    /// the main actor every time a matching page loads.
    private var scriptCache: [String: [String: String]] = [:]
    private var localizations: [String: ExtensionLocalization] = [:]
    private var pendingReplies: [Int: PendingReply] = [:]
    private var nextRequestID = 1
    private var alarms: [String: [String: AlarmSpec]] = [:]
    private var ports: [String: PortEndpoint] = [:]
    private var proxySettings: [String: [String: Any]] = [:]
    private var extensionRuleLists: [String: [WKContentRuleList]] = [:]
    private var offscreens: [String: ExtensionOffscreenRuntime] = [:]
    private var alarmTasks: [String: [String: Task<Void, Never>]] = [:]
    private var downloadIDs: [Int: UUID] = [:]
    private var nextDownloadID = 1

    private struct PortEndpoint {
        var webView: WKWebView?
        var frame: WKFrameInfo?
        var context: String
        var extensionID: String
    }

    private struct PendingReply {
        var webView: WKWebView?
        var frame: WKFrameInfo?
        var context: String
        var envelopeID: Int
        var runtimeID: String? = nil
    }

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loadRegistry()
    }

    // MARK: Registry

    private var registryURL: URL { root.appendingPathComponent("registry.json") }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let records = try? JSONDecoder().decode([InstalledExtension].self, from: data) else {
            return
        }
        installed = records
        for record in installed where record.isEnabled {
            let directory = root.appendingPathComponent(record.id, isDirectory: true)
            schemeHandler.register(extensionID: record.id, directory: directory)
            ensureBackgroundDocument(for: record, in: directory)
            compileRules(for: record)
            scheduleRuntime(for: record)
        }
    }

    /// Background scripts run from a real document served by the scheme handler.
    /// `loadHTMLString` gives the page a null origin, and subresource loads from a
    /// custom scheme in a null-origin document are rejected by WebKit.
    private func ensureBackgroundDocument(for record: InstalledExtension, in directory: URL) {
        guard let manifest = record.manifest, manifest.backgroundPage == nil,
              !manifest.backgroundScripts.isEmpty else { return }
        let url = directory.appendingPathComponent("background.html")
        let document = ExtensionShim.backgroundDocument(scriptPaths: manifest.backgroundScripts)
        try? document.write(to: url, atomically: true, encoding: .utf8)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: registryURL, options: [.atomic])
    }

    /// Content rule lists compiled from every enabled extension's
    /// `declarative_net_request` rule resources.
    func contentRuleLists() -> [WKContentRuleList] {
        extensionRuleLists.values.flatMap { $0 }
    }

    // MARK: Install / remove / enable

    func install(_ staged: StagedPackage, grants: [String]) throws -> InstalledExtension {
        let identifier = UUID().uuidString
        let destination = root.appendingPathComponent(identifier, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let contents = try manager.contentsOfDirectory(at: staged.directory, includingPropertiesForKeys: nil)
        for item in contents {
            try manager.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
        defer { try? manager.removeItem(at: staged.directory) }

        guard let manifestData = ExtensionPackage.readManifest(in: destination) else {
            try? manager.removeItem(at: destination)
            throw PackageError.missingManifest
        }

        let record = InstalledExtension(
            id: identifier,
            displayName: staged.manifest.name,
            version: staged.manifest.version,
            isEnabled: true,
            installedAt: Date(),
            sourceKind: staged.sourceKind.rawValue,
            signatureVerified: staged.signatureVerified,
            manifestData: manifestData,
            report: staged.report,
            grants: grants
        )

        schemeHandler.register(extensionID: identifier, directory: destination)
        ensureBackgroundDocument(for: record, in: destination)
        compileRules(for: record)
        warmScriptCache(extensionID: identifier, manifest: staged.manifest, directory: destination)
        installed.append(record)
        persist()
        scheduleRuntime(for: record)
        AppLog.write("extension installed: \(record.displayName) \(record.version)", tag: "ext")
        return record
    }

    func remove(_ record: InstalledExtension) {
        stopRuntime(for: record.id)
        schemeHandler.unregister(extensionID: record.id)
        storages[record.id] = nil
        scriptCache[record.id] = nil
        cancelAlarms(for: record.id)
        removeCompiledRules(for: record.id)
        installed.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(record.id, isDirectory: true))
        persist()
    }

    func setEnabled(_ record: InstalledExtension, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        installed[index].isEnabled = enabled
        persist()
        if enabled {
            compileRules(for: installed[index])
            scheduleRuntime(for: installed[index])
        } else {
            stopRuntime(for: record.id)
            scriptCache[record.id] = nil
            cancelAlarms(for: record.id)
            removeCompiledRules(for: record.id)
        }
    }

    func setGrants(_ grants: [String], for record: InstalledExtension) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        installed[index].grants = grants
        persist()
    }

    func storage(for record: InstalledExtension) -> ExtensionStorage {
        if let existing = storages[record.id] { return existing }
        let url = root.appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent("storage.json")
        let storage = ExtensionStorage(fileURL: url)
        storages[record.id] = storage
        return storage
    }

    func storageByteCount(for record: InstalledExtension) -> Int {
        storage(for: record).byteCount()
    }

    // MARK: Runtime

    private func scheduleRuntime(for record: InstalledExtension) {
        guard record.isEnabled, let manifest = record.manifest, manifest.backgroundKind != .none else { return }
        guard runtimes[record.id] == nil else { return }
        let token = registerToken(for: record.id)
        let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "background", manifestJSON: record.manifestJSON ?? "{}")
        let runtime = ExtensionBackgroundRuntime(
            extensionID: record.id,
            manifest: manifest,
            directory: root.appendingPathComponent(record.id, isDirectory: true),
            schemeHandler: schemeHandler,
            bridge: bridge,
            nativeBridge: NativeBridge(),
            token: token,
            shim: shim
        )
        runtimes[record.id] = runtime
        runtime.onReady = { [weak self] in
            self?.evaluateInAllRuntimes("window.__chromexRuntimeEvent && window.__chromexRuntimeEvent('startup', {});")
            self?.evaluateInAllRuntimes("window.__chromexRuntimeEvent && window.__chromexRuntimeEvent('installed', { reason: 'install' });")
        }
        runtime.onUnhandled = { [weak self] requestID in
            guard let self, let pending = self.pendingReplies.removeValue(forKey: requestID) else { return }
            self.reply(on: pending.webView, frame: pending.frame, id: pending.envelopeID, value: nil, error: nil, context: pending.context, runtimeID: pending.runtimeID)
        }
    }

    private func stopRuntime(for identifier: String) {
        runtimes[identifier]?.stop()
        runtimes[identifier] = nil
    }

    private func evaluateInAllRuntimes(_ script: String) {
        for runtime in runtimes.values {
            runtime.evaluate(script)
        }
    }

    func makePopupWebView(for record: InstalledExtension) -> WKWebView? {
        guard record.isEnabled, let manifest = record.manifest,
              let popup = manifest.action?.defaultPopup else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ExtensionSchemeHandler.scheme)
        let token = registerToken(for: record.id)
        let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "popup", manifestJSON: record.manifestJSON ?? "{}")
        configuration.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(bridge, name: "chromexBridge")
        let native = NativeBridge()
        configuration.userContentController.add(native, name: "chromexNative")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        schemeHandler.register(extensionID: record.id, directory: root.appendingPathComponent(record.id, isDirectory: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = ExtensionPageObserver.shared
        let urlString = "\(ExtensionSchemeHandler.scheme)://\(record.id)/\(popup)"
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func makeOptionsWebView(for record: InstalledExtension) -> WKWebView? {
        guard record.isEnabled, let manifest = record.manifest,
              let options = manifest.optionsPage else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ExtensionSchemeHandler.scheme)
        let token = registerToken(for: record.id)
        let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "options", manifestJSON: record.manifestJSON ?? "{}")
        configuration.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(bridge, name: "chromexBridge")
        let native = NativeBridge()
        configuration.userContentController.add(native, name: "chromexNative")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        schemeHandler.register(extensionID: record.id, directory: root.appendingPathComponent(record.id, isDirectory: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = ExtensionPageObserver.shared
        if let url = URL(string: "\(ExtensionSchemeHandler.scheme)://\(record.id)/\(options)") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// Fires `chrome.action.onClicked` in the extension's background page.
    /// Chrome does not fire it when a popup is declared; we match that.
    func dispatchActionClick(for record: InstalledExtension) {
        guard record.manifest?.action?.defaultPopup == nil else {
            appendDiagnostic("\(record.displayName): action click ignored — the extension declares a popup")
            return
        }
        guard let runtime = runtimes[record.id] else {
            appendDiagnostic("\(record.displayName): no running background page for action click")
            return
        }
        runtime.sendActionClicked()
    }

    private func localization(for record: InstalledExtension) -> ExtensionLocalization? {
        if let cached = localizations[record.id] { return cached }
        let directory = root.appendingPathComponent(record.id, isDirectory: true)
        guard let loaded = ExtensionLocalization.load(
            directory: directory,
            defaultLocale: record.manifest?.defaultLocale
        ) else { return nil }
        localizations[record.id] = loaded
        return loaded
    }

    private func permissionsSatisfied(_ requested: [String: Any], by record: InstalledExtension) -> Bool {
        let permissions = requested["permissions"] as? [String] ?? []
        let origins = requested["origins"] as? [String] ?? []
        let declared = Set(record.manifest?.permissions ?? [])
        let granted = Set(record.grants)
        let declaredOK = permissions.allSatisfy { declared.contains($0) }
        let originsOK = origins.allSatisfy { granted.contains($0) || granted.contains("<all_urls>") }
        return declaredOK && originsOK
    }

    // MARK: Offscreen documents

    private func startOffscreenDocument(
        payload: [String: Any],
        record: InstalledExtension,
        respond: @escaping (Any?, String?) -> Void
    ) {
        if offscreens[record.id] != nil {
            respond([:], nil)
            return
        }
        let requested = payload["url"] as? String
        let documentPath = (requested?.isEmpty == false ? requested : nil) ?? "offscreen.html"
        guard let url = URL(string: "\(ExtensionSchemeHandler.scheme)://\(record.id)/\(documentPath)") else {
            respond(nil, "offscreen.createDocument needs a url")
            return
        }
        let token = registerToken(for: record.id)
        let shim = ExtensionShim.source(
            token: token,
            extensionID: record.id,
            context: "offscreen",
            manifestJSON: record.manifestJSON ?? "{}"
        )
        let runtime = ExtensionOffscreenRuntime(
            extensionID: record.id,
            url: url,
            schemeHandler: schemeHandler,
            bridge: bridge,
            nativeBridge: NativeBridge(),
            shim: shim
        )
        offscreens[record.id] = runtime
        AppLog.write("\(record.displayName): offscreen document \(documentPath)", tag: "ext")
        respond([:], nil)
    }

    private func stopOffscreenDocument(for identifier: String) {
        offscreens[identifier]?.stop()
        offscreens[identifier] = nil
    }

    // MARK: declarativeNetRequest

    /// Chrome's `declarativeNetRequest` is the one blocking API WebKit can honour:
    /// its rules describe declarative matches, which map onto `WKContentRuleList`.
    private func compileRules(for record: InstalledExtension) {
        guard let manifest = record.manifest, !manifest.ruleResources.isEmpty else { return }
        let directory = root.appendingPathComponent(record.id, isDirectory: true)
        var compiled: [[String: Any]] = []

        for resource in manifest.ruleResources where resource.enabled {
            let file = directory.appendingPathComponent(resource.path)
            guard let data = try? Data(contentsOf: file),
                  let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                AppLog.write("rule resource unreadable: \(resource.path)", tag: "ext")
                continue
            }
            var blocks: [[String: Any]] = []
            var allows: [[String: Any]] = []
            for rule in rules {
                guard let translation = Self.blockerRule(from: rule) else { continue }
                let action = (rule["action"] as? [String: Any])?["type"] as? String ?? ""
                if action == "allow" {
                    allows.append(translation)
                } else {
                    blocks.append(translation)
                }
            }
            compiled.append(contentsOf: blocks)
            compiled.append(contentsOf: allows)
        }

        guard !compiled.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: compiled),
              let encoded = String(data: data, encoding: .utf8) else { return }

        let identifier = "chromex-ext-\(record.id)"
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: encoded
        ) { list, error in
            let boxed = list.map { SendableBox($0) }
            let failure = error?.localizedDescription
            let displayName = record.displayName
            let recordID = record.id
            let ruleCount = compiled.count
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let boxed {
                    self.extensionRuleLists[recordID] = [boxed.value]
                    AppLog.write("extension rules compiled: \(displayName) (\(ruleCount))", tag: "ext")
                } else {
                    AppLog.write("extension rules rejected: \(displayName) — \(failure ?? "unknown")", tag: "ext")
                }
            }
        }
    }

    private func removeCompiledRules(for identifier: String) {
        extensionRuleLists[identifier] = nil
        WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: "chromex-ext-\(identifier)") { _ in }
    }

    nonisolated static func blockerRule(from rule: [String: Any]) -> [String: Any]? {
        let action = rule["action"] as? [String: Any] ?? [:]
        let type = action["type"] as? String ?? ""
        guard type == "block" || type == "allow" else { return nil }
        let condition = rule["condition"] as? [String: Any] ?? [:]

        var trigger: [String: Any] = [:]
        if let regex = condition["regexFilter"] as? String {
            trigger["url-filter"] = regex
        } else if let filter = condition["urlFilter"] as? String {
            trigger["url-filter"] = wkURLFilter(fromChromeFilter: filter)
        } else {
            return nil
        }
        if let caseSensitive = condition["isUrlFilterCaseSensitive"] as? Bool, caseSensitive {
            trigger["url-filter-is-case-sensitive"] = true
        }
        if let types = condition["resourceTypes"] as? [String], !types.isEmpty {
            let mapped = types.compactMap { wkResourceType($0) }
            if !mapped.isEmpty { trigger["resource-type"] = mapped }
        }

        if type == "block" {
            return ["trigger": trigger, "action": ["type": "block"]]
        }
        return ["trigger": trigger, "action": ["type": "ignore-previous-rules"]]
    }

    nonisolated static func wkResourceType(_ chromeType: String) -> String? {
        switch chromeType {
        case "main_frame", "sub_frame": return "document"
        case "stylesheet": return "style-sheet"
        case "script": return "script"
        case "image": return "image"
        case "font": return "font"
        case "media": return "media"
        case "xmlhttprequest", "other", "websocket": return "raw"
        default: return nil
        }
    }

    /// Translates Chrome's filter syntax (`||host^`, `*`, `|anchor`) into the
    /// ICU regular expression a WebKit content blocker expects.
    nonisolated static func wkURLFilter(fromChromeFilter filter: String) -> String {
        var pattern = filter
        var prefix = ".*"
        if pattern.hasPrefix("||") {
            pattern.removeFirst(2)
            prefix = "^[a-z]+://([^/]+\\.)?"
        } else if pattern.hasPrefix("|") {
            pattern.removeFirst()
            prefix = "^"
        }

        var body = ""
        for character in pattern {
            if character == "*" {
                body += ".*"
            } else if character == "^" {
                body += "(?:[^a-zA-Z0-9_\\-.%]|$)"
            } else if ".^$+?()[]{}|\\".contains(character) {
                body += "\\" + String(character)
            } else {
                body.append(character)
            }
        }
        return prefix + body
    }

    // MARK: Caps

    func registerToken(for extensionID: String) -> String {
        let token = UUID().uuidString
        tokens[token] = extensionID
        tokenOrder.append(token)
        if tokenOrder.count > maxTokens {
            let overflow = tokenOrder.count - maxTokens
            for stale in tokenOrder.prefix(overflow) {
                tokens[stale] = nil
            }
            tokenOrder.removeFirst(overflow)
        }
        return token
    }

    private func extensionID(for token: String) -> String? {
        tokens[token]
    }

    // MARK: Scripts

    func injections(for url: URL, isPrivate: Bool) -> [ScriptInjection] {
        guard !isPrivate else { return [] }
        guard HostMatcher.isWebURL(url) else { return [] }

        var result: [ScriptInjection] = []
        for record in installed where record.isEnabled {
            guard let manifest = record.manifest else { continue }
            let directory = root.appendingPathComponent(record.id, isDirectory: true)

            for script in manifest.contentScripts {
                guard HostMatcher.anyMatch(patterns: script.matches, url: url) else { continue }
                if !script.excludeMatches.isEmpty,
                   HostMatcher.anyMatch(patterns: script.excludeMatches, url: url) {
                    continue
                }
                guard isGranted(record: record, patterns: script.matches) else { continue }

                if script.world == .main {
                    // Chrome runs MAIN-world scripts in the page's own context with
                    // no extension APIs; injection is the raw source, no shim.
                    for path in script.css {
                        guard let css = readText(path, in: directory, extensionID: record.id) else { continue }
                        result.append(ScriptInjection(
                            source: styleInjectionSource(css: css),
                            runAt: script.runAt,
                            allFrames: script.allFrames,
                            world: .main
                        ))
                    }
                    for path in script.js {
                        guard let source = readText(path, in: directory, extensionID: record.id) else { continue }
                        result.append(ScriptInjection(
                            source: source,
                            runAt: script.runAt,
                            allFrames: script.allFrames,
                            world: .main
                        ))
                    }
                    continue
                }

                let token = registerToken(for: record.id)
                let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "content", manifestJSON: record.manifestJSON ?? "{}")
                result.append(ScriptInjection(source: shim, runAt: .documentStart, allFrames: script.allFrames))

                for path in script.css {
                    guard let css = readText(path, in: directory, extensionID: record.id) else { continue }
                    result.append(ScriptInjection(
                        source: styleInjectionSource(css: css),
                        runAt: script.runAt,
                        allFrames: script.allFrames
                    ))
                }
                for path in script.js {
                    guard let source = readText(path, in: directory, extensionID: record.id) else { continue }
                    result.append(ScriptInjection(source: source, runAt: script.runAt, allFrames: script.allFrames))
                }
            }
        }
        return result
    }

    private func styleInjectionSource(css: String) -> String {
        """
        (function(){try{var s=document.createElement("style");s.textContent=\(JSBridge.literal(css));\
        (document.head||document.documentElement).appendChild(s);}catch(e){}})();
        """
    }

    private func readText(_ relativePath: String, in directory: URL, extensionID: String) -> String? {
        if let cached = scriptCache[extensionID]?[relativePath] {
            return cached
        }
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
        let base = directory.standardizedFileURL.path
        guard candidate.path.hasPrefix(base + "/") else { return nil }
        guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { return nil }
        scriptCache[extensionID, default: [:]][relativePath] = text
        return text
    }

    /// Reads every declared script once, at install time, so the first matching
    /// navigation does not pay for disk I/O on the main actor.
    private func warmScriptCache(extensionID: String, manifest: ExtensionManifest, directory: URL) {
        for script in manifest.contentScripts {
            for path in script.js {
                _ = readText(path, in: directory, extensionID: extensionID)
            }
            for path in script.css {
                _ = readText(path, in: directory, extensionID: extensionID)
            }
        }
    }

    private func isGranted(record: InstalledExtension, patterns: [String]) -> Bool {
        if record.grants.contains("<all_urls>") { return true }
        return patterns.contains { record.grants.contains($0) }
    }

    private func isGranted(record: InstalledExtension, url: URL) -> Bool {
        if record.grants.contains("<all_urls>") { return true }
        return record.grants.contains { HostMatcher.matches(pattern: $0, url: url) }
    }

    // MARK: Navigation events

    func navigationDidFinish(urlString: String, isPrivate: Bool) {
        guard !isPrivate, !runtimes.isEmpty else { return }
        let payload: [String: Any] = ["url": urlString, "tabId": 0]
        let json = JSBridge.stringify(payload)
        for runtime in runtimes.values {
            runtime.evaluate("window.__chromexTabUpdated && window.__chromexTabUpdated(\(JSBridge.literal(json)));")
            runtime.evaluate("window.__chromexNavigation && window.__chromexNavigation(\(JSBridge.literal(json)));")
        }
    }

    // MARK: Bridge

    func handleBridgeMessage(_ body: [String: Any], from webView: WKWebView?, frame: WKFrameInfo?) {
        guard let token = body["token"] as? String,
              let identifier = extensionID(for: token),
              let record = installed.first(where: { $0.id == identifier }),
              record.isEnabled else {
            return
        }

        let envelopeID = (body["id"] as? NSNumber)?.intValue ?? (body["id"] as? Int) ?? 0
        let api = body["api"] as? String ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]
        let context = body["ctx"] as? String ?? "content"
        let extensionStorage = storage(for: record)

        func respond(_ value: Any?, _ error: String? = nil) {
            reply(on: webView, frame: frame, id: envelopeID, value: value, error: error, context: context)
        }

        switch api {
        case "storage.get":
            respond(extensionStorage.snapshot(for: payload["keys"]))

        case "storage.set":
            guard let items = payload["items"] as? [String: Any] else {
                respond(nil, "storage.set expects an object")
                return
            }
            let changes = extensionStorage.set(items)
            notifyStorageChanged(identifier, changes: changes)
            respond([:])

        case "storage.remove":
            let keys = (payload["keys"] as? [String]) ?? []
            let changes = extensionStorage.remove(keys)
            notifyStorageChanged(identifier, changes: changes)
            respond([:])

        case "storage.clear":
            let changes = extensionStorage.clear()
            notifyStorageChanged(identifier, changes: changes)
            respond([:])

        case "storage.bytes":
            respond(extensionStorage.byteCount())

        case "tabs.query":
            let query = payload["query"] as? [String: Any] ?? [:]
            respond(tabsPayload(matching: query, record: record))

        case "tabs.create":
            let options = payload["options"] as? [String: Any] ?? [:]
            guard let urlString = options["url"] as? String, let url = URL(string: urlString) else {
                respond(nil, "tabs.create expects { url }")
                return
            }
            let active = options["active"] as? Bool ?? true
            app?.extensionOpenTab(url: url, active: active)
            respond(tabPayload(for: app?.extensionTabs.first { $0.url == urlString }, record: record))

        case "tabs.update":
            let tabID = (payload["tabId"] as? NSNumber)?.intValue ?? 0
            let urlString = payload["url"] as? String
            let url = urlString.flatMap { URL(string: $0) }
            app?.extensionUpdateTab(id: tabID, url: url)
            respond([:])

        case "tabs.reload":
            let tabID = (payload["tabId"] as? NSNumber)?.intValue ?? 0
            app?.extensionReloadTab(id: tabID)
            respond([:])

        case "tabs.remove":
            let tabID = (payload["tabId"] as? NSNumber)?.intValue ?? 0
            app?.extensionCloseTab(id: tabID)
            respond([:])

        case "tabs.sendMessage":
            let tabID = (payload["tabId"] as? NSNumber)?.intValue ?? 0
            let message = payload["message"]
            let requestID = nextRequestID
            nextRequestID += 1
            pendingReplies[requestID] = PendingReply(
                webView: webView,
                frame: frame,
                context: context,
                envelopeID: envelopeID
            )
            let json = JSBridge.stringify(message)
            app?.extensionEvaluateInTab(id: tabID, script: "window.__chromexDispatch && window.__chromexDispatch(\(requestID), \(JSBridge.literal(json)));", inContentWorld: true) { result in
                let answered = (result as? String) == "__handled__"
                if !answered, let pending = self.pendingReplies.removeValue(forKey: requestID) {
                    self.reply(on: pending.webView, frame: pending.frame, id: pending.envelopeID, value: nil, error: nil, context: pending.context, runtimeID: pending.runtimeID)
                }
            }

        case "runtime.connect":
            let portId = payload["portId"] as? String ?? ""
            guard !portId.isEmpty else { return }
            ports[portId] = PortEndpoint(
                webView: webView,
                frame: frame,
                context: context,
                extensionID: identifier
            )
            if let runtime = runtimes[identifier] {
                let senderJSON = JSBridge.stringify([
                    "id": identifier,
                    "url": webView?.url?.absoluteString ?? ""
                ])
                runtime.evaluate(
                    "window.__chromexIncomingPort(" +
                    "\(JSBridge.literal(portId)), " +
                    "\(JSBridge.literal(payload["name"] as? String ?? "")), " +
                    "\(JSBridge.literal(senderJSON)));"
                )
            }

        case "runtime.port.postMessage":
            guard let portId = payload["portId"] as? String,
                  let endpoint = ports[portId] else { return }
            let messageJSON = JSBridge.stringify(payload["message"])
            if webView == nil {
                deliverPortMessage(portId: portId, messageJSON: messageJSON, to: endpoint)
            } else if let runtime = runtimes[endpoint.extensionID] {
                runtime.evaluate(
                    "window.__chromexPortMessage && window.__chromexPortMessage(" +
                    "\(JSBridge.literal(portId)), \(JSBridge.literal(messageJSON)));"
                )
            }

        case "runtime.port.disconnect":
            guard let portId = payload["portId"] as? String,
                  let endpoint = ports.removeValue(forKey: portId) else { return }
            if webView == nil {
                deliverPortDisconnect(portId: portId, to: endpoint)
            } else if let runtime = runtimes[endpoint.extensionID] {
                runtime.evaluate(
                    "window.__chromexPortDisconnect && window.__chromexPortDisconnect(" +
                    "\(JSBridge.literal(portId)));"
                )
            }

        case "offscreen.createDocument":
            startOffscreenDocument(payload: payload, record: record, respond: respond)

        case "offscreen.closeDocument":
            stopOffscreenDocument(for: record.id)
            respond([:])

        case "offscreen.hasDocument":
            respond(offscreens[record.id] != nil)

        case "proxy.onRequest.registered":
            AppLog.write("\(record.displayName): registered a proxy.onRequest listener", tag: "ext")

        case "cookies.get", "cookies.getAll", "cookies.set", "cookies.remove":
            handleCookieAPI(api: api, payload: payload, respond: respond)

        case "proxy.set":
            let value = payload["value"] as? [String: Any] ?? [:]
            proxySettings[record.id] = value
            AppLog.write("\(record.displayName): proxy mode \(value["mode"] as? String ?? "?")", tag: "ext")
            respond([:])

        case "notifications.create":
            let options = payload["options"] as? [String: Any] ?? [:]
            let title = options["title"] as? String ?? record.displayName
            let message = options["message"] as? String ?? ""
            let notificationID = payload["id"] as? String ?? UUID().uuidString
            let box = SendableBox(respond)
            NotificationPresenter.shared.post(title: title, body: message, identifier: notificationID) { granted in
                box.value(notificationID, granted ? nil : "Notifications are not permitted.")
            }

        case "network.fetch":
            handleNetworkFetch(payload: payload, record: record, respond: respond)

        case "scripting.executeScript":
            let target = payload["target"] as? [String: Any] ?? [:]
            let tabID = (target["tabId"] as? NSNumber)?.intValue ?? 0
            let worldID = payload["worldId"] as? String ?? "ISOLATED"
            let directory = root.appendingPathComponent(record.id, isDirectory: true)
            var code = payload["code"] as? String
            if code == nil, let function = payload["func"] as? String {
                code = "(\(function))();"
            }
            if code == nil, let files = payload["files"] as? [String], let first = files.first {
                code = readText(first, in: directory, extensionID: record.id)
            }
            guard let script = code else {
                respond(nil, "scripting.executeScript needs files, code or func")
                return
            }
            app?.extensionEvaluateInTab(id: tabID, script: script, inContentWorld: worldID != "MAIN") { result in
                respond([["frameId": 0, "result": result ?? NSNull()]], nil)
            }
        case "scripting.insertCSS":
            let css = payload["css"] as? String ?? ""
            let tabID = (payload["tabId"] as? NSNumber)?.intValue ?? 0
            app?.extensionEvaluateInTab(id: tabID, script: styleInjectionSource(css: css), inContentWorld: true) { _ in }
            respond([:])

        case "i18n.getMessage":
            let name = payload["name"] as? String ?? ""
            let substitutions = payload["substitutions"] as? [String] ?? []
            respond(localization(for: record)?.message(for: name, substitutions: substitutions))

        case "i18n.getAcceptLanguages":
            respond(["en-US", "en"])

        case "permissions.contains", "permissions.request":
            respond(permissionsSatisfied(payload["permissions"] as? [String: Any] ?? [:], by: record))

        case "permissions.getAll":
            respond([
                "permissions": record.manifest?.permissions ?? [],
                "origins": record.grants
            ])

        case "runtime.sendMessage":
            forwardRuntimeMessage(payload["message"], from: webView, frame: frame, envelopeID: envelopeID, context: context, to: identifier)

        case "runtime.response":
            let requestID = (payload["requestId"] as? NSNumber)?.intValue ?? (payload["requestId"] as? Int) ?? -1
            guard let pending = pendingReplies.removeValue(forKey: requestID) else { return }
            reply(on: pending.webView, frame: pending.frame, id: pending.envelopeID, value: payload["value"], error: nil, context: pending.context, runtimeID: pending.runtimeID)

        case "runtime.getManifest":
            respond(record.manifestObject)

        case "runtime.getPlatformInfo":
            respond([
                "os": "ios",
                "arch": "arm64",
                "nacl_arch": "",
                "manifestVersion": record.manifest?.manifestVersion ?? 3
            ])

        case "runtime.getURL":
            let path = payload["path"] as? String ?? ""
            respond("\(ExtensionSchemeHandler.scheme)://\(record.id)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")

        case "alarms.create":
            createAlarm(payload: payload, record: record)
            respond([:])

        case "alarms.clear":
            let name = payload["name"] as? String ?? ""
            clearAlarm(extensionID: record.id, name: name)
            respond(true)

        case "alarms.clearAll":
            cancelAlarms(for: record.id)
            respond(true)

        case "alarms.getAll":
            respond(alarmsPayload(for: record))

        case "downloads.download":
            guard let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
                respond(nil, "downloads.download expects { url }")
                return
            }
            let id = nextDownloadID
            nextDownloadID += 1
            if let itemID = app?.startURLSessionDownload(url) {
                downloadIDs[id] = itemID
            }
            respond(id)

        case "system.cpu":
            respond([
                "numOfProcessors": ProcessInfo.processInfo.processorCount,
                "archName": "arm64",
                "modelName": ""
            ])

        case "system.memory":
            respond([
                "capacity": ProcessInfo.processInfo.physicalMemory,
                "availableCapacity": 0
            ])

        case "declarativeNetRequest.getDynamicRules", "declarativeNetRequest.getSessionRules":
            respond([Any]())

        case "declarativeNetRequest.isRegexSupported":
            respond(["isSupported": false])

        case "offscreen.createDocument", "offscreen.closeDocument":
            respond([:])

        case "log":
            appendDiagnostic("\(record.displayName): \(payload["message"] as? String ?? "")")

        default:
            respond(nil, "Unsupported API: \(api)")
        }
    }

    private func deliverPortMessage(portId: String, messageJSON: String, to endpoint: PortEndpoint) {
        guard let webView = endpoint.webView else { return }
        let script = "window.__chromexPortMessage && window.__chromexPortMessage("
            + "\(JSBridge.literal(portId)), \(JSBridge.literal(messageJSON)));"
        if endpoint.context == "content" {
            webView.evaluateJavaScript(script, in: endpoint.frame, in: app?.contentWorld ?? .page, completionHandler: nil)
        } else {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func deliverPortDisconnect(portId: String, to endpoint: PortEndpoint) {
        guard let webView = endpoint.webView else { return }
        let script = "window.__chromexPortDisconnect && window.__chromexPortDisconnect("
            + "\(JSBridge.literal(portId)));"
        if endpoint.context == "content" {
            webView.evaluateJavaScript(script, in: endpoint.frame, in: app?.contentWorld ?? .page, completionHandler: nil)
        } else {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func handleCookieAPI(
        api: String,
        payload: [String: Any],
        respond: @escaping (Any?, String?) -> Void
    ) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let box = SendableBox(respond)

        switch api {
        case "cookies.get":
            let name = payload["name"] as? String ?? ""
            let host = (payload["url"] as? String).flatMap { URL(string: $0)?.host }
            let domain = payload["domain"] as? String
            store.getAllCookies { cookies in
                let found = cookies.first { cookie in
                    cookie.name == name && Self.cookieMatches(cookie, host: host, domain: domain)
                }
                let result = SendableBox(found.map { Self.cookiePayload($0) })
                Task { @MainActor in box.value(result.value, nil) }
            }

        case "cookies.getAll":
            let host = (payload["url"] as? String).flatMap { URL(string: $0)?.host }
            let domain = payload["domain"] as? String
            store.getAllCookies { cookies in
                let values = cookies
                    .filter { Self.cookieMatches($0, host: host, domain: domain) }
                    .map { Self.cookiePayload($0) }
                let result = SendableBox(values)
                Task { @MainActor in box.value(result.value, nil) }
            }

        case "cookies.set":
            guard let name = payload["name"] as? String,
                  let value = payload["value"] as? String else {
                box.value(nil, "cookies.set needs name and value")
                return
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .path: payload["path"] as? String ?? "/"
            ]
            if let domain = payload["domain"] as? String, !domain.isEmpty {
                properties[.domain] = domain
            } else if let urlString = payload["url"] as? String,
                      let host = URL(string: urlString)?.host {
                properties[.domain] = host
            } else {
                box.value(nil, "cookies.set needs a url or domain")
                return
            }
            properties[.secure] = ((payload["secure"] as? Bool) ?? false) ? "TRUE" : "FALSE"
            if let expires = payload["expirationDate"] as? Double {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }
            guard let cookie = HTTPCookie(properties: properties) else {
                box.value(nil, "cookies.set could not build a cookie")
                return
            }
            let cookiePayload = SendableBox(Self.cookiePayload(cookie))
            store.setCookie(cookie) {
                Task { @MainActor in box.value(cookiePayload.value, nil) }
            }

        case "cookies.remove":
            let name = payload["name"] as? String ?? ""
            let host = (payload["url"] as? String).flatMap { URL(string: $0)?.host }
            let domain = payload["domain"] as? String
            let removal = SendableBox(payload)
            store.getAllCookies { cookies in
                let boxed = SendableBox(cookies)
                Task { @MainActor in
                    for cookie in boxed.value where cookie.name == name
                        && Self.cookieMatches(cookie, host: host, domain: domain) {
                        store.delete(cookie, completionHandler: nil)
                    }
                    box.value(removal.value, nil)
                }
            }

        default:
            box.value(nil, "Unsupported cookie call")
        }
    }

    nonisolated static func cookieMatches(_ cookie: HTTPCookie, host: String?, domain: String?) -> Bool {
        if let domain, !domain.isEmpty {
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return cookie.domain == domain || cookie.domain == bare || cookie.domain == "." + bare
        }
        if let host, !host.isEmpty {
            return host == cookie.domain || host.hasSuffix(cookie.domain)
        }
        return true
    }

    nonisolated static func cookiePayload(_ cookie: HTTPCookie) -> [String: Any] {
        var payload: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "hostOnly": !cookie.domain.hasPrefix("."),
            "session": cookie.isSessionOnly
        ]
        if let expires = cookie.expiresDate {
            payload["expirationDate"] = expires.timeIntervalSince1970
        }
        if let sameSite = cookie.sameSitePolicy?.rawValue {
            if sameSite == "SameSiteStrict" {
                payload["sameSite"] = "strict"
            } else if sameSite == "SameSiteLax" {
                payload["sameSite"] = "lax"
            }
        }
        return payload
    }

    nonisolated static func proxyDictionary(from value: [String: Any]) -> [AnyHashable: Any]? {
        guard let mode = value["mode"] as? String else { return nil }
        switch mode {
        case "direct":
            return nil
        case "fixed_servers":
            let rules = value["rules"] as? [String: Any] ?? [:]
            let proxy = (rules["singleProxy"] as? [String: Any])
                ?? (rules["proxyForHttps"] as? [String: Any])
                ?? (rules["proxyForHttp"] as? [String: Any])
            guard let host = proxy?["host"] as? String,
                  let port = (proxy?["port"] as? NSNumber)?.intValue else { return nil }
            let scheme = (proxy?["scheme"] as? String)?.lowercased() ?? "http"
            if scheme.hasPrefix("socks") {
                return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
            }
            return [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port
            ]
        default:
            AppLog.write("proxy mode \(mode) is not supported by the native bridge", tag: "ext")
            return nil
        }
    }

    /// Extension pages get Chrome's host-permission privilege: requests to granted
    /// hosts go through native `URLSession`, so they are not blocked by CORS the way
    /// a normal web page would be.
    private func handleNetworkFetch(
        payload: [String: Any],
        record: InstalledExtension,
        respond: @escaping (Any?, String?) -> Void
    ) {
        guard let urlString = payload["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            respond(nil, "network.fetch expects an http(s) url")
            return
        }
        guard isGranted(record: record, url: url) else {
            respond(nil, "network.fetch: this extension has no access to \(url.host ?? urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = (payload["method"] as? String ?? "GET").uppercased()
        request.timeoutInterval = 60
        if let headers = payload["headers"] as? [String: String] {
            for (key, value) in headers where !key.isEmpty {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = payload["body"] as? String, !body.isEmpty, let data = Data(base64Encoded: body) {
            request.httpBody = data
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        if let proxy = proxySettings[record.id], let dictionary = Self.proxyDictionary(from: proxy) {
            configuration.connectionProxyDictionary = dictionary
        }
        let box = SendableBox(respond)
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            var headerFields: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headerFields[String(describing: key)] = String(describing: value)
            }
            let status = http?.statusCode ?? 0
            let encoded = (data ?? Data()).base64EncodedString()
            let finalURL = http?.url?.absoluteString ?? urlString
            let failure = error?.localizedDescription
            Task { @MainActor in
                if let failure {
                    box.value(nil, failure)
                    return
                }
                box.value([
                    "status": status,
                    "headers": headerFields,
                    "body": encoded,
                    "url": finalURL
                ], nil)
            }
        }.resume()
    }

    private func tabsPayload(matching query: [String: Any], record: InstalledExtension) -> [[String: Any]] {
        guard let tabs = app?.extensionTabs else { return [] }
        let wantActive = query["active"] as? Bool
        return tabs.compactMap { tab in
            if let wantActive, tab.isActive != wantActive { return nil }
            return tabPayload(for: tab, record: record)
        }
    }

    private func tabPayload(for tab: ExtensionTabInfo?, record: InstalledExtension) -> [String: Any] {
        guard let tab else { return [:] }
        // Chrome only exposes URL and title for tabs the extension may read.
        let url = tab.url.isEmpty ? nil : URL(string: tab.url)
        let canRead = record.grants.contains("<all_urls>")
            || record.grants.contains { pattern in
                guard let url else { return false }
                return HostMatcher.matches(pattern: pattern, url: url)
            }
        return [
            "id": tab.id,
            "index": tab.id - 1,
            "windowId": 0,
            "active": tab.isActive,
            "highlighted": tab.isActive,
            "incognito": tab.isPrivate,
            "url": canRead ? tab.url : "",
            "title": canRead ? tab.title : "",
            "status": "complete"
        ]
    }

    // MARK: Alarms

    private func createAlarm(payload: [String: Any], record: InstalledExtension) {
        var name = payload["name"] as? String ?? ""
        var delay = payload["delayInMinutes"] as? Double
        var period = payload["periodInMinutes"] as? Double
        if name.isEmpty, let info = payload["info"] as? [String: Any] {
            delay = info["delayInMinutes"] as? Double
            period = info["periodInMinutes"] as? Double
        }
        if delay == nil, let period { delay = period }
        if name.isEmpty { name = "chromex-alarm-\(UUID().uuidString.prefix(6))" }

        let interval = (delay ?? 1) * 60
        let spec = AlarmSpec(
            name: name,
            scheduledTime: Date().addingTimeInterval(interval),
            periodInMinutes: period
        )
        alarms[record.id, default: [:]][name] = spec
        scheduleAlarm(extensionID: record.id, name: name, after: interval)
    }

    private func scheduleAlarm(extensionID: String, name: String, after seconds: TimeInterval) {
        clearAlarm(extensionID: extensionID, name: name, keepSpec: true)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, seconds)))
            guard !Task.isCancelled else { return }
            self?.fireAlarm(extensionID: extensionID, name: name)
        }
        alarmTasks[extensionID, default: [:]][name] = task
    }

    private func fireAlarm(extensionID: String, name: String) {
        guard let runtime = runtimes[extensionID] else { return }
        let json = JSBridge.stringify(["name": name])
        runtime.evaluate("window.__chromexAlarm && window.__chromexAlarm(\(JSBridge.literal(json)));")

        guard let spec = alarms[extensionID]?[name], let period = spec.periodInMinutes else {
            alarms[extensionID]?[name] = nil
            alarmTasks[extensionID]?[name] = nil
            return
        }
        alarms[extensionID]?[name]?.scheduledTime = Date().addingTimeInterval(period * 60)
        scheduleAlarm(extensionID: extensionID, name: name, after: period * 60)
    }

    private func clearAlarm(extensionID: String, name: String, keepSpec: Bool = false) {
        alarmTasks[extensionID]?[name]?.cancel()
        alarmTasks[extensionID]?[name] = nil
        if !keepSpec {
            alarms[extensionID]?[name] = nil
        }
    }

    private func cancelAlarms(for extensionID: String) {
        alarmTasks[extensionID]?.values.forEach { $0.cancel() }
        alarmTasks[extensionID] = nil
        alarms[extensionID] = nil
    }

    private func alarmsPayload(for record: InstalledExtension) -> [[String: Any]] {
        (alarms[record.id] ?? [:]).values.map { spec in
            var entry: [String: Any] = [
                "name": spec.name,
                "scheduledTime": spec.scheduledTime.timeIntervalSince1970 * 1000
            ]
            if let period = spec.periodInMinutes {
                entry["periodInMinutes"] = period
            } else {
                entry["periodInMinutes"] = NSNull()
            }
            return entry
        }
    }

    // MARK: Messaging

    private func forwardRuntimeMessage(
        _ message: Any?,
        from webView: WKWebView?,
        frame: WKFrameInfo?,
        envelopeID: Int,
        context: String,
        to identifier: String
    ) {
        if webView == nil, let offscreen = offscreens[identifier] {
            let requestID = nextRequestID
            nextRequestID += 1
            pendingReplies[requestID] = PendingReply(
                webView: nil,
                frame: nil,
                context: "background",
                envelopeID: envelopeID,
                runtimeID: identifier
            )
            offscreen.dispatch(JSBridge.stringify(message)) { [weak self] result in
                guard let self else { return }
                if result == "__none__", let pending = self.pendingReplies.removeValue(forKey: requestID) {
                    self.reply(on: pending.webView, frame: pending.frame, id: pending.envelopeID, value: nil, error: nil, context: pending.context, runtimeID: pending.runtimeID)
                }
            }
            return
        }

        guard let webView else { return }
        guard let runtime = runtimes[identifier] else {
            reply(on: webView, frame: frame, id: envelopeID, value: nil, error: "This extension has no running background page.", context: context)
            return
        }

        let requestID = nextRequestID
        nextRequestID += 1
        pendingReplies[requestID] = PendingReply(webView: webView, frame: frame, context: context, envelopeID: envelopeID)

        let payloadJSON = JSBridge.stringify(message)
        runtime.dispatch(requestID: requestID, payloadJSON: payloadJSON) { [weak self] result in
            guard let self else { return }
            if result == "__none__" {
                if let pending = self.pendingReplies.removeValue(forKey: requestID) {
                    self.reply(on: pending.webView, frame: pending.frame, id: pending.envelopeID, value: nil, error: nil, context: pending.context, runtimeID: pending.runtimeID)
                }
            }
        }
    }

    private func notifyStorageChanged(_ identifier: String, changes: [String: Any]) {
        guard !changes.isEmpty else { return }
        let json = JSBridge.stringify(changes)
        if let runtime = runtimes[identifier] {
            runtime.notifyStorageChanged(json)
        }
        app?.notifyContentStorageChanged(json)
    }

    private func reply(
        on webView: WKWebView?,
        frame: WKFrameInfo?,
        id: Int,
        value: Any?,
        error: String?,
        context: String,
        runtimeID: String? = nil
    ) {
        let json = JSBridge.stringify(value)
        let errorLiteral = error.map(JSBridge.literal) ?? "null"
        let script = "window.__chromexReply(\(id), \(JSBridge.literal(json)), \(errorLiteral));"

        if webView == nil, let runtimeID, let runtime = runtimes[runtimeID] {
            runtime.evaluate(script)
            return
        }
        guard let webView else { return }

        if context == "content" {
            let world = app?.contentWorld ?? .page
            webView.evaluateJavaScript(script, in: frame, in: world) { [weak webView] result in
                guard case .failure = result else { return }
                // A stale frame snapshot fails; retry in the main frame so the
                // caller still gets an answer instead of hanging.
                webView?.evaluateJavaScript(script, in: nil, in: world, completionHandler: nil)
            }
        } else {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: Diagnostics

    func appendDiagnostic(_ message: String) {
        diagnostics.append(message)
        if diagnostics.count > 200 {
            diagnostics.removeFirst(diagnostics.count - 200)
        }
        AppLog.write(message, tag: "ext")
    }

    func clearDiagnostics() {
        diagnostics.removeAll()
    }

    func activeRuntimeCount() -> Int {
        runtimes.count
    }
}
