import SwiftUI
import UIKit
import WebKit

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

// MARK: - Sheets

enum ChromeSheet: Identifiable {
    case menu
    case hub
    case extensionPopup(InstalledExtension)

    var id: String {
        switch self {
        case .menu: return "menu"
        case .hub: return "hub"
        case .extensionPopup(let record): return "popup-\(record.id)"
        }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: ChromeSheet?
    @State private var omniboxFocused = false
    @State private var omniboxText = ""
    @State private var showFind = false
    @State private var findText = ""
    @State private var findStatus: String?

    private var bookmarksVisible: Bool {
        model.preferences.showBookmarksBar && !model.bookmarks.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            ChromeStyle.page.ignoresSafeArea()

            VStack(spacing: 0) {
                if let tab = model.currentTab {
                    ChromeTabStrip(
                        tabs: model.tabs,
                        selectedID: model.selectedTabID,
                        onSelect: { model.select($0) },
                        onClose: { model.closeTab($0) },
                        onNewTab: { model.openTab(url: nil, select: true) }
                    )

                    ChromeToolbarRow(
                        tab: tab,
                        omniboxText: $omniboxText,
                        omniboxFocused: $omniboxFocused,
                        onSubmit: submitFromOmnibox,
                        onOpenHub: { sheet = .hub },
                        onOpenMenu: { sheet = .menu },
                        onPopup: { record in sheet = .extensionPopup(record) }
                    )

                    if bookmarksVisible {
                        BookmarksBar(onOpen: { url in tab.load(url) })
                    }

                    if showFind {
                        FindBarView(
                            text: $findText,
                            status: findStatus,
                            onPrevious: { runFind(tab: tab, forward: false) },
                            onNext: { runFind(tab: tab, forward: true) },
                            onClose: closeFind
                        )
                    }

                    ChromePageArea(
                        tab: tab,
                        onFocusOmnibox: { omniboxFocused = true },
                        onOpenHub: { sheet = .hub }
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

            if omniboxFocused {
                OmniboxSuggestions(
                    query: omniboxText,
                    layerOffset: ChromeStyle.chromeHeight(bookmarksVisible: bookmarksVisible)
                        + (showFind ? ChromeStyle.findBarHeight : 0),
                    onSelect: { suggestion in
                        omniboxFocused = false
                        if let url = URL(string: suggestion.urlString) {
                            model.currentTab?.load(url)
                        }
                    }
                )
            }
        }
        .sheet(item: $sheet) { active in
            sheetContent(active)
        }

        .onAppear {
            omniboxText = model.currentTab.map { displayText(for: $0.urlString) } ?? ""
        }
        .onChange(of: model.selectedTabID) { _, _ in
            omniboxFocused = false
            omniboxText = model.currentTab.map { displayText(for: $0.urlString) } ?? ""
        }
        .onChange(of: model.currentTab?.urlString ?? "") { _, _ in
            guard !omniboxFocused, let current = model.currentTab else { return }
            omniboxText = displayText(for: current.urlString)
        }
        .onChange(of: omniboxFocused) { _, focused in
            guard !focused, let current = model.currentTab else { return }
            omniboxText = displayText(for: current.urlString)
        }

    }

    // MARK: Sheet content

    @ViewBuilder
    private func sheetContent(_ active: ChromeSheet) -> some View {
        switch active {
        case .menu:
            NavigationStack {
                if let tab = model.currentTab {
                    ChromeMenuView(
                        tab: tab,
                        onNewTab: { model.openTab(url: nil, select: true) },
                        onNewPrivateTab: { model.openTab(url: nil, select: true, private: true) },
                        onStartFind: {
                            showFind = true
                            findStatus = nil
                        },
                        onPrint: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                tab.printable()
                            }
                        },
                        onShare: {
                            guard let url = URL(string: tab.urlString) else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                ShareSheet.present(url: url)
                            }
                        },
                        onToggleDesktop: { tab.setDesktopMode(!tab.isDesktopMode) },
                        onClearData: { model.clearBrowsingData() },
                        onCloseTab: { model.closeCurrentTab() },
                        canCloseTab: model.tabs.count > 1
                    )
                } else {
                    EmptyStateView(
                        symbol: "globe",
                        title: "No tab",
                        message: "Open a tab first."
                    )
                }
            }
        case .hub:
            NavigationStack { HubView() }
        case .extensionPopup(let record):
            ExtensionPopupView(record: record)
        }
    }

