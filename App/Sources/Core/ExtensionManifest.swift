import Foundation

// MARK: - Manifest model

enum RunAt: String, Codable, Sendable, Hashable {
    case documentStart = "document_start"
    case documentEnd = "document_end"
    case documentIdle = "document_idle"
}

struct ContentScript: Sendable, Hashable {
    var matches: [String] = []
    var excludeMatches: [String] = []
    var js: [String] = []
    var css: [String] = []
    var runAt: RunAt = .documentIdle
    var allFrames: Bool = false
}

struct ExtensionAction: Sendable, Hashable {
    var defaultPopup: String?
    var defaultTitle: String?
    var defaultIconPath: String?
}

enum BackgroundKind: String, Sendable {
    case serviceWorker = "service_worker"
    case scripts = "scripts"
    case page = "page"
    case none
}

struct ExtensionManifest: Sendable {
    var manifestVersion: Int
    var name: String
    var version: String
    var summary: String
    var permissions: [String]
    var hostPermissions: [String]
    var optionalPermissions: [String]
    var contentScripts: [ContentScript]
    var action: ExtensionAction?
    var optionsPage: String?
    var backgroundScripts: [String]
    var backgroundPage: String?
    var backgroundKind: BackgroundKind
    var icons: [String: String]
    var contentSecurityPolicy: String?
}

enum ManifestError: Error, LocalizedError, Equatable {
    case notAJSONObject
    case missingManifestVersion
    case unsupportedManifestVersion(Int)
    case missingName
    case missingVersion
    case invalidContentScript(Int)

    var errorDescription: String? {
        switch self {
        case .notAJSONObject:
            return "manifest.json is not a JSON object."
        case .missingManifestVersion:
            return "manifest.json has no manifest_version."
        case .unsupportedManifestVersion(let version):
            return "Manifest version \(version) is not supported. CHROMEX runs Manifest V2 and V3."
        case .missingName:
            return "manifest.json has no name."
        case .missingVersion:
            return "manifest.json has no version."
        case .invalidContentScript(let index):
            return "content_scripts[\(index)] is missing a matches array."
        }
    }
}

// MARK: - Parsing

enum ManifestParser {
    static func parse(data: Data) throws -> ExtensionManifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError.notAJSONObject
        }
        guard let manifestVersion = root["manifest_version"] as? Int else {
            throw ManifestError.missingManifestVersion
        }
        guard manifestVersion == 2 || manifestVersion == 3 else {
            throw ManifestError.unsupportedManifestVersion(manifestVersion)
        }
        guard let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw ManifestError.missingName
        }
        guard let version = root["version"] as? String, !version.isEmpty else {
            throw ManifestError.missingVersion
        }

        var permissions = root["permissions"] as? [String] ?? []
        var hostPermissions = root["host_permissions"] as? [String] ?? []

        // Manifest V2 keeps host patterns inside `permissions`.
        if manifestVersion == 2 {
            let split = permissions.reduce(into: (plain: [String](), hosts: [String]())) { result, entry in
                if HostMatcher.isHostPattern(entry) {
                    result.hosts.append(entry)
                } else {
                    result.plain.append(entry)
                }
            }
            permissions = split.plain
            hostPermissions.append(contentsOf: split.hosts)
        }

        let contentScripts = try parseContentScripts(root["content_scripts"])

        let actionDict = (root["action"] as? [String: Any]) ?? (root["browser_action"] as? [String: Any])
        let action: ExtensionAction? = actionDict.map { dict in
            ExtensionAction(
                defaultPopup: dict["default_popup"] as? String,
                defaultTitle: dict["default_title"] as? String,
                defaultIconPath: iconPath(from: dict["default_icon"])
            )
        }

        var backgroundScripts: [String] = []
        var backgroundPage: String?
        var backgroundKind: BackgroundKind = .none
        if let background = root["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String {
                backgroundScripts = [worker]
                backgroundKind = .serviceWorker
            } else if let scripts = background["scripts"] as? [String] {
                backgroundScripts = scripts
                backgroundKind = .scripts
            } else if let page = background["page"] as? String {
                backgroundPage = page
                backgroundKind = .page
            }
        }

        let optionsPage = (root["options_page"] as? String)
            ?? ((root["options_ui"] as? [String: Any])?["page"] as? String)

        return ExtensionManifest(
            manifestVersion: manifestVersion,
            name: name,
            version: version,
            summary: (root["description"] as? String) ?? "",
            permissions: permissions,
            hostPermissions: Array(Set(hostPermissions)).sorted(),
            optionalPermissions: (root["optional_permissions"] as? [String]) ?? [],
            contentScripts: contentScripts,
            action: action,
            optionsPage: optionsPage,
            backgroundScripts: backgroundScripts,
            backgroundPage: backgroundPage,
            backgroundKind: backgroundKind,
            icons: (root["icons"] as? [String: String]) ?? [:],
            contentSecurityPolicy: contentSecurityPolicy(from: root["content_security_policy"])
        )
    }

    private static func parseContentScripts(_ raw: Any?) throws -> [ContentScript] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return try array.enumerated().map { index, dict in
            guard let matches = dict["matches"] as? [String], !matches.isEmpty else {
                throw ManifestError.invalidContentScript(index)
            }
            return ContentScript(
                matches: matches,
                excludeMatches: (dict["exclude_matches"] as? [String]) ?? [],
                js: (dict["js"] as? [String]) ?? [],
                css: (dict["css"] as? [String]) ?? [],
                runAt: RunAt(rawValue: (dict["run_at"] as? String) ?? "") ?? .documentIdle,
                allFrames: (dict["all_frames"] as? Bool) ?? false
            )
        }
    }

    private static func iconPath(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let dict = raw as? [String: String] {
            return dict.sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }.first?.value
        }
        return nil
    }

    private static func contentSecurityPolicy(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let dict = raw as? [String: String] { return dict["extension_pages"] }
        return nil
    }
}

