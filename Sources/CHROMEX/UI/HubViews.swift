import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Pending import

struct PendingImport: Identifiable {
    let id = UUID()
    let package: StagedPackage
    let grants: [String]
}

// MARK: - Hub

struct HubView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingImporter = false
    @State private var pending: PendingImport?
    @State private var errorMessage: String?
    @State private var isImporting = false

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.zip, .folder]
        if let crx = UTType(filenameExtension: "crx") {
            types.append(crx)
        }
        return types
    }

    var body: some View {
        ZStack {
            ChromeStyle.page
            VStack(spacing: 0) {
                hubHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.extensions.installed.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(model.extensions.installed) { record in
                                NavigationLink {
                                    ExtensionDetailView(record: record)
                                } label: {
                                    ExtensionHubCard(
                                        record: record,
                                        storageBytes: model.extensions.storageByteCount(for: record)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            diagnosticsCard
                        }
                        Text("CHROMEX runs a documented subset of Chrome extension APIs. Every package is analysed before install; the detail screen lists what will not work.")
                            .font(ChromexFont.caption)
                            .foregroundStyle(ChromeStyle.textTertiary)
                            .padding(.top, 4)
                    }
                    .padding(20)
                }
            }
            if isImporting {
                importingOverlay
            }
        }
        .presentationBackground(ChromeStyle.page)
        .navigationTitle("Chromex Hub")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingImporter = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Import extension")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePicker(result)
        }
        .sheet(item: $pending) { item in
            NavigationStack {
                ImportReviewView(pending: item) { _ in
                    pending = nil
                }
            }
        }
        .alert("Import failed", isPresented: alertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "puzzlepiece.extension",
            title: "No extensions yet",
            message: "Import a .zip, .crx or unpacked extension folder. CHROMEX inspects the package before anything runs.",
            actionTitle: "Import extension",
            action: { showingImporter = true }
        )
    }

    private var hubHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            DiamondMark(size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chromex Hub")
                    .font(ChromexFont.title)
                    .foregroundStyle(ChromeStyle.text)
                Text("\(model.extensions.installed.count) installed · \(model.extensions.installed.filter(\.isEnabled).count) active")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
            Spacer()
            Button {
                showingImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(ChromeStyle.accent, in: Circle())
            }
            .accessibilityLabel("Import extension")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(ChromeStyle.toolbar.opacity(0.6))
    }

    @ViewBuilder
    private var diagnosticsCard: some View {
        if !model.extensions.diagnostics.isEmpty {
            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(ChromeStyle.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Runtime diagnostics")
                            .font(ChromexFont.headline)
                            .foregroundStyle(ChromeStyle.text)
                        Text("\(model.extensions.diagnostics.count) message(s) from background pages")
                            .font(ChromexFont.caption)
                            .foregroundStyle(ChromeStyle.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChromeStyle.textTertiary)
                }
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    private var importingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Inspecting package…")
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromeStyle.textSecondary)
        }
        .padding(24)
        .background(ChromeStyle.toolbar, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func handlePicker(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            beginImport(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func beginImport(_ url: URL) {
        isImporting = true
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try ExtensionPackage.stage(from: url)
                }.value
                let grants = InstalledExtension.requestedGrants(for: staged.manifest)
                pending = PendingImport(package: staged, grants: grants)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isImporting = false
        }
    }
}

