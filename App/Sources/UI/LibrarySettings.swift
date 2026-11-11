import SwiftUI

// MARK: - Bookmarks

struct BookmarksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            BrowserBackground()
            if model.bookmarks.isEmpty {
                EmptyStateView(
                    symbol: "bookmark",
                    title: "No bookmarks",
                    message: "Add a bookmark from the page menu while browsing."
                )
            } else {
                List {
                    ForEach(model.bookmarks) { bookmark in
                        Button {
                            if let url = URL(string: bookmark.urlString) {
                                model.openTab(url: url, select: true)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ChromexColor.electricBlue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(ChromexFont.callout)
                                        .foregroundStyle(ChromexColor.textPrimary)
                                        .lineLimit(1)
                                    Text(bookmark.urlString)
                                        .font(ChromexFont.caption)
                                        .foregroundStyle(ChromexColor.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                model.removeBookmark(bookmark)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return model.history }
        let needle = query.lowercased()
        return model.history.filter {
            $0.title.lowercased().contains(needle) || $0.urlString.lowercased().contains(needle)
        }
    }

    var body: some View {
        ZStack {
            BrowserBackground()
            if model.history.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "No history",
                    message: "Pages you visit appear here. Private browsing is never recorded."
                )
            } else {
                List {
                    ForEach(filtered) { entry in
                        Button {
                            if let url = URL(string: entry.urlString) {
                                model.openTab(url: url, select: true)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(entry.visitedAt, format: .dateTime.hour().minute())
                                    .font(ChromexFont.caption)
                                    .foregroundStyle(ChromexColor.textTertiary)
                                    .frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(ChromexFont.callout)
                                        .foregroundStyle(ChromexColor.textPrimary)
                                        .lineLimit(1)
                                    Text(entry.host)
                                        .font(ChromexFont.caption)
                                        .foregroundStyle(ChromexColor.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.deleteHistory(entry) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear", role: .destructive) { model.clearHistory() }
                    .disabled(model.history.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?

    var body: some View {
        ZStack {
            BrowserBackground()
            if model.downloads.isEmpty {
                EmptyStateView(
                    symbol: "arrow.down.circle",
                    title: "No downloads",
                    message: "Files you download are saved in CHROMEX/Documents/Downloads and reachable from the Files app."
                )
            } else {
                List {
                    ForEach(model.downloads) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .font(.system(size: 16))
                                .foregroundStyle(item.state == .failed ? ChromexColor.danger : ChromexColor.textSecondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.filename)
                                    .font(ChromexFont.callout)
                                    .foregroundStyle(ChromexColor.textPrimary)
                                    .lineLimit(1)
                                Text(subtitle(for: item))
                                    .font(ChromexFont.caption)
                                    .foregroundStyle(item.state == .failed ? ChromexColor.danger : ChromexColor.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if item.state == .completed, let path = item.localPath {
                                Button {
                                    shareItem = ShareItem(url: URL(fileURLWithPath: path))
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundStyle(ChromexColor.electricBlue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { model.removeDownload(item) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
                .presentationDetents([.medium])
        }
    }

    private func icon(for item: DownloadItem) -> String {
        switch item.state {
        case .inProgress: return "arrow.down.circle"
        case .completed: return "doc.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func subtitle(for item: DownloadItem) -> String {
        switch item.state {
        case .inProgress:
            return "Downloading…"
        case .completed:
            return ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
        case .failed:
            return item.errorMessage ?? "Download failed"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingNewEngine = false
    @State private var engineName = ""
    @State private var engineTemplate = ""

    var body: some View {
        ZStack {
            BrowserBackground()
            Form {
                Section {
                    Picker("Search engine", selection: Binding(
                        get: { model.preferences.searchEngineID },
                        set: { model.preferences.searchEngineID = $0 }
                    )) {
                        ForEach(model.allSearchEngines) { engine in
                            Text(engine.name).tag(engine.id)
                        }
                    }
                    HStack {
                        Text("Homepage")
                        Spacer()
                        TextField("Start page", text: Binding(
                            get: { model.preferences.homepage },
                            set: { model.preferences.homepage = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    }
                } header: {
                    Text("Browsing")
                }

                Section {
                    Picker("Appearance", selection: Binding(
                        get: { model.preferences.theme },
                        set: { model.preferences.theme = $0 }
                    )) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    Toggle("Desktop site by default", isOn: Binding(
                        get: { model.preferences.desktopModeByDefault },
                        set: { model.preferences.desktopModeByDefault = $0 }
                    ))
                    .tint(ChromexColor.electricBlue)
                } header: {
                    Text("Display")
                }

                Section {
                    Toggle("Block ads and trackers", isOn: Binding(
                        get: { model.preferences.blockAdsAndTrackers },
                        set: { model.preferences.blockAdsAndTrackers = $0 }
                    ))
                    .tint(ChromexColor.electricBlue)
                    NavigationLink("Privacy dashboard") { PrivacyDashboardView() }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Blocking is declarative. WebKit does not expose per-request interception to browsers, so CHROMEX ships a compiled rule list instead of pretending to filter traffic.")
                }

                Section {
                    ForEach(model.customEngines) { engine in
                        HStack {
                            Text(engine.name)
                            Spacer()
                            Text(engine.template)
                                .font(ChromexFont.caption)
                                .foregroundStyle(ChromexColor.textTertiary)
                                .lineLimit(1)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.removeSearchEngine(engine) }
                        }
                    }
                    Button("Add search engine") {
                        engineName = ""
                        engineTemplate = ""
                        showingNewEngine = true
                    }
                } header: {
                    Text("Custom search engines")
                } footer: {
                    Text("Use %s where the query goes, for example https://example.com/search?q=%s")
                }

                Section {
                    Button("Clear history", role: .destructive) { model.clearHistory() }
                    Button("Clear downloads list", role: .destructive) {
                        for item in model.downloads { model.removeDownload(item) }
                    }
                } header: {
                    Text("Data")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(ChromexColor.textTertiary)
                    }
                    HStack {
                        Text("Engine")
                        Spacer()
                        Text("WebKit / WKWebView")
                            .foregroundStyle(ChromexColor.textTertiary)
                    }
                    HStack {
                        Text("Extensions")
                        Spacer()
                        Text("\(model.extensions.installed.count) installed")
                            .foregroundStyle(ChromexColor.textTertiary)
                    }
                } header: {
                    Text("About CHROMEX")
                } footer: {
                    Text("Your Browser. Your Extensions. Your Rules.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .alert("New search engine", isPresented: $showingNewEngine) {
            TextField("Name", text: $engineName)
            TextField("https://example.com/search?q=%s", text: $engineTemplate)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let name = engineName.trimmingCharacters(in: .whitespaces)
                let template = engineTemplate.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, template.contains("%s") {
                    model.addSearchEngine(name: name, template: template)
                }
            }
        }
    }
}

// MARK: - Privacy dashboard

struct PrivacyDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            BrowserBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    protectionCard
                    permissionCard
                    extensionCard
                    limitsCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.preferences.blockAdsAndTrackers ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(model.preferences.blockAdsAndTrackers ? ChromexColor.electricBlueBright : ChromexColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.preferences.blockAdsAndTrackers ? "Protection on" : "Protection off")
                        .font(ChromexFont.headline)
                        .foregroundStyle(ChromexColor.textPrimary)
                    Text(ruleSummary)
                        .font(ChromexFont.caption)
                        .foregroundStyle(ChromexColor.textSecondary)
                }
                Spacer()
            }
            if let error = model.adBlocker.lastError {
                Text(error)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.danger)
            }
            Toggle("Block ads and trackers", isOn: Binding(
                get: { model.preferences.blockAdsAndTrackers },
                set: { model.preferences.blockAdsAndTrackers = $0 }
            ))
            .tint(ChromexColor.electricBlue)
        }
        .cardStyle()
    }

    private var ruleSummary: String {
        if !model.preferences.blockAdsAndTrackers { return "No rules are attached to new tabs." }
        if model.adBlocker.ruleCount == 0 { return "Compiling rules…" }
        return "\(model.adBlocker.ruleCount) rules compiled into a WebKit content-blocking list."
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Site permissions")
            if model.permissions.isEmpty {
                Text("No site has been granted or denied a permission yet.")
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromexColor.textSecondary)
            } else {
                ForEach(model.permissions.sorted { $0.decidedAt > $1.decidedAt }.prefix(12)) { permission in
                    HStack(spacing: 8) {
                        Text(permission.host)
                            .font(ChromexFont.callout)
                            .foregroundStyle(ChromexColor.textPrimary)
                            .lineLimit(1)
                        Text(permission.type.displayName)
                            .font(ChromexFont.caption)
                            .foregroundStyle(ChromexColor.textTertiary)
                        Spacer()
                        Text(permission.decision.rawValue.capitalized)
                            .font(ChromexFont.caption)
                            .foregroundStyle(permission.decision == .allow ? ChromexColor.success : ChromexColor.danger)
                    }
                }
            }
        }
        .cardStyle()
    }

    private var extensionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Extension access", trailing: "\(model.extensions.installed.count)")
            if model.extensions.installed.isEmpty {
                Text("No extensions installed.")
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromexColor.textSecondary)
            } else {
                ForEach(model.extensions.installed) { record in
                    HStack(spacing: 8) {
                        DiamondMark(size: 12)
                        Text(record.displayName)
                            .font(ChromexFont.callout)
                            .foregroundStyle(ChromexColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(accessSummary(record))
                            .font(ChromexFont.caption)
                            .foregroundStyle(ChromexColor.textTertiary)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func accessSummary(_ record: InstalledExtension) -> String {
        if record.grants.contains("<all_urls>") { return "All sites" }
        if record.grants.isEmpty { return "No host access" }
        return "\(record.grants.count) pattern\(record.grants.count == 1 ? "" : "s")"
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "What this page cannot tell you")
            Text("WebKit gives a browser no per-request hook, so CHROMEX cannot count individual blocked requests. This dashboard reports what it can verify — compiled rules, permission decisions, and which extensions hold host access — instead of inventing numbers.")
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromexColor.textSecondary)
        }
        .cardStyle()
    }
}