// MARK: - Host matching

enum HostMatcher {
    static func isHostPattern(_ value: String) -> Bool {
        if value == "<all_urls>" { return true }
        if value.contains("://") { return true }
        if value.hasPrefix("*.") { return true }
        return false
    }

    /// Supports `<all_urls>`, `*://host/path`, `https://*.example.com/*`,
    /// and bare hosts such as `example.com`.
    static func matches(pattern rawPattern: String, url: URL) -> Bool {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return false }
        if pattern == "<all_urls>" { return isWebURL(url) }

        var working = pattern
        if !working.contains("://") {
            working = "*://" + working
            if !working.contains("/", after: "://") { working += "/*" }
        }

        guard let schemeSeparator = working.range(of: "://") else { return false }
        let scheme = String(working[working.startIndex..<schemeSeparator.lowerBound]).lowercased()
        let remainder = String(working[schemeSeparator.upperBound...])

        guard let urlScheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "*":
            if urlScheme != "http" && urlScheme != "https" { return false }
        case urlScheme:
            break
        default:
            return false
        }

        let hostAndPath = remainder
        let host = String(hostAndPath.prefix { $0 != "/" })
        let path = hostAndPath.count > host.count ? String(hostAndPath.dropFirst(host.count)) : "/*"

        guard let urlHost = url.host?.lowercased(), !urlHost.isEmpty else { return false }
        if host != "*" {
            if host.hasPrefix("*.") {
                let suffix = String(host.dropFirst(2)).lowercased()
                if urlHost != suffix && !urlHost.hasSuffix("." + suffix) { return false }
            } else if host.lowercased() != urlHost {
                return false
            }
        }

        return globMatch(pattern: path.isEmpty ? "/*" : path, value: url.path.isEmpty ? "/" : url.path)
    }

    static func anyMatch(patterns: [String], url: URL) -> Bool {
        patterns.contains { matches(pattern: $0, url: url) }
    }

    static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    private static func globMatch(pattern: String, value: String) -> Bool {
        if pattern == "/*" || pattern == "*" { return true }
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        guard let expression = try? NSRegularExpression(pattern: regex) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }
}

