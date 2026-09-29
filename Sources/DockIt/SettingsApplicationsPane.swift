import AppKit
import SwiftUI

struct ApplicationsPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        // Spacers share `pinnedApps` but are managed from the dock and Widgets ▸ Spacers; listed
        // here they would be rows with no icon and a meaningless "spacer:<uuid>" path.
        let apps = settings.pinnedApps.filter { !$0.hasPrefix(spacerPrefix) }
        SettingsPage(title: "Applications", subtitle: "Drag icons in the dock to reorder them, or drop apps onto it.") {
            SettingsSection(
                title: "Pinned apps", anchor: SettingsAnchor.pinned,
                footer: "Finder is always first and cannot be removed."
            ) {
                if apps.isEmpty {
                    SettingsWideRow(subtitle: "No pinned apps.") { EmptyView() }
                }
                ForEach(apps, id: \.self) { path in
                    ItemRow(path: path) { settings.pinnedApps.removeAll { $0 == path } }
                }
                SettingsRow(title: "Add an application") {
                    Button("Add Application…", action: addApplications)
                }
            }
            SettingsSection(
                title: "Recent apps", anchor: SettingsAnchor.recent,
                footer: "Apps you quit lately that aren't pinned, after the running apps. Remembered on this Mac only, and only while this is on."
            ) {
                SettingsToggle(
                    title: "Show recent apps in the dock",
                    subtitle: "The last \(DockModel.recentAppsShown), as the macOS Dock shows them.",
                    isOn: $settings.showsRecentApps)
            }
            SettingsSection(
                title: "Hidden apps", anchor: SettingsAnchor.hidden,
                footer: "Never shown in the dock, even while running. Right-click an app in the dock ▸ Hide from Dock to add one."
            ) {
                if settings.hiddenApps.isEmpty {
                    SettingsWideRow(subtitle: "No hidden apps.") { EmptyView() }
                }
                ForEach(settings.hiddenApps, id: \.self) { path in
                    ItemRow(path: path, actionTitle: "Show") { settings.hiddenApps.removeAll { $0 == path } }
                }
                SettingsRow(title: "Hide an application") {
                    Button("Hide an Application…", action: hideApplications)
                }
            }
        }
    }

    /// Pins the chosen apps at the end of the dock, in the order picked. Compared the way the dock
    /// compares them (symlinks resolved), so an app already pinned by another path is not added twice,
    /// and Finder — always first — is never added at all.
    private func addApplications() {
        guard let urls = chooseApplications(prompt: "Add") else { return }
        var seen = Set(settings.pinnedApps.map { DockModel.key(URL(fileURLWithPath: $0)) } + [DockModel.finderID])
        for url in urls where seen.insert(DockModel.key(url)).inserted {
            settings.pinnedApps.append(url.path)
        }
        // Pinning overrides an earlier hide, as dragging onto the dock does.
        let pinned = Set(settings.pinnedApps.map { DockModel.key(URL(fileURLWithPath: $0)) })
        settings.hiddenApps.removeAll { pinned.contains(DockModel.key(URL(fileURLWithPath: $0))) }
    }

    /// Hides the chosen apps, which also unpins them — a hidden app is never shown, pinned or not.
    private func hideApplications() {
        guard let urls = chooseApplications(prompt: "Hide") else { return }
        var seen = Set(settings.hiddenApps.map { DockModel.key(URL(fileURLWithPath: $0)) } + [DockModel.finderID])
        for url in urls where seen.insert(DockModel.key(url)).inserted {
            settings.hiddenApps.append(url.path)
        }
        let hidden = Set(settings.hiddenApps.map { DockModel.key(URL(fileURLWithPath: $0)) })
        settings.pinnedApps.removeAll { hidden.contains(DockModel.key(URL(fileURLWithPath: $0))) }
    }

    private func chooseApplications(prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

struct ItemRow: View {
    let path: String
    var actionTitle = "Remove"
    let remove: () -> Void
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
            Button(actionTitle, action: remove)
        }
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 7)
        .settingsRowDivider()
    }
}