    // MARK: Omnibox helpers

    private func submitFromOmnibox() {
        let trimmed = omniboxText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        omniboxFocused = false
        model.submit(trimmed)
    }

    private func displayText(for urlString: String) -> String {
        URLResolver.displayString(for: URL(string: urlString))
    }


    // MARK: Find

    private func runFind(tab: BrowserTab, forward: Bool) {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            findStatus = nil
            return
        }
        Task {
            let found = await tab.find(needle, forward: forward)
            findStatus = found ? nil : "No results"
        }
    }

    private func closeFind() {
        showFind = false
        findText = ""
        findStatus = nil
    }
}

// MARK: - Tab strip

struct ChromeTabStrip: View {
    let tabs: [BrowserTab]
    let selectedID: UUID?
    var onSelect: (BrowserTab) -> Void
    var onClose: (BrowserTab) -> Void
    var onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(tabs) { tab in
                            ChromeTabChip(
                                tab: tab,
                                isSelected: tab.id == selectedID,
                                onSelect: { onSelect(tab) },
                                onClose: { onClose(tab) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onAppear {
                    if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                }
                .onChange(of: selectedID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChromeStyle.text)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tab")
            .padding(.trailing, 4)
        }
        .frame(height: ChromeStyle.tabStripHeight)
        .background(ChromeStyle.tabStrip)
    }

}

// MARK: - Omnibox

struct OmniboxField: View {
    @Binding var text: String
    /// Full URL shown (and selected) while editing, the way Chrome does it.
    let fullURL: String
    let placeholder: String
    let isSecure: Bool
    let isPrivate: Bool
    @Binding var isFocused: Bool
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isPrivate ? "hand.raised.fill" : (isSecure ? "lock.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPrivate ? ChromeStyle.incognito : (isSecure ? ChromeStyle.textSecondary : ChromeStyle.danger))

            ChromeAddressField(
                text: $text,
                isFocused: $isFocused,
                focusText: fullURL,
                placeholder: placeholder,
                onSubmit: onSubmit
            )

            if isFocused, !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ChromeStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear address")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(isFocused ? ChromeStyle.omniboxFocused : ChromeStyle.omnibox)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(isFocused ? ChromeStyle.accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture { isFocused = true }
    }
}

/// UIKit text field behind the omnibox.
///
/// SwiftUI's `TextField` cannot select its contents when focus arrives, so typing
/// after a tap appended to the old address instead of replacing it. Chrome selects
/// the whole address on focus; a `UITextField` is the only way to match that.
struct ChromeAddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusText: String
    let placeholder: String
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 15)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.textContentType = .URL
        field.textColor = UIColor(ChromeStyle.text)
        field.tintColor = UIColor(ChromeStyle.accent)
        field.placeholder = placeholder
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "Done", style: .done, target: context.coordinator, action: #selector(Coordinator.dismissKeyboard))
        ]
        field.inputAccessoryView = toolbar
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        if field.text != text {
            field.text = text
        }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChromeAddressField

        init(_ parent: ChromeAddressField) {
            self.parent = parent
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            let address = parent.focusText
            textField.text = address
            parent.text = address
            parent.isFocused = true
            textField.selectAll(nil)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            parent.onSubmit()
            return true
        }

        @objc func edited(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        @objc func dismissKeyboard() {
            parent.isFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

struct OmniboxSuggestion: Identifiable {
    enum Kind {
        case history
        case bookmark
        case search
    }

    var id: String
    var title: String
    var subtitle: String
    var urlString: String
    var kind: Kind
}

struct OmniboxSuggestions: View {
    @EnvironmentObject private var model: AppModel
    let query: String
    let layerOffset: CGFloat
    var onSelect: (OmniboxSuggestion) -> Void

    private var suggestions: [OmniboxSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [OmniboxSuggestion] = []
        var seen = Set<String>()

        if !trimmed.isEmpty {
            for entry in model.history(matching: trimmed).prefix(5) where seen.insert(entry.urlString).inserted {
                rows.append(OmniboxSuggestion(
                    id: "h-\(entry.id)",
                    title: entry.title.isEmpty ? entry.host : entry.title,
                    subtitle: entry.host,
                    urlString: entry.urlString,
                    kind: .history
                ))
            }
            for bookmark in model.bookmarks where bookmark.title.lowercased().contains(trimmed.lowercased())
                && seen.insert(bookmark.urlString).inserted {
                rows.append(OmniboxSuggestion(
                    id: "b-\(bookmark.id)",
                    title: bookmark.title,
                    subtitle: URL(string: bookmark.urlString)?.host ?? "",
                    urlString: bookmark.urlString,
                    kind: .bookmark
                ))
            }
            rows.append(OmniboxSuggestion(
                id: "search",
                title: "\(model.currentSearchEngine.name): “\(trimmed)”",
                subtitle: "Search the web",
                urlString: model.currentSearchEngine.url(for: trimmed)?.absoluteString ?? "",
                kind: .search
            ))
        } else {
            for entry in model.topSites.prefix(6) {
                rows.append(OmniboxSuggestion(
                    id: "t-\(entry.id)",
                    title: entry.title.isEmpty ? entry.host : entry.title,
                    subtitle: entry.host,
                    urlString: entry.urlString,
                    kind: .history
                ))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: suggestion.kind))
                                    .font(.system(size: 14))
                                    .foregroundStyle(ChromeStyle.textSecondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(ChromeStyle.text)
                                        .lineLimit(1)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(ChromeStyle.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        ChromeDivider()
                    }
                }
            }
            .frame(maxHeight: 320)
            Spacer(minLength: 0)
        }
        .background(ChromeStyle.toolbar)
        .padding(.top, layerOffset)
        .ignoresSafeArea(edges: .bottom)
        .onTapGesture {}
    }

    private func icon(for kind: OmniboxSuggestion.Kind) -> String {
        switch kind {
        case .history: return "clock"
        case .bookmark: return "star"
        case .search: return "magnifyingglass"
        }
    }
}