private extension String {
    func contains(_ needle: String, after marker: String) -> Bool {
        guard let markerRange = range(of: marker) else { return false }
        return range(of: needle, range: markerRange.upperBound..<endIndex) != nil
    }
}

// MARK: - Compatibility catalog

enum APIStatus: String, Codable, Sendable {
    case supported
    case partial
    case unsupported
    case refused
}

struct APIEntry: Identifiable, Codable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var status: APIStatus
    var note: String
}

enum ExtensionAPICatalog {
    static let entries: [APIEntry] = [
        APIEntry(name: "content_scripts", status: .supported, note: "Injected at the declared run_at, JS and CSS."),
        APIEntry(name: "storage.local", status: .supported, note: "Local key/value store, persisted per extension."),
        APIEntry(name: "storage.session", status: .partial, note: "Mapped to local storage; cleared when the extension is disabled."),
        APIEntry(name: "runtime.sendMessage", status: .supported, note: "Content, popup and background pages can message the background."),
        APIEntry(name: "runtime.onMessage", status: .supported, note: "Delivered to the background page; responses are routed back."),
        APIEntry(name: "runtime.getURL", status: .supported, note: "Returns a chromex-extension:// URL for packaged resources."),
        APIEntry(name: "tabs.query", status: .partial, note: "Reports the active tab only. Titles and URLs require host access."),
        APIEntry(name: "tabs.create", status: .partial, note: "Opens a tab in CHROMEX; the extension cannot manage other tabs."),
        APIEntry(name: "action (popup)", status: .supported, note: "The declared popup opens in a CHROMEX sheet."),
        APIEntry(name: "action.setBadgeText", status: .unsupported, note: "No badge surface in this build."),
        APIEntry(name: "scripting.executeScript", status: .unsupported, note: "Use declared content_scripts instead."),
        APIEntry(name: "i18n", status: .unsupported, note: "_locales is not resolved in this build."),
        APIEntry(name: "alarms", status: .unsupported, note: "iOS cannot keep a background scheduler alive."),
        APIEntry(name: "notifications", status: .unsupported, note: "Not bridged in this build."),
        APIEntry(name: "contextMenus", status: .unsupported, note: "Not bridged in this build."),
        APIEntry(name: "commands", status: .unsupported, note: "Not bridged in this build."),
        APIEntry(name: "declarativeNetRequest", status: .unsupported, note: "Category blocking is provided by CHROMEX itself, not per extension."),
        APIEntry(name: "webRequest", status: .unsupported, note: "WebKit gives no request observation hook to the browser."),
        APIEntry(name: "webRequestBlocking", status: .refused, note: "The engine cannot intercept requests. Refused by design."),
        APIEntry(name: "cookies", status: .unsupported, note: "Cookie access is not exposed to extensions."),
        APIEntry(name: "history", status: .unsupported, note: "Not exposed to extensions."),
        APIEntry(name: "bookmarks", status: .unsupported, note: "Not exposed to extensions."),
        APIEntry(name: "downloads", status: .unsupported, note: "Not exposed to extensions."),
        APIEntry(name: "identity", status: .unsupported, note: "No OAuth bridge."),
        APIEntry(name: "nativeMessaging", status: .refused, note: "iOS forbids spawning helper processes."),
        APIEntry(name: "debugger", status: .refused, note: "No page-process debugging surface."),
        APIEntry(name: "offscreen", status: .unsupported, note: "No offscreen document concept in WebKit."),
        APIEntry(name: "tabGroups", status: .unsupported, note: "Not bridged in this build."),
        APIEntry(name: "sidePanel", status: .unsupported, note: "No side panel on iPhone."),
        APIEntry(name: "userScripts", status: .unsupported, note: "Not bridged in this build."),
        APIEntry(name: "omnibox", status: .unsupported, note: "The address bar is not extensible."),
        APIEntry(name: "devtools", status: .unsupported, note: "No extension developer tools on iOS.")
    ]

    static let unsupportedPermissions: Set<String> = [
        "alarms", "cookies", "debugger", "declarativeNetRequest", "history",
        "identity", "management", "nativeMessaging", "notifications", "offscreen",
        "proxy", "scripting", "tabGroups", "userScripts", "webRequest", "webRequestBlocking"
    ]

