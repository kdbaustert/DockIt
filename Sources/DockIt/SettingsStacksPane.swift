import AppKit
import SwiftUI

struct StacksPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(
            title: "Stacks",
            subtitle: "Folders shown beside the Trash. Click one in the dock for its newest items."
        ) {
            SettingsSection(
                title: "Folders", anchor: SettingsAnchor.stacks,
                footer: "You can also drop a folder onto the dock to add it."
            ) {
                if settings.stacks.isEmpty {
                    SettingsWideRow(subtitle: "No stacks.") { EmptyView() }
                }
                ForEach(settings.stacks, id: \.self) { path in
                    ItemRow(path: path) { settings.stacks.removeAll { $0 == path } }
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
