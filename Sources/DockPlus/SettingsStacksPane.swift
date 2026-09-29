import AppKit
import SwiftUI

struct StacksPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(
            title: "Stacks",
            subtitle: "Folders shown beside the Trash. Click one in the dock to browse it."
        ) {
            SettingsSection(
                title: "Folders", anchor: SettingsAnchor.stacks,
                footer: "Each stack keeps its own sort and view, also under Sort By and View Content As when you "
                    + "right-click it in the dock. Grid shows large icons over the stack instead of a menu. "
                    + "You can also drop a folder onto the dock to add it."
            ) {
                if settings.stacks.isEmpty {
                    SettingsWideRow(subtitle: "No stacks.") { EmptyView() }
                }
                ForEach(settings.stacks, id: \.self) { path in
                    StackRow(path: path, settings: settings)
                }
                SettingsRow(title: "Add a folder") {
                    Button("Add Folder…", action: addFolder)
                }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        settings.stacks += panel.urls.map(\.path).filter { !settings.stacks.contains($0) }
    }
}

/// `ItemRow`'s layout with the stack's sort and view beside Remove. Its own row rather than an
/// accessory slot on `ItemRow`, which would make that row generic for every list in the Applications
/// pane.
private struct StackRow: View {
    let path: String
    let settings: DockSettings
    /// Looked up once: `icon(forFile:)` goes to disk, and the body runs on every render.
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)
                .task(id: path) { icon = NSWorkspace.shared.icon(forFile: path) }
            VStack(alignment: .leading, spacing: 1) {
                Text(FileManager.default.displayName(atPath: path)).font(.system(size: 13))
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Picker("Sort By", selection: Binding(
                get: { settings.stackSort(for: path) },
                set: { settings.setStackSort($0, for: path) }
            )) {
                ForEach(StackSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Sort \(FileManager.default.displayName(atPath: path)) by")
            Picker("View Content As", selection: Binding(
                get: { settings.stackDisplay(for: path) },
                set: { settings.setStackDisplay($0, for: path) }
            )) {
                ForEach(StackDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("View \(FileManager.default.displayName(atPath: path)) as")
            Button("Remove") { settings.stacks.removeAll { $0 == path } }
        }
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 7)
        .settingsRowDivider()
    }
}
