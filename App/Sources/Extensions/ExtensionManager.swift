import Foundation
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

    /// Host patterns the user consented to: declared hosts plus content-script matches.
    static func requestedGrants(for manifest: ExtensionManifest) -> [String] {
        var patterns = manifest.hostPermissions
        for script in manifest.contentScripts {
            patterns.append(contentsOf: script.matches)
        }
        return Array(Set(patterns)).sorted()
    }
}

/// A script ready to be turned into a `WKUserScript`.
struct ScriptInjection: Sendable, Hashable {
    var source: String
    var runAt: RunAt
    var allFrames: Bool
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

// MARK: - Manager

@MainActor
final class ExtensionManager: ObservableObject {
    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var diagnostics: [String] = []

    let root: URL
    let schemeHandler = ExtensionSchemeHandler()

    private(set) lazy var bridge: ExtensionBridge = {
        let bridge = ExtensionBridge()
        bridge.manager = self
        return bridge
    }()

    private var runtimes: [String: ExtensionBackgroundRuntime] = [:]
    private var storages: [String: ExtensionStorage] = [:]
    private var tokens: [String: String] = [:]
    private var pendingReplies: [Int: (webView: WKWebView, envelopeID: Int)] = [:]
    private var nextRequestID = 1

    /// Supplied by the app model so extensions see real CHROMEX tabs.
    var tabInfoProvider: ((InstalledExtension) -> [[String: Any]])?
    var openTabHandler: ((URL) -> Void)?

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
            scheduleRuntime(for: record)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: registryURL, options: [.atomic])
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
        installed.append(record)
        persist()
        scheduleRuntime(for: record)
        return record
    }

    func remove(_ record: InstalledExtension) {
        stopRuntime(for: record.id)
        schemeHandler.unregister(extensionID: record.id)
        storages[record.id] = nil
        installed.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(record.id, isDirectory: true))
        persist()
    }

    func setEnabled(_ record: InstalledExtension, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == record.id }) else { return }
        installed[index].isEnabled = enabled
        persist()
        if enabled {
            scheduleRuntime(for: installed[index])
        } else {
            stopRuntime(for: record.id)
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
        let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "background")
        let runtime = ExtensionBackgroundRuntime(
            extensionID: record.id,
            manifest: manifest,
            directory: root.appendingPathComponent(record.id, isDirectory: true),
            schemeHandler: schemeHandler,
            bridge: bridge,
            token: token,
            shim: shim
        )
        runtimes[record.id] = runtime
        runtime.onUnhandled = { [weak self] requestID in
            guard let self, let pending = self.pendingReplies.removeValue(forKey: requestID) else { return }
            self.reply(on: pending.webView, id: pending.envelopeID, value: nil, error: nil)
        }
    }

    private func stopRuntime(for identifier: String) {
        runtimes[identifier]?.stop()
        runtimes[identifier] = nil
    }

    func makePopupWebView(for record: InstalledExtension) -> WKWebView? {
        guard record.isEnabled, let manifest = record.manifest,
              let popup = manifest.action?.defaultPopup else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ExtensionSchemeHandler.scheme)
        let token = registerToken(for: record.id)
        let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "popup")
        configuration.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(bridge, name: "chromexBridge")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let urlString = "\(ExtensionSchemeHandler.scheme)://\(record.id)/\(popup)"
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    // MARK: Caps

    func registerToken(for extensionID: String) -> String {
        let token = UUID().uuidString
        tokens[token] = extensionID
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

                let token = registerToken(for: record.id)
                let shim = ExtensionShim.source(token: token, extensionID: record.id, context: "content")
                result.append(ScriptInjection(source: shim, runAt: .documentStart, allFrames: script.allFrames))

                for path in script.css {
                    guard let css = readText(path, in: directory) else { continue }
                    result.append(ScriptInjection(
                        source: styleInjectionSource(css: css),
                        runAt: .documentStart,
                        allFrames: script.allFrames
                    ))
                }
                for path in script.js {
                    guard let source = readText(path, in: directory) else { continue }
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

    private func readText(_ relativePath: String, in directory: URL) -> String? {
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
        let base = directory.standardizedFileURL.path
        guard candidate.path.hasPrefix(base + "/") else { return nil }
        return try? String(contentsOf: candidate, encoding: .utf8)
    }

    private func isGranted(record: InstalledExtension, patterns: [String]) -> Bool {
        if record.grants.contains("<all_urls>") { return true }
        return patterns.contains { record.grants.contains($0) }
    }

    // MARK: Bridge

    func handleBridgeMessage(_ body: [String: Any], from webView: WKWebView?) {
        guard let token = body["token"] as? String,
              let identifier = extensionID(for: token),
              let record = installed.first(where: { $0.id == identifier }),
              record.isEnabled else {
            return
        }

        let envelopeID = (body["id"] as? NSNumber)?.intValue ?? (body["id"] as? Int) ?? 0
        let api = body["api"] as? String ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]
        let extensionStorage = storage(for: record)

        switch api {
        case "storage.get":
            let keys = payload["keys"]
            reply(on: webView, id: envelopeID, value: extensionStorage.snapshot(for: keys), error: nil)

        case "storage.set":
            guard let items = payload["items"] as? [String: Any] else {
                reply(on: webView, id: envelopeID, value: nil, error: "storage.set expects an object")
                return
            }
            let changes = extensionStorage.set(items)
            notifyStorageChanged(identifier, changes: changes)
            reply(on: webView, id: envelopeID, value: [:], error: nil)

        case "storage.remove":
            let keys = (payload["keys"] as? [String]) ?? []
            let changes = extensionStorage.remove(keys)
            notifyStorageChanged(identifier, changes: changes)
            reply(on: webView, id: envelopeID, value: [:], error: nil)

        case "storage.clear":
            let changes = extensionStorage.clear()
            notifyStorageChanged(identifier, changes: changes)
            reply(on: webView, id: envelopeID, value: [:], error: nil)

        case "storage.bytes":
            reply(on: webView, id: envelopeID, value: extensionStorage.byteCount(), error: nil)

        case "tabs.query":
            let tabs = tabInfoProvider?(record) ?? []
            reply(on: webView, id: envelopeID, value: tabs, error: nil)

        case "tabs.create":
            if let options = payload["options"] as? [String: Any],
               let urlString = options["url"] as? String,
               let url = URL(string: urlString) {
                openTabHandler?(url)
                reply(on: webView, id: envelopeID, value: [:], error: nil)
            } else {
                reply(on: webView, id: envelopeID, value: nil, error: "tabs.create expects { url }")
            }

        case "runtime.sendMessage":
            let message = payload["message"]
            forwardRuntimeMessage(message, from: webView, envelopeID: envelopeID, to: identifier)

        case "runtime.response":
            let requestID = (payload["requestId"] as? NSNumber)?.intValue ?? (payload["requestId"] as? Int) ?? -1
            guard let pending = pendingReplies.removeValue(forKey: requestID) else { return }
            reply(on: pending.webView, id: pending.envelopeID, value: payload["value"], error: nil)

        case "log":
            appendDiagnostic("\(record.displayName): \(payload["message"] as? String ?? "")")

        default:
            reply(on: webView, id: envelopeID, value: nil, error: "Unsupported API: \(api)")
        }
    }

    private func forwardRuntimeMessage(_ message: Any?, from webView: WKWebView?, envelopeID: Int, to identifier: String) {
        guard let webView else { return }
        guard let runtime = runtimes[identifier] else {
            reply(on: webView, id: envelopeID, value: nil, error: "This extension has no running background page.")
            return
        }

        let requestID = nextRequestID
        nextRequestID += 1
        pendingReplies[requestID] = (webView, envelopeID)

        let payloadJSON = JSBridge.stringify(message)
        runtime.dispatch(requestID: requestID, payloadJSON: payloadJSON) { [weak self] result in
            guard let self else { return }
            if result == "__none__" {
                if let pending = self.pendingReplies.removeValue(forKey: requestID) {
                    self.reply(on: pending.webView, id: pending.envelopeID, value: nil, error: nil)
                }
            }
        }
    }

    private func notifyStorageChanged(_ identifier: String, changes: [String: Any]) {
        guard !changes.isEmpty, let runtime = runtimes[identifier] else { return }
        runtime.notifyStorageChanged(JSBridge.stringify(changes))
    }

    private func reply(on webView: WKWebView?, id: Int, value: Any?, error: String?) {
        guard let webView else { return }
        let json = JSBridge.stringify(value)
        let errorLiteral = error.map(JSBridge.literal) ?? "null"
        let script = "window.__chromexReply(\(id), \(JSBridge.literal(json)), \(errorLiteral));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Diagnostics

    func appendDiagnostic(_ message: String) {
        diagnostics.append(message)
        if diagnostics.count > 200 {
            diagnostics.removeFirst(diagnostics.count - 200)
        }
    }

    func clearDiagnostics() {
        diagnostics.removeAll()
    }

    func activeRuntimeCount() -> Int {
        runtimes.count
    }
}