    static let refusedPermissions: Set<String> = ["debugger", "nativeMessaging", "webRequestBlocking"]

    static func entry(named name: String) -> APIEntry? {
        entries.first { $0.name == name }
    }
}

// MARK: - Compatibility analysis

enum CompatibilityVerdict: String, Codable, Sendable, CaseIterable {
    case runs
    case runsWithLimits = "runs-with-limits"
    case unsupported
    case refused

    var title: String {
        switch self {
        case .runs: return "Runs"
        case .runsWithLimits: return "Runs with limits"
        case .unsupported: return "Unsupported"
        case .refused: return "Refused"
        }
    }

    var explanation: String {
        switch self {
        case .runs:
            return "Every API this extension declares is implemented by CHROMEX."
        case .runsWithLimits:
            return "It will run, but some of what it declares is not available on iOS."
        case .unsupported:
            return "The parts CHROMEX can run do not add up to a working extension."
        case .refused:
            return "This extension needs a capability that CHROMEX will not grant."
        }
    }
}

struct CompatibilityFinding: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var api: String
    var status: APIStatus
    var message: String
}

struct CompatibilityReport: Codable, Sendable, Hashable {
    var verdict: CompatibilityVerdict
    var findings: [CompatibilityFinding]
    var unsupported: [String]
    var supported: [String]
    var requiresBroadAccess: Bool
    var score: Int
    var analyzedAt: Date = Date()
}

enum CompatibilityAnalyzer {
    static func analyze(_ manifest: ExtensionManifest) -> CompatibilityReport {
        var findings: [CompatibilityFinding] = []
        var unsupported: [String] = []
        var supported: [String] = []

        for permission in manifest.permissions {
            if ExtensionAPICatalog.refusedPermissions.contains(permission) {
                findings.append(CompatibilityFinding(
                    api: permission,
                    status: .refused,
                    message: "Refused by CHROMEX: the iOS engine cannot provide this."
                ))
                unsupported.append(permission)
            } else if ExtensionAPICatalog.unsupportedPermissions.contains(permission) {
                findings.append(CompatibilityFinding(
                    api: permission,
                    status: .unsupported,
                    message: "Declared but not implemented in this build."
                ))
                unsupported.append(permission)
            } else if let entry = ExtensionAPICatalog.entry(named: permission) {
                supported.append(permission)
                if entry.status == .partial || entry.status == .unsupported {
                    findings.append(CompatibilityFinding(api: permission, status: entry.status, message: entry.note))
                }
            }
        }

        if !manifest.contentScripts.isEmpty { supported.append("content_scripts") }
        if manifest.action?.defaultPopup != nil { supported.append("action") }
        if !manifest.backgroundScripts.isEmpty || manifest.backgroundPage != nil {
            supported.append("background")
        }

        let broad = manifest.hostPermissions.contains { pattern in
            pattern == "<all_urls>" || pattern.contains("*://*") || pattern == "*://*/*"
        }

        let refused = findings.contains { $0.status == .refused }
        let hasWorkingSurface = !manifest.contentScripts.isEmpty
            || manifest.action?.defaultPopup != nil
            || !manifest.backgroundScripts.isEmpty
            || manifest.backgroundPage != nil

        let verdict: CompatibilityVerdict
        if refused {
            verdict = .refused
        } else if !hasWorkingSurface {
            verdict = .unsupported
        } else if findings.contains(where: { $0.status == .unsupported }) {
            verdict = .runsWithLimits
        } else {
            verdict = .runs
        }

        var score = 100
        for finding in findings {
            switch finding.status {
            case .refused: score -= 30
            case .unsupported: score -= 10
            case .partial: score -= 4
            case .supported: break
            }
        }
        if broad { score -= 5 }
        score = max(0, min(100, score))

        return CompatibilityReport(
            verdict: verdict,
            findings: findings,
            unsupported: Array(Set(unsupported)).sorted(),
            supported: Array(Set(supported)).sorted(),
            requiresBroadAccess: broad,
            score: score
        )
    }
}
