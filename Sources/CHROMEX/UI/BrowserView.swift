import SwiftUI
import WebKit

// MARK: - Routes

enum BrowserRoute: String, Identifiable {
    case hub
    case settings
    case bookmarks
    case history
    case downloads
    case privacy

    var id: String { rawValue }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        BrowserView()
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    model.saveNow()
                }
            }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var route: BrowserRoute?
    @State private var showingMenu = false
    @State private var shareItem: ShareItem?

    var body: some View {
        ZStack {
            BrowserBackground()

            VStack(spacing: 0) {
                if let tab = model.currentTab {
                    content(for: tab)
                    OmniboxBar(tab: tab) { route = .hub }
                    BrowserToolbar(
                        tab: tab,
                        tabCount: model.tabs.count,
                        onBack: { tab.goBack() },
                        onForward: { tab.goForward() },
                        onTabs: { model.showingTabSwitcher = true },
                        onExtensions: { route = .hub },
                        onMenu: { showingMenu = true }
                    )
                } else {
                    EmptyStateView(
                        symbol: "globe",
                        title: "No tabs",
                        message: "Open a tab to start browsing.",
                        actionTitle: "New tab",
                        action: { model.openTab(url: nil, select: true) }
                    )
                }
            }
        }
        .sheet(item: $route) { route in
            switch route {
            case .hub:
                NavigationStack { HubView() }
            case .settings:
                NavigationStack { SettingsView() }
            case .bookmarks:
                NavigationStack { BookmarksView() }
            case .history:
                NavigationStack { HistoryView() }
            case .downloads:
                NavigationStack { DownloadsView() }
            case .privacy:
                NavigationStack { PrivacyDashboardView() }
            }
        }
        .sheet(isPresented: $model.showingTabSwitcher) {
            TabSwitcherView()
        }
        .sheet(item: $model.popupExtension) { record in
            ExtensionPopupView(record: record)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("CHROMEX", isPresented: $showingMenu, titleVisibility: .hidden) {
            Button("New Tab") { model.openTab(url: nil, select: true) }
            Button("New Private Tab") { model.openTab(url: nil, select: true, private: true) }
            if let tab = model.currentTab, !tab.urlString.isEmpty {
                Button(model.isBookmarked(urlString: tab.urlString) ? "Remove Bookmark" : "Add Bookmark") {
                    model.toggleBookmark(title: tab.snapshotTitle(), urlString: tab.urlString)
                }
                Button(tab.isDesktopMode ? "Request Mobile Site" : "Request Desktop Site") {
                    tab.setDesktopMode(!tab.isDesktopMode)
                }
                Button("Share Page") {
                    if let url = URL(string: tab.urlString) {
                        shareItem = ShareItem(url: url)
                    }
                }
            }
            Button("Bookmarks") { route = .bookmarks }
            Button("History") { route = .history }
            Button("Downloads") { route = .downloads }
            Button("Privacy Dashboard") { route = .privacy }
            Button("Settings") { route = .settings }
            if model.tabs.count > 1 {
                Button("Close Tab", role: .destructive) { model.closeCurrentTab() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func content(for tab: BrowserTab) -> some View {
        ZStack(alignment: .top) {
            WebViewContainer(webView: tab.webView)
                .background(ChromexColor.background)

            if tab.urlString.isEmpty {
                HomeView(onOpenHub: { route = .hub }, onOpenURL: { url in tab.load(url) })
                    .transition(.opacity)
            }

            if tab.isLoading, tab.estimatedProgress < 1 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(ChromexColor.accentGradient)
                        .frame(width: proxy.size.width * max(0.02, tab.estimatedProgress), height: 2)
                }
                .frame(height: 2)
                .transition(.opacity)
            }

            if let error = tab.errorMessage {
                Text(error)
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromexColor.danger)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChromexColor.surface.opacity(0.96))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: tab.urlString.isEmpty)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Omnibox

struct OmniboxBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    var onExtensions: () -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onExtensions()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ChromexColor.violet)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Extensions")

            HStack(spacing: 6) {
                Image(systemName: tab.isSecure ? "lock.fill" : "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tab.isSecure ? ChromexColor.textSecondary : ChromexColor.textTertiary)

                TextField("Search or enter address", text: $text)
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromexColor.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit {
                        model.submit(text)
                        focused = false
                    }

                if !text.isEmpty {
                    Button {
                        text = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ChromexColor.textTertiary)
                    }
                    .accessibilityLabel("Clear address")
                }

                if tab.isLoading {
                    Button { tab.stopLoading() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(ChromexColor.textSecondary)
                    }
                    .accessibilityLabel("Stop loading")
                } else if !tab.urlString.isEmpty {
                    Button { tab.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ChromexColor.textSecondary)
                    }
                    .accessibilityLabel("Reload")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(ChromexColor.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(ChromexColor.hairline, lineWidth: 0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { text = displayText }
        .onChange(of: tab.urlString) { _, _ in
            if !focused { text = displayText }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { text = displayText }
        }
    }

    private var displayText: String {
        tab.urlString.isEmpty ? "" : URLResolver.displayString(for: URL(string: tab.urlString))
    }
}

// MARK: - Toolbar

struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    let tabCount: Int
    var onBack: () -> Void
    var onForward: () -> Void
    var onTabs: () -> Void
    var onExtensions: () -> Void
    var onMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            toolbarButton("chevron.left", label: "Back", enabled: tab.canGoBack, action: onBack)
            toolbarButton("chevron.right", label: "Forward", enabled: tab.canGoForward, action: onForward)

            Button(action: onTabs) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ChromexColor.textPrimary, lineWidth: 1.6)
                        .frame(width: 22, height: 22)
                    Text("\(min(tabCount, 99))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ChromexColor.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .accessibilityLabel("Tabs")

            toolbarButton("square.grid.2x2", label: "Extensions", enabled: true, action: onExtensions, tint: ChromexColor.violet)

            Button(action: onMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChromexColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .accessibilityLabel("Menu")
        }
        .padding(.horizontal, 8)
        .background(ChromexColor.surface.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle().fill(ChromexColor.hairline).frame(height: 0.5)
        }
    }

    private func toolbarButton(
        _ symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void,
        tint: Color = ChromexColor.textPrimary
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? tint : ChromexColor.textTertiary.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var onOpenHub: () -> Void
    var onOpenURL: (URL) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                searchField
                if !model.bookmarks.isEmpty { favourites }
                if !model.history.isEmpty { recent }
                privacyLine
                extensionsPrompt
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DiamondMark(size: 22)
                Text("CHROMEX")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(ChromexColor.textPrimary)
            }
            Text("Your Browser. Your Extensions. Your Rules.")
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromexColor.textSecondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ChromexColor.textTertiary)
            TextField("Search \(model.currentSearchEngine.name) or enter address", text: $query)
                .font(ChromexFont.body)
                .foregroundStyle(ChromexColor.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit { submit() }
            if !query.isEmpty {
                Button { submit() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(ChromexColor.electricBlue)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(ChromexColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(ChromexColor.hairline, lineWidth: 0.5))
    }

    private var favourites: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Favourites", trailing: "\(model.bookmarks.count)")
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.bookmarks.prefix(8)) { bookmark in
                    Button {
                        if let url = URL(string: bookmark.urlString) { onOpenURL(url) }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(ChromexColor.surfaceRaised)
                                Text(initial(for: bookmark))
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(ChromexColor.textPrimary)
                            }
                            .frame(height: 56)
                            Text(bookmark.title)
                                .font(ChromexFont.caption)
                                .foregroundStyle(ChromexColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently visited")
            VStack(spacing: 0) {
                ForEach(model.history.prefix(3)) { entry in
                    Button {
                        if let url = URL(string: entry.urlString) { onOpenURL(url) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .font(.system(size: 13))
                                .foregroundStyle(ChromexColor.textTertiary)
                                .frame(width: 20)
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
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if entry.id != model.history.prefix(3).last?.id {
                        Divider().overlay(ChromexColor.hairline)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(ChromexColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var privacyLine: some View {
        HStack(spacing: 10) {
            Image(systemName: model.preferences.blockAdsAndTrackers ? "shield.lefthalf.filled" : "shield.slash")
                .foregroundStyle(model.preferences.blockAdsAndTrackers ? ChromexColor.electricBlueBright : ChromexColor.textTertiary)
            Text(privacyText)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromexColor.textSecondary)
            Spacer()
        }
        .padding(14)
        .background(ChromexColor.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var privacyText: String {
        guard model.preferences.blockAdsAndTrackers else { return "Content blocking is off." }
        if model.adBlocker.ruleCount == 0 { return "Preparing content blocking…" }
        return "\(model.adBlocker.ruleCount) blocking rules active."
    }

    private var extensionsPrompt: some View {
        Button(action: onOpenHub) {
            HStack(spacing: 12) {
                DiamondMark(size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chromex Hub")
                        .font(ChromexFont.headline)
                        .foregroundStyle(ChromexColor.textPrimary)
                    Text("Import and manage extensions")
                        .font(ChromexFont.caption)
                        .foregroundStyle(ChromexColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChromexColor.textTertiary)
            }
            .padding(16)
            .background(ChromexColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(ChromexColor.violet.opacity(0.25), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        focused = false
        if let url = URLResolver.destination(for: trimmed, engine: model.currentSearchEngine) {
            onOpenURL(url)
            query = ""
        }
    }

    private func initial(for bookmark: Bookmark) -> String {
        let source = bookmark.title.isEmpty ? (URL(string: bookmark.urlString)?.host ?? "?") : bookmark.title
        return String(source.prefix(1)).uppercased()
    }
}

struct DiamondMark: View {
    var size: CGFloat = 20

    var body: some View {
        DiamondShape()
            .stroke(ChromexColor.accentGradient, lineWidth: max(1.6, size * 0.12))
            .frame(width: size, height: size)
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