struct ExtensionHubCard: View {
    let record: InstalledExtension
    let storageBytes: Int

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ChromeStyle.toolbarRaised)
                DiamondMark(size: 20)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(ChromexFont.headline)
                    .foregroundStyle(ChromeStyle.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StateDot(kind: record.isEnabled ? .active : .idle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
        }
        .padding(14)
        .background(ChromeStyle.toolbar, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ChromeStyle.separator, lineWidth: 0.5)
        )
    }

    private var subtitle: String {
        var parts = ["v\(record.version)", record.report.verdict.title]
        if storageBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

struct ExtensionRow: View {
    let record: InstalledExtension
    let storageBytes: Int

    var body: some View {
        HStack(spacing: 12) {
            DiamondMark(size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromeStyle.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(record.isEnabled ? ChromeStyle.accent : ChromeStyle.textTertiary)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = ["v\(record.version)", record.report.verdict.title]
        if storageBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

enum ExtensionPage: String, Identifiable {
    case popup
    case options
    var id: String { rawValue }
}

struct ExtensionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: InstalledExtension

    @State private var showingRemove = false
    @State private var page: ExtensionPage?

    private var current: InstalledExtension {
        model.extensions.installed.first { $0.id == record.id } ?? record
    }

    private var hasPopup: Bool {
        current.manifest?.action?.defaultPopup != nil
    }

    private var hasOptions: Bool {
        current.manifest?.optionsPage != nil
    }

    var body: some View {
        ZStack {
            ChromeStyle.page
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identity
                    verdictCard
                    if !current.report.findings.isEmpty {
                        limitations
                    }
                    permissionsCard
                    detailsCard
                    if hasPopup {
                        popupButton
                    }
                    if hasOptions {
                        optionsButton
                    }
                    if !hasPopup {
                        actionButton
                    }
                    removeButton
                }
                .padding(20)
            }
        }
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(current.displayName)?",
            isPresented: $showingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove extension", role: .destructive) {
                model.extensions.remove(current)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its package, storage and grants are deleted from this device.")
        }
        .sheet(item: $page) { page in
            switch page {
            case .popup:
                ExtensionPopupView(record: current)
            case .options:
                ExtensionOptionsView(record: current)
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ChromeStyle.toolbarRaised)
                DiamondMark(size: 26)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(current.displayName)
                    .font(ChromexFont.title)
                    .foregroundStyle(ChromeStyle.text)
                Text("v\(current.version) · Manifest V\(current.manifest?.manifestVersion ?? 3)")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
                Text(signatureLine)
                    .font(ChromexFont.caption)
                    .foregroundStyle(current.signatureVerified ? ChromeStyle.accent : ChromeStyle.textTertiary)
            }
            Spacer()
        }
    }

    private var signatureLine: String {
        current.signatureVerified
            ? "CRX signature verified"
            : "\(current.sourceKind.uppercased()) · signature not verified"
    }

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VerdictBadge(verdict: current.report.verdict)
                Spacer()
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .tint(ChromeStyle.accent)
            }
            Text(current.report.verdict.explanation)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromeStyle.textSecondary)
            if !current.report.supported.isEmpty {
                Text("Works: \(current.report.supported.joined(separator: ", "))")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
        }
        .cardStyle()
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { current.isEnabled },
            set: { model.extensions.setEnabled(current, $0) }
        )
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Not available on iOS")
            ForEach(current.report.findings) { finding in
                findingRow(finding)
            }
        }
        .cardStyle()
    }

    private func findingRow(_ finding: CompatibilityFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.status == .refused ? "hand.raised.fill" : "minus.circle")
                .font(.system(size: 12))
                .foregroundStyle(finding.status == .refused ? ChromeStyle.danger : ChromeStyle.textSecondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.api)
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromeStyle.text)
                Text(finding.message)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textSecondary)
            }
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Can access")
            if current.grants.isEmpty {
                Text("No host access was granted.")
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromeStyle.textSecondary)
            } else {
                ForEach(current.grants, id: \.self) { grant in
                    grantRow(grant)
                }
            }
        }
        .cardStyle()
    }

    private func grantRow(_ grant: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: grant == "<all_urls>" ? "exclamationmark.shield.fill" : "checkmark.shield")
                .font(.system(size: 12))
                .foregroundStyle(grant == "<all_urls>" ? ChromeStyle.textSecondary : ChromeStyle.textSecondary)
            Text(grant)
                .font(ChromexFont.mono)
                .foregroundStyle(ChromeStyle.textSecondary)
            Spacer()
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Details")
            detailRow("Storage", ByteCountFormatter.string(
                fromByteCount: Int64(model.extensions.storageByteCount(for: current)),
                countStyle: .file
            ))
            detailRow("Installed", current.installedAt.formatted(date: .abbreviated, time: .omitted))
            detailRow("Source", current.sourceKind)
            detailRow("Background", backgroundDescription)
        }
        .cardStyle()
    }

    private var backgroundDescription: String {
        guard let manifest = current.manifest else { return "Unknown" }
        switch manifest.backgroundKind {
        case .none: return "None"
        case .serviceWorker: return "Service worker (non-persistent page)"
        case .scripts: return "Background scripts (non-persistent page)"
        case .page: return "Background page"
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromeStyle.textSecondary)
            Spacer()
            Text(value)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromeStyle.text)
        }
    }

    private var popupButton: some View {
        Button {
            page = .popup
        } label: {
            Text("Open popup")
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private var optionsButton: some View {
        Button {
            page = .options
        } label: {
            Text("Open options")
        }
        .buttonStyle(QuietButtonStyle())
    }

    private var actionButton: some View {
        Button {
            model.extensions.dispatchActionClick(for: current)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                Text("Trigger action")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButtonStyle())
    }

    private var removeButton: some View {
        Button {
            showingRemove = true
        } label: {
            Text("Remove extension")
                .font(ChromexFont.headline)
                .foregroundStyle(ChromeStyle.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(ChromeStyle.danger.opacity(0.1), in: Capsule())
        }
    }
}

// MARK: - Import review

struct ImportReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: PendingImport
    var onInstalled: (InstalledExtension) -> Void

    @State private var grants: Set<String> = []
    @State private var errorMessage: String?
    @State private var isInstalling = false

    private var manifest: ExtensionManifest { pending.package.manifest }
    private var report: CompatibilityReport { pending.package.report }

    var body: some View {
        ZStack {
            ChromeStyle.page
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBlock
                    verdictBlock
                    limitsBlock
                    grantsBlock
                    installBlock
                }
                .padding(20)
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { grants = Set(pending.grants) }
        .alert("Install failed", isPresented: alertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var headerBlock: some View {
        HStack(spacing: 12) {
            DiamondMark(size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.name)
                    .font(ChromexFont.title)
                    .foregroundStyle(ChromeStyle.text)
                Text(headerSubtitle)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
            Spacer()
        }
    }

    private var headerSubtitle: String {
        "v\(manifest.version) · Manifest V\(manifest.manifestVersion) · \(pending.package.sourceKind.rawValue.uppercased())"
    }

    private var verdictBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VerdictBadge(verdict: report.verdict)
            Text(report.verdict.explanation)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromeStyle.textSecondary)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var limitsBlock: some View {
        if !report.findings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Will not work")
                ForEach(report.findings) { finding in
                    limitRow(finding)
                }
            }
            .cardStyle()
        }
    }

    private func limitRow(_ finding: CompatibilityFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(ChromeStyle.textSecondary)
                .padding(.top, 2)
            Text("\(finding.api) — \(finding.message)")
                .font(ChromexFont.caption)
                .foregroundStyle(ChromeStyle.textSecondary)
        }
    }

    private var grantsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Allow access")
            if pending.grants.isEmpty {
                Text("This extension requests no host access.")
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromeStyle.textSecondary)
            } else {
                ForEach(pending.grants, id: \.self) { grant in
                    grantToggle(grant)
                }
            }
        }
        .cardStyle()
    }

    private func grantToggle(_ grant: String) -> some View {
        Toggle(isOn: binding(for: grant)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(grant == "<all_urls>" ? "All websites" : grant)
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromeStyle.text)
                Text(grant == "<all_urls>" ? "Read and change data on every site you visit" : "Read and change data on matching sites")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
        }
        .tint(ChromeStyle.accent)
    }

    private func binding(for grant: String) -> Binding<Bool> {
        Binding(
            get: { grants.contains(grant) },
            set: { enabled in
                if enabled {
                    grants.insert(grant)
                } else {
                    grants.remove(grant)
                }
            }
        )
    }

    private var installBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing has run yet. Installing adds the package to this device; content scripts only run on sites you allowed.")
                .font(ChromexFont.caption)
                .foregroundStyle(ChromeStyle.textTertiary)
            Button {
                install()
            } label: {
                installLabel
            }
            .buttonStyle(PrimaryButtonStyle(fill: installTint))
            .disabled(isInstalling)
        }
    }

    @ViewBuilder
    private var installLabel: some View {
        if isInstalling {
            ProgressView().tint(.white)
        } else {
            Text(report.verdict == .refused ? "Install anyway" : "Install extension")
        }
    }

    private var installTint: Color {
        report.verdict == .refused ? ChromeStyle.textTertiary : ChromeStyle.accent
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func install() {
        isInstalling = true
        do {
            let record = try model.extensions.install(pending.package, grants: Array(grants))
            onInstalled(record)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isInstalling = false
    }
}

// MARK: - Popup

struct ExtensionPopupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: InstalledExtension

    @State private var webView: WKWebView?

    var body: some View {
        ZStack {
            ChromeStyle.page
            VStack(spacing: 0) {
                popupHeader
                if let webView {
                    WebViewContainer(webView: webView)
                } else {
                    EmptyStateView(
                        symbol: "puzzlepiece",
                        title: "No popup",
                        message: "This extension does not declare an action popup."
                    )
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if webView == nil {
                webView = model.extensions.makePopupWebView(for: record)
            }
        }
    }

    private var popupHeader: some View {
        HStack {
            DiamondMark(size: 16)
            Text(record.displayName)
                .font(ChromexFont.headline)
                .foregroundStyle(ChromeStyle.text)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ChromeStyle.textTertiary)
            }
            .accessibilityLabel("Close popup")
        }
        .padding(16)
    }
}

// MARK: - Options page

struct ExtensionOptionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: InstalledExtension

    @State private var webView: WKWebView?

    var body: some View {
        ZStack {
            ChromeStyle.page
            VStack(spacing: 0) {
                HStack {
                    DiamondMark(size: 16)
                    Text("\(record.displayName) options")
                        .font(ChromexFont.headline)
                        .foregroundStyle(ChromeStyle.text)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ChromeStyle.textTertiary)
                    }
                    .accessibilityLabel("Close options")
                }
                .padding(16)

                if let webView {
                    WebViewContainer(webView: webView)
                } else {
                    EmptyStateView(
                        symbol: "gearshape",
                        title: "No options page",
                        message: "This extension does not declare an options page."
                    )
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if webView == nil {
                webView = model.extensions.makeOptionsWebView(for: record)
            }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            ChromeStyle.page
            if model.extensions.diagnostics.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "No runtime errors",
                    message: "Errors reported by extension background pages appear here."
                )
            } else {
                diagnosticList
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { model.extensions.clearDiagnostics() }
            }
        }
    }

    private var diagnosticList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.extensions.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(ChromexFont.mono)
                        .foregroundStyle(ChromeStyle.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}