// MARK: - Bookmarks bar

struct BookmarksBar: View {
    @EnvironmentObject private var model: AppModel
    var onOpen: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.bookmarks.prefix(16)) { bookmark in
                    Button {
                        if let url = URL(string: bookmark.urlString) {
                            onOpen(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            SiteLetterMark(text: markText(bookmark), size: 16, tint: ChromeStyle.textSecondary)
                            Text(bookmark.title.isEmpty ? (URL(string: bookmark.urlString)?.host ?? "Bookmark") : bookmark.title)
                                .font(.system(size: 12))
                                .foregroundStyle(ChromeStyle.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: ChromeStyle.bookmarksHeight - 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: ChromeStyle.bookmarksHeight)
        .background(ChromeStyle.toolbarRaised)
        .overlay(alignment: .bottom) { ChromeDivider() }
    }

    private func markText(_ bookmark: Bookmark) -> String {
        if let host = URL(string: bookmark.urlString)?.host, !host.isEmpty { return host }
        return bookmark.title.isEmpty ? "?" : bookmark.title
    }
}

// MARK: - Find bar

struct FindBarView: View {
    @Binding var text: String
    let status: String?
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(ChromeStyle.textSecondary)

            TextField("Find in page", text: $text)
                .font(.system(size: 14))
                .foregroundStyle(ChromeStyle.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(onNext)

            if let status {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(ChromeStyle.textSecondary)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ChromeStyle.text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous match")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ChromeStyle.text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next match")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ChromeStyle.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, 14)
        .frame(height: ChromeStyle.findBarHeight)
        .background(ChromeStyle.toolbarRaised)
        .overlay(alignment: .bottom) { ChromeDivider() }
        .onAppear { focused = true }
    }
}

// MARK: - Error page

struct ErrorPageView: View {
    let error: BrowserTab.PageError
    var onReload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(ChromeStyle.textSecondary)
            Text(error.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ChromeStyle.text)
            Text(error.message)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(ChromeStyle.textSecondary)
                .frame(maxWidth: 320)
            Text(error.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChromeStyle.textTertiary)
            Button(action: onReload) {
                Text("Reload")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(ChromeStyle.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChromeStyle.page)
    }
}

// MARK: - New tab page

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var onFocusOmnibox: () -> Void
    var onOpenURL: (URL) -> Void
    var onOpenHub: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                searchPill
                if !model.topSites.isEmpty {
                    shortcuts
                } else {
                    firstRun
                }
                hubRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 40)
        }
        .background(ChromeStyle.page)
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(spacing: 8) {
            DiamondMark(size: 30)
            Text("CHROMEX")
                .font(.system(size: 22, weight: .bold))
                .tracking(6)
                .foregroundStyle(ChromeStyle.text)
            Text("WebKit engine · Chrome-style browsing")
                .font(.system(size: 12))
                .foregroundStyle(ChromeStyle.textTertiary)
        }
    }

    private var searchPill: some View {
        Button(action: onFocusOmnibox) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(ChromeStyle.textSecondary)
                Text("Search \(model.currentSearchEngine.name) or type a URL")
                    .font(.system(size: 15))
                    .foregroundStyle(ChromeStyle.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(ChromeStyle.omnibox, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shortcuts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChromeStyle.text)
                Spacer()
                Text("Most visited")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.topSites) { site in
                    Button {
                        if let url = URL(string: site.urlString) {
                            onOpenURL(url)
                        }
                    } label: {
                        VStack(spacing: 7) {
                            SiteLetterMark(text: site.host, size: 46)
                            Text(shortLabel(site))
                                .font(.system(size: 11))
                                .foregroundStyle(ChromeStyle.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var firstRun: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(ChromeStyle.textTertiary)
            Text("Your most visited sites will appear here")
                .font(.system(size: 13))
                .foregroundStyle(ChromeStyle.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var hubRow: some View {
        Button(action: onOpenHub) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 16))
                    .foregroundStyle(ChromexColor.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chromex Hub")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChromeStyle.text)
                    Text("\(model.extensions.installed.count) extension(s) installed")
                        .font(.system(size: 11))
                        .foregroundStyle(ChromeStyle.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
            .padding(14)
            .background(ChromeStyle.toolbarRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ChromeStyle.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func shortLabel(_ site: HistoryEntry) -> String {
        let host = site.host
        if host.hasPrefix("www.") { return String(host.dropFirst(4)) }
        return host
    }
}

// MARK: - Web view host

final class WebHostView: UIView {
    var hosted: WKWebView? {
        didSet {
            guard oldValue !== hosted else { return }
            oldValue?.removeFromSuperview()
            guard let hosted else { return }
            hosted.frame = bounds
            hosted.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(hosted)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WebHostView {
        let host = WebHostView()
        host.backgroundColor = .clear
        host.hosted = webView
        return host
    }

    func updateUIView(_ uiView: WebHostView, context: Context) {
        if uiView.hosted !== webView {
            uiView.hosted = webView
        }
    }
}

// MARK: - Shared pieces used by other screens

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

/// Presents the system share sheet without routing through a SwiftUI `.sheet`,
/// which is unreliable while another sheet is still dismissing.
@MainActor
enum ShareSheet {
    static func present(url: URL) {
        guard let root = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(
                x: root.view.bounds.midX,
                y: root.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        root.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
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
}

struct DiamondMark: View {
    var size: CGFloat = 20

    var body: some View {
        DiamondShape()
            .stroke(ChromexColor.accentGradient, lineWidth: max(1.6, size * 0.12))
            .frame(width: size, height: size)
    }
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


// MARK: - Toolbar row

/// Owns the page-bound chrome. It observes `BrowserTab` directly so the address
/// bar, progress and navigation buttons update live while a page loads.
struct ChromeToolbarRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    @Binding var omniboxText: String
    @Binding var omniboxFocused: Bool
    var onSubmit: () -> Void
    var onOpenHub: () -> Void
    var onOpenMenu: () -> Void
    var onPopup: (InstalledExtension) -> Void

    private var pinned: [InstalledExtension] {
        Array(model.extensions.installed.filter { record in
            record.isEnabled && record.manifest?.action != nil
        }.prefix(3))
    }

    var body: some View {
        HStack(spacing: 2) {
            ChromeIconButton(symbol: "chevron.left", enabled: tab.canGoBack) { tab.goBack() }
            ChromeIconButton(symbol: "chevron.right", enabled: tab.canGoForward) { tab.goForward() }
            ChromeIconButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise") {
                tab.isLoading ? tab.stopLoading() : tab.reload()
            }

            OmniboxField(
                text: $omniboxText,
                fullURL: tab.urlString,
                placeholder: "Search \(model.currentSearchEngine.name) or type a URL",
                isSecure: tab.isSecure,
                isPrivate: tab.isPrivate,
                isFocused: $omniboxFocused,
                onSubmit: onSubmit
            )

            ChromeIconButton(
                symbol: model.isBookmarked(urlString: tab.urlString) ? "star.fill" : "star",
                enabled: !tab.urlString.isEmpty,
                tint: model.isBookmarked(urlString: tab.urlString) ? ChromeStyle.accent : ChromeStyle.text
            ) {
                model.toggleBookmark(title: tab.snapshotTitle(), urlString: tab.urlString)
            }

            ForEach(pinned) { record in
                Button {
                    if record.manifest?.action?.defaultPopup != nil {
                        onPopup(record)
                    } else {
                        model.extensions.dispatchActionClick(for: record)
                    }
                } label: {
                    Image(systemName: record.manifest?.action?.defaultPopup != nil
                          ? "puzzlepiece.extension.fill"
                          : "bolt.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(ChromexColor.violet)
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(record.displayName)
            }

            ChromeIconButton(symbol: "puzzlepiece.extension") { onOpenHub() }
            ChromeIconButton(symbol: "ellipsis") { onOpenMenu() }
        }
        .padding(.horizontal, 6)
        .frame(height: ChromeStyle.toolbarHeight)
        .background(ChromeStyle.toolbar)
        .overlay(alignment: .bottom) { ChromeDivider() }
    }
}

// MARK: - Page area

struct ChromePageArea: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    var onFocusOmnibox: () -> Void
    var onOpenHub: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            WebViewContainer(webView: tab.webView)
                .background(ChromeStyle.page)

            if tab.urlString.isEmpty, tab.pageError == nil {
                HomeView(
                    onFocusOmnibox: onFocusOmnibox,
                    onOpenURL: { url in tab.load(url) },
                    onOpenHub: onOpenHub
                )
            }

            if let error = tab.pageError {
                ErrorPageView(error: error, onReload: { tab.reload() })
            }

            if tab.isLoading, tab.estimatedProgress < 1 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(ChromeStyle.accent)
                        .frame(width: proxy.size.width * max(0.02, tab.estimatedProgress), height: 2)
                }
                .frame(height: 2)
            }
        }
        .clipped()
    }
}

// MARK: - Tab chip

struct ChromeTabChip: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isPrivate {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ChromeStyle.incognito)
            } else if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(tab.snapshotTitle())
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? ChromeStyle.text : ChromeStyle.tabTextInactive)
                .lineLimit(1)
            if isSelected {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ChromeStyle.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 158, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? ChromeStyle.tabActive : ChromeStyle.tabInactive)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
