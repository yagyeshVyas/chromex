import SwiftUI

/// Chrome's three-dot menu as a sheet. Pages (bookmarks, history, downloads,
/// Hub, settings, privacy) push onto the same stack; actions run after the sheet
/// dismisses.
struct ChromeMenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tab: BrowserTab

    var onNewTab: () -> Void
    var onNewPrivateTab: () -> Void
    var onStartFind: () -> Void
    var onPrint: () -> Void
    var onShare: () -> Void
    var onToggleDesktop: () -> Void
    var onClearData: () -> Void
    var onCloseTab: () -> Void
    var canCloseTab: Bool

    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                section {
                    row("plus.square", "New tab") {
                        dismiss()
                        onNewTab()
                    }
                    row("hand.raised", "New private tab") {
                        dismiss()
                        onNewPrivateTab()
                    }
                }

                divider

                section {
                    link("star", "Bookmarks", BookmarksView())
                    link("clock.arrow.circlepath", "History", HistoryView())
                    link("arrow.down.circle", "Downloads", DownloadsView())
                    link("puzzlepiece.extension", "Extensions", HubView())
                }

                divider

                section {
                    row("magnifyingglass", "Find in page") {
                        dismiss()
                        onStartFind()
                    }
                    zoomRow
                    row("printer", "Print") {
                        dismiss()
                        onPrint()
                    }
                    row("square.and.arrow.up", "Share") {
                        dismiss()
                        onShare()
                    }
                    row(tab.isDesktopMode ? "iphone" : "desktopcomputer",
                        tab.isDesktopMode ? "Request mobile site" : "Request desktop site") {
                        onToggleDesktop()
                    }
                }

                divider

                section {
                    link("gearshape", "Settings", SettingsView())
                    link("shield.lefthalf.filled", "Privacy dashboard", PrivacyDashboardView())
                    row("trash", "Clear browsing data", destructive: true) {
                        confirmingClear = true
                    }
                }

                if canCloseTab {
                    divider
                    section {
                        row("xmark", "Close tab", destructive: true) {
                            dismiss()
                            onCloseTab()
                        }
                    }
                }

                Text("CHROMEX · WebKit \(webKitVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeStyle.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            }
        }
        .background(ChromeStyle.page.ignoresSafeArea())
        .navigationTitle("CHROMEX")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .alert("Clear browsing data?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                onClearData()
                dismiss()
            }
        } message: {
            Text("Cookies, site data, cached files and history are removed from this device. Downloaded files stay in Files.")
        }
    }

    // MARK: Rows

    private var zoomRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat.size")
                .font(.system(size: 15))
                .foregroundStyle(ChromeStyle.textSecondary)
                .frame(width: 22)
            Text("Zoom")
                .font(.system(size: 15))
                .foregroundStyle(ChromeStyle.text)
            Spacer()
            Button {
                tab.setZoom(tab.zoom - 0.1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChromeStyle.text)
                    .frame(width: 30, height: 30)
                    .background(ChromeStyle.omnibox, in: Circle())
            }
            .buttonStyle(.plain)
            Text("\(Int((tab.zoom * 100).rounded()))%")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChromeStyle.textSecondary)
                .frame(width: 46)
            Button {
                tab.setZoom(tab.zoom + 0.1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChromeStyle.text)
                    .frame(width: 30, height: 30)
                    .background(ChromeStyle.omnibox, in: Circle())
            }
            .buttonStyle(.plain)
            Button("Reset") {
                tab.setZoom(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(ChromeStyle.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
    }

    private var divider: some View {
        ChromeDivider().padding(.vertical, 4)
    }

    private func row(_ symbol: String, _ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(destructive ? ChromeStyle.danger : ChromeStyle.textSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(destructive ? ChromeStyle.danger : ChromeStyle.text)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func link<Destination: View>(_ symbol: String, _ title: String, _ destination: Destination) -> some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(ChromeStyle.textSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(ChromeStyle.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var webKitVersion: String {
        "605.1"
    }
}
