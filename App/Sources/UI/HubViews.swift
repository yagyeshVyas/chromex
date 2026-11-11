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
            BrowserBackground()
            if model.extensions.installed.isEmpty {
                emptyState
            } else {
                extensionList
            }
            if isImporting {
                importingOverlay
            }
        }
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

    private var extensionList: some View {
        List {
            diagnosticsSection
            installedSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if !model.extensions.diagnostics.isEmpty {
            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } header: {
                Text("Runtime")
            }
        }
    }

    private var installedSection: some View {
        Section {
            ForEach(model.extensions.installed) { record in
                NavigationLink {
                    ExtensionDetailView(record: record)
                } label: {
                    ExtensionRow(
                        record: record,
                        storageBytes: model.extensions.storageByteCount(for: record)
                    )
                }
            }
        } header: {
            SectionHeader(title: "Installed", trailing: "\(model.extensions.installed.count)")
        } footer: {
            Text("CHROMEX runs a documented subset of the Chrome extension APIs. Every extension is analysed before install and limitations are listed on its detail screen.")
                .font(ChromexFont.caption)
        }
    }

    private var importingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Inspecting package…")
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromexColor.textSecondary)
        }
        .padding(24)
        .background(ChromexColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

struct ExtensionRow: View {
    let record: InstalledExtension
    let storageBytes: Int

    var body: some View {
        HStack(spacing: 12) {
            DiamondMark(size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromexColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(record.isEnabled ? ChromexColor.success : ChromexColor.textTertiary)
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

struct ExtensionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: InstalledExtension

    @State private var showingRemove = false

    private var current: InstalledExtension {
        model.extensions.installed.first { $0.id == record.id } ?? record
    }

    private var hasPopup: Bool {
        current.manifest?.action?.defaultPopup != nil
    }

    var body: some View {
        ZStack {
            BrowserBackground()
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
    }

    private var identity: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ChromexColor.surfaceRaised)
                DiamondMark(size: 26)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(current.displayName)
                    .font(ChromexFont.title)
                    .foregroundStyle(ChromexColor.textPrimary)
                Text("v\(current.version) · Manifest V\(current.manifest?.manifestVersion ?? 3)")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textTertiary)
                Text(signatureLine)
                    .font(ChromexFont.caption)
                    .foregroundStyle(current.signatureVerified ? ChromexColor.success : ChromexColor.textTertiary)
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
                    .tint(ChromexColor.electricBlue)
            }
            Text(current.report.verdict.explanation)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromexColor.textSecondary)
            if !current.report.supported.isEmpty {
                Text("Works: \(current.report.supported.joined(separator: ", "))")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textTertiary)
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
                .foregroundStyle(finding.status == .refused ? ChromexColor.danger : ChromexColor.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.api)
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromexColor.textPrimary)
                Text(finding.message)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textSecondary)
            }
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Can access")
            if current.grants.isEmpty {
                Text("No host access was granted.")
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromexColor.textSecondary)
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
                .foregroundStyle(grant == "<all_urls>" ? ChromexColor.warning : ChromexColor.textSecondary)
            Text(grant)
                .font(ChromexFont.mono)
                .foregroundStyle(ChromexColor.textSecondary)
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
                .foregroundStyle(ChromexColor.textSecondary)
            Spacer()
            Text(value)
                .font(ChromexFont.footnote)
                .foregroundStyle(ChromexColor.textPrimary)
        }
    }

    private var popupButton: some View {
        Button {
            model.openPopup(for: current)
        } label: {
            Text("Open popup")
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private var removeButton: some View {
        Button {
            showingRemove = true
        } label: {
            Text("Remove extension")
                .font(ChromexFont.headline)
                .foregroundStyle(ChromexColor.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(ChromexColor.danger.opacity(0.1), in: Capsule())
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
            BrowserBackground()
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
                    .foregroundStyle(ChromexColor.textPrimary)
                Text(headerSubtitle)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textTertiary)
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
                .foregroundStyle(ChromexColor.textSecondary)
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
                .foregroundStyle(ChromexColor.warning)
                .padding(.top, 2)
            Text("\(finding.api) — \(finding.message)")
                .font(ChromexFont.caption)
                .foregroundStyle(ChromexColor.textSecondary)
        }
    }

    private var grantsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Allow access")
            if pending.grants.isEmpty {
                Text("This extension requests no host access.")
                    .font(ChromexFont.footnote)
                    .foregroundStyle(ChromexColor.textSecondary)
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
                    .foregroundStyle(ChromexColor.textPrimary)
                Text(grant == "<all_urls>" ? "Read and change data on every site you visit" : "Read and change data on matching sites")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textTertiary)
            }
        }
        .tint(ChromexColor.electricBlue)
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
                .foregroundStyle(ChromexColor.textTertiary)
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
        report.verdict == .refused ? ChromexColor.textTertiary : ChromexColor.electricBlue
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
            BrowserBackground()
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
        .presentationDetents([.medium, .large])
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
                .foregroundStyle(ChromexColor.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ChromexColor.textTertiary)
            }
            .accessibilityLabel("Close popup")
        }
        .padding(16)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            BrowserBackground()
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
                        .foregroundStyle(ChromexColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}
