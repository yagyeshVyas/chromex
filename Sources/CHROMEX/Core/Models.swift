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
    /// 0...1 while a WebKit download is running. Not persisted: a relaunch cannot
    /// resume a transfer, so the value is only meaningful for the live session.
    var progress: Double = 0

    private enum CodingKeys: String, CodingKey {
        case id
        case filename
        case sourceURLString
        case state
        case byteCount
        case createdAt
        case localPath
        case errorMessage
    }

    init(filename: String, sourceURLString: String, state: State) {
        self.filename = filename
        self.sourceURLString = sourceURLString
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "download"
        sourceURLString = try container.decodeIfPresent(String.self, forKey: .sourceURLString) ?? ""
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .failed
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        progress = 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(sourceURLString, forKey: .sourceURLString)
        try container.encode(state, forKey: .state)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(localPath, forKey: .localPath)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
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
///
/// Decoded field by field so a state file written by an older build keeps every
/// preference instead of failing the whole `PersistedState` decode.
struct AppPreferences: Codable, Sendable {
    var searchEngineID: UUID = SearchEngine.builtIns[0].id
    var homepage: String = ""
    var theme: AppTheme = .system
    var blockAdsAndTrackers: Bool = true
    var desktopModeByDefault: Bool = false
    var customUserAgent: String = ""
    var openLinksInNewTab: Bool = false
    var showBookmarksBar: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case searchEngineID
        case homepage
        case theme
        case blockAdsAndTrackers
        case desktopModeByDefault
        case customUserAgent
        case openLinksInNewTab
        case showBookmarksBar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchEngineID = try container.decodeIfPresent(UUID.self, forKey: .searchEngineID)
            ?? SearchEngine.builtIns[0].id
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage) ?? ""
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        blockAdsAndTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockAdsAndTrackers) ?? true
        desktopModeByDefault = try container.decodeIfPresent(Bool.self, forKey: .desktopModeByDefault) ?? false
        customUserAgent = try container.decodeIfPresent(String.self, forKey: .customUserAgent) ?? ""
        openLinksInNewTab = try container.decodeIfPresent(Bool.self, forKey: .openLinksInNewTab) ?? false
        showBookmarksBar = try container.decodeIfPresent(Bool.self, forKey: .showBookmarksBar) ?? true
    }
}
