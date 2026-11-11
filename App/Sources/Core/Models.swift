import Foundation

// MARK: - Browsing domain

/// A saved bookmark. URL is stored as a string so the model stays trivially Codable.
struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var createdAt: Date = Date()
}

/// One history visit. Private browsing never writes these.
struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var visitedAt: Date = Date()

    var host: String {
        URL(string: urlString)?.host ?? urlString
    }
}

/// A tab as it should be restored on next launch.
struct SessionTab: Codable, Hashable, Sendable {
    var urlString: String
    var title: String
    var groupID: UUID?
}

struct TabGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String
}

// MARK: - Downloads

struct DownloadItem: Identifiable, Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case inProgress
        case completed
        case failed
    }

    var id: UUID = UUID()
    var filename: String
    var sourceURLString: String
    var state: State
    var byteCount: Int64 = 0
    var createdAt: Date = Date()
    var localPath: String?
    var errorMessage: String?
}

// MARK: - Search

struct SearchEngine: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Query template. Must contain `%s`.
    var template: String
    var isBuiltIn: Bool = false

    func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    static let builtIns: [SearchEngine] = [
        SearchEngine(
            id: UUID(uuidString: "6C0F4B1E-0000-4000-8000-000000000001")!,
            name: "Google",
            template: "https://www.google.com/search?q=%s",
            isBuiltIn: true
        ),
        SearchEngine(
            id: UUID(uuidString: "6C0F4B1E-0000-4000-8000-000000000002")!,
            name: "DuckDuckGo",
            template: "https://duckduckgo.com/?q=%s",
            isBuiltIn: true
        ),
        SearchEngine(
            id: UUID(uuidString: "6C0F4B1E-0000-4000-8000-000000000003")!,
            name: "Bing",
            template: "https://www.bing.com/search?q=%s",
            isBuiltIn: true
        ),
        SearchEngine(
            id: UUID(uuidString: "6C0F4B1E-0000-4000-8000-000000000004")!,
            name: "Brave",
            template: "https://search.brave.com/search?q=%s",
            isBuiltIn: true
        ),
        SearchEngine(
            id: UUID(uuidString: "6C0F4B1E-0000-4000-8000-000000000005")!,
            name: "Ecosia",
            template: "https://www.ecosia.org/search?q=%s",
            isBuiltIn: true
        ),
        SearchEngine(
            id: UUID(uuidString: "6C0F4B1E-0000-4000-8000-000000000006")!,
            name: "Startpage",
            template: "https://www.startpage.com/sp/search?query=%s",
            isBuiltIn: true
        )
    ]
}

// MARK: - Website permissions

enum SitePermissionType: String, Codable, CaseIterable, Sendable {
    case camera
    case microphone
    case location
    case notifications

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .notifications: return "Notifications"
        }
    }
}

enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
}

struct SitePermission: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var host: String
    var type: SitePermissionType
    var decision: PermissionDecision
    var decidedAt: Date = Date()
}

// MARK: - Appearance

enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system
    case dark
    case light

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

/// Preferences that must be readable before any view exists.
struct AppPreferences: Codable, Sendable {
    var searchEngineID: UUID = SearchEngine.builtIns[0].id
    var homepage: String = ""
    var theme: AppTheme = .dark
    var blockAdsAndTrackers: Bool = true
    var desktopModeByDefault: Bool = false
    var customUserAgent: String = ""
    var openLinksInNewTab: Bool = false
}
