import SwiftUI

struct TabSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewGroup = false
    @State private var newGroupName = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.groups.isEmpty {
                            Text("Long-press a tab to move it into a group.")
                                .font(ChromexFont.caption)
                                .foregroundStyle(ChromexColor.textTertiary)
                        } else {
                            groupsRow
                        }

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(model.tabs) { tab in
                                tabCard(tab)
                            }
                            newTabCard
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("New tab group")
                }
            }
            .alert("New tab group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Cancel", role: .cancel) { newGroupName = "" }
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { model.createGroup(name: name) }
                    newGroupName = ""
                }
            }
        }
        .presentationDetents([.large])
    }

    private var groupsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Groups")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.groups) { group in
                        HStack(spacing: 6) {
                            Circle().fill(ChromexColor.violet).frame(width: 7, height: 7)
                            Text(group.name).font(ChromexFont.footnote)
                            Text("\(groupCount(group))").font(ChromexFont.caption).foregroundStyle(ChromexColor.textTertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(ChromexColor.surface, in: Capsule())
                        .contextMenu {
                            Button("Delete group", role: .destructive) { model.removeGroup(group) }
                        }
                    }
                }
            }
        }
    }

    private func groupCount(_ group: TabGroup) -> Int {
        model.tabs.filter { $0.groupID == group.id }.count
    }

    private func tabCard(_ tab: BrowserTab) -> some View {        Button {
            model.select(tab)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text((tab.urlString.isEmpty ? "New Tab" : (URL(string: tab.urlString)?.host ?? "New Tab")))
                        .font(ChromexFont.caption)
                        .foregroundStyle(ChromexColor.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    if tab.isPrivate {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ChromexColor.violet)
                    }
                }
                Text(tab.snapshotTitle())
                    .font(ChromexFont.callout)
                    .foregroundStyle(ChromexColor.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack {
                    if tab.groupID != nil, let group = model.groups.first(where: { $0.id == tab.groupID }) {
                        Text(group.name)
                            .font(ChromexFont.caption)
                            .foregroundStyle(ChromexColor.violet)
                    }
                    Spacer()
                    Button {
                        model.closeTab(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ChromexColor.textTertiary)
                            .frame(width: 26, height: 26)
                            .background(ChromexColor.surfaceRaised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close tab")
                }
            }
            .padding(14)
            .frame(height: 190, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ChromexColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        tab.id == model.selectedTabID ? ChromexColor.electricBlue.opacity(0.6) : ChromexColor.hairline,
                        lineWidth: tab.id == model.selectedTabID ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(model.groups) { group in
                Button("Move to \(group.name)") {
                    tab.groupID = group.id
                }
            }
            if tab.groupID != nil {
                Button("Remove from group") { tab.groupID = nil }
            }
            Button("Close tab", role: .destructive) { model.closeTab(tab) }
        }
    }

    private var newTabCard: some View {
        Button {
            model.openTab(url: nil, select: true)
            dismiss()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ChromexColor.electricBlue)
                Text("New Tab")
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(ChromexColor.hairline)
            )
        }
        .buttonStyle(.plain)
    }
}
