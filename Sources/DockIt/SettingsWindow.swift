import AppKit
import ServiceManagement
import SwiftUI

// The settings window, built the way Cmd-Tab builds its own so the two are indistinguishable: a
// System Settings-shaped sidebar of tabs with gradient icon badges and a search field that jumps
// to any individual setting, and content built from the titled cards in `SettingsChrome.swift`.

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, interactions, applications, stacks, about

    var id: String { rawValue }

    /// Grouped the way Cmd-Tab groups its sidebar: the dock's own tabs under a heading, the two
    /// bookends on their own.
    static let groups: [(header: String?, tabs: [SettingsTab])] = [
        (nil, [.general]),
        ("Dock", [.appearance, .interactions, .applications, .stacks]),
        (nil, [.about]),
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .interactions: "Interactions"
        case .applications: "Applications"
        case .stacks: "Stacks"
        case .about: "About"
        }
    }

    /// Cmd-Tab's own badge values for the tabs the two apps share in spirit.
    var gradient: (Color, Color) {
        switch self {
        case .general: (Color(hex: "#8E8E93")!, Color(hex: "#6C6C70")!)
        case .appearance: (Color(hex: "#FF8A5B")!, Color(hex: "#E0532B")!)
        case .interactions: (Color(hex: "#A96BFF")!, Color(hex: "#6B2FD6")!)
        case .applications: (Color(hex: "#5BC8A8")!, Color(hex: "#17916F")!)
        case .stacks: (Color(hex: "#3F8CFF")!, Color(hex: "#1B5FD9")!)
        case .about: (Color(hex: "#B8B8BE")!, Color(hex: "#95959B")!)
        }
    }

    /// Cmd-Tab's icon family: solid, geometric, enclosed where a shape allows it.
    var symbol: String {
        switch self {
        case .general: "gearshape.2.fill"
        case .appearance: "swatchpalette.fill"
        case .interactions: "cursorarrow.motionlines"
        case .applications: "square.grid.3x3.fill"
        case .stacks: "folder.fill"
        case .about: "info.circle.fill"
        }
    }
}

/// Section anchors, so the search index and the sections themselves agree on one spelling.
private enum SettingsAnchor {
    static let startup = "general.startup"
    static let macOSDock = "general.macOSDock"
    static let autoHide = "interactions.autoHide"
    static let display = "general.display"
    static let iCloud = "general.iCloud"
    static let backup = "general.backup"
    static let position = "appearance.position"
    static let size = "appearance.size"
    static let magnification = "interactions.magnification"
    static let launching = "interactions.launching"
    static let previews = "interactions.previews"
    static let pinned = "applications.pinned"
    static let hidden = "applications.hidden"
    static let stacks = "stacks.folders"
    static let build = "about.build"
}

/// One searchable setting. Hand-written rather than derived from the views: a row is findable by the
/// words someone would actually type for it, which the label alone rarely covers.
private struct SettingsIndexItem: Identifiable {
    let id: String
    let tab: SettingsTab
    let anchor: String
    let section: String
    let title: String
    let keywords: [String]

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let hay = ([title, section, tab.title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy(hay.contains)
    }
}

private enum SettingsIndex {
    static let items: [SettingsIndexItem] = [
        item("menuBarIcon", .general, SettingsAnchor.startup, "Startup", "Show menu-bar icon",
             ["menu bar", "status item", "hide icon", "tray"]),
        item("startAtLogin", .general, SettingsAnchor.startup, "Startup", "Start at login",
             ["login", "launch", "boot", "autostart", "startup"]),
        item("hideSystemDock", .general, SettingsAnchor.macOSDock, "macOS Dock", "Hide the macOS Dock",
             ["system dock", "apple dock", "restore", "replace"]),
        item("iCloudSync", .general, SettingsAnchor.iCloud, "iCloud", "Sync settings with iCloud",
             ["icloud", "sync", "cloud", "other macs", "share"]),
        item("export", .general, SettingsAnchor.backup, "Backup", "Export settings",
             ["export", "backup", "save", "json", "share"]),
        item("import", .general, SettingsAnchor.backup, "Backup", "Import settings",
             ["import", "restore", "load", "json"]),
        item("autoHide", .interactions, SettingsAnchor.autoHide, "Auto-hide", "Automatically hide and show the dock",
             ["autohide", "auto-hide", "hide", "reveal", "edge", "sensitivity", "delay", "speed"]),
        item("display", .general, SettingsAnchor.display, "Display", "Show the dock on",
             ["display", "screen", "monitor", "follow", "all displays", "primary"]),
        item("edge", .appearance, SettingsAnchor.position, "Position", "Position on screen",
             ["left", "right", "bottom", "edge", "side", "orientation"]),
        item("iconSize", .appearance, SettingsAnchor.size, "Size", "Icon size",
             ["size", "bigger", "smaller", "scale", "tile"]),
        item("iconPadding", .appearance, SettingsAnchor.size, "Size", "Icon padding",
             ["padding", "spacing", "gap", "between icons"]),
        item("dockPadding", .appearance, SettingsAnchor.size, "Size", "Dock padding",
             ["padding", "margin", "inset", "bar"]),
        item("magnify", .interactions, SettingsAnchor.magnification, "Magnification", "Magnify icons under the pointer",
             ["magnification", "zoom", "grow", "enlarge", "hover"]),
        item("magnifyAmount", .interactions, SettingsAnchor.magnification, "Magnification", "Amount",
             ["magnification", "zoom", "size", "amount", "scale"]),
        item("magnifyReach", .interactions, SettingsAnchor.magnification, "Magnification", "Reach",
             ["magnification", "reach", "spread", "falloff", "narrow", "wide"]),
        item("magnifyApproach", .interactions, SettingsAnchor.magnification, "Magnification", "Magnify as the pointer approaches",
             ["magnification", "approach", "near", "proximity"]),
        item("smoothHover", .interactions, SettingsAnchor.magnification, "Magnification", "Smooth hover animation",
             ["animation", "spring", "glide", "smooth", "hover"]),
        item("hoverIntensity", .interactions, SettingsAnchor.magnification, "Magnification", "Hover highlight",
             ["hover", "highlight", "intensity", "glow", "brightness", "opacity"]),
        item("bounce", .interactions, SettingsAnchor.launching, "Launching", "Bounce icons while apps open",
             ["bounce", "launch", "opening", "animation", "jump"]),
        item("previews", .interactions, SettingsAnchor.previews, "Window previews", "Show window previews on hover",
             ["preview", "thumbnail", "windows", "hover", "peek"]),
        item("previewDelay", .interactions, SettingsAnchor.previews, "Window previews", "Preview delay",
             ["preview", "delay", "hover", "wait"]),
        item("previewControls", .interactions, SettingsAnchor.previews, "Window previews", "Window controls",
             ["preview", "close", "controls", "title", "buttons"]),
        item("pinned", .applications, SettingsAnchor.pinned, "Pinned apps", "Pinned apps",
             ["pin", "keep in dock", "remove", "apps", "applications"]),
        item("hiddenApps", .applications, SettingsAnchor.hidden, "Hidden apps", "Hidden apps",
             ["hide", "hidden", "exclude", "never show", "helper", "background"]),
        item("addApplication", .applications, SettingsAnchor.pinned, "Pinned apps", "Add an application",
             ["add", "pin", "choose", "select", "app", "applications"]),
        item("stacks", .stacks, SettingsAnchor.stacks, "Folders", "Stacks",
             ["folder", "downloads", "add folder", "stack"]),
        item("version", .about, SettingsAnchor.build, "DockIt", "Version",
             ["version", "build", "about"]),
    ]

    private static func item(
        _ id: String, _ tab: SettingsTab, _ anchor: String, _ section: String, _ title: String,
        _ keywords: [String]
    ) -> SettingsIndexItem {
        SettingsIndexItem(id: id, tab: tab, anchor: anchor, section: section, title: title, keywords: keywords)
    }
}

// MARK: - Root

private struct SettingsRootView: View {
    let settings: DockSettings
    @State private var tab: SettingsTab = .general
    @State private var query = ""
    /// Anchor a search result asked for. Cleared once the scroll has happened, so picking the same
    /// result twice still moves.
    @State private var jump: String?
    /// Anchor currently outlined. See `settingsFlash`.
    @State private var flash: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 212)
                .background(VisualEffectBackground(material: .sidebar))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Deliberately no background: the window's own backdrop shows through here.
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 500, idealHeight: 580)
        .environment(\.settingsFlash, flash)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights, which sit over the sidebar in a full-size-content window.
            SettingsSearchField(text: $query)
                .padding(.horizontal, 10)
                .padding(.top, 38)
                .padding(.bottom, 8)

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                tabList
            } else {
                results
            }
            Spacer(minLength: 0)
        }
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsTab.groups.enumerated()), id: \.offset) { _, group in
                if let header = group.header {
                    Text(header)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.tabs) { candidate in
                    tabRow(candidate)
                }
            }
        }
        .padding(.horizontal, 8)
        .accessibilityLabel("Settings sections")
    }

    private func tabRow(_ candidate: SettingsTab) -> some View {
        Button {
            tab = candidate
        } label: {
            HStack(spacing: 9) {
                SettingsTabIcon(symbol: candidate.symbol, start: candidate.gradient.0, end: candidate.gradient.1)
                Text(candidate.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tab == candidate ? Color.primary.opacity(0.10) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(tab == candidate ? [.isButton, .isSelected] : .isButton)
    }

    /// Search hits, each naming the tab and section it lives in — the sidebar's job the rest of the
    /// time, which is why they take its place rather than covering the content.
    @ViewBuilder
    private var results: some View {
        let hits = SettingsIndex.items.filter { $0.matches(query) }
        if hits.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(hits) { hit in
                        Button {
                            tab = hit.tab
                            query = ""
                            jump = hit.anchor
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).font(.system(size: 12))
                                Text("\(hit.tab.title) › \(hit.section)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: jump) { _, anchor in
                    guard let anchor else { return }
                    // The tab changed in the same turn, so the section being scrolled to does not
                    // exist yet; let SwiftUI build the new pane before asking for it.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                        flash = anchor
                        jump = nil
                    }
                }
                .onChange(of: flash) { _, anchor in
                    guard anchor != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if flash == anchor { flash = nil }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralPane(settings: settings)
        case .appearance: AppearancePane(settings: settings)
        case .interactions: InteractionsPane(settings: settings)
        case .applications: ApplicationsPane(settings: settings)
        case .stacks: StacksPane(settings: settings)
        case .about: AboutPane()
        }
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Bindable var settings: DockSettings
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    /// Set while a failed change puts the toggle back, so that `onChange` does not answer the reset by
    /// trying the opposite change and replacing the real error with its own.
    @State private var isResettingLogin = false

    var body: some View {
        SettingsPage(title: "General", subtitle: "How DockIt starts, and what it does with the macOS Dock.") {
            SettingsSection(title: "Startup", anchor: SettingsAnchor.startup, footer: loginError) {
                SettingsToggle(
                    title: "Show menu-bar icon",
                    subtitle: "Off leaves no menu-bar item. Right-click the dock to get Settings back.",
                    isOn: $settings.showsMenuBarIcon)
                SettingsToggle(title: "Start at login", isOn: $opensAtLogin)
            }
            SettingsSection(
                title: "macOS Dock",
                anchor: SettingsAnchor.macOSDock,
                footer: "When you quit DockIt, it asks whether to bring the macOS Dock back."
            ) {
                SettingsToggle(
                    title: "Hide the macOS Dock",
                    subtitle: "It keeps running for Cmd-Tab, Mission Control and Spaces — just out of sight.",
                    isOn: $settings.hidesSystemDock)
            }
            SettingsSection(
                title: "Display", anchor: SettingsAnchor.display,
                footer: NSScreen.screens.count > 1
                    ? nil : "One screen is attached right now; these take effect when more are."
            ) {
                SettingsChoice(
                    title: "Show the dock on",
                    selection: $settings.displayMode,
                    options: [
                        .init(value: .followPointer, title: "Follow the pointer", symbol: "cursorarrow.motionlines"),
                        .init(value: .primary, title: "Primary display", symbol: "menubar.dock.rectangle"),
                        .init(value: .specific, title: "A specific display", symbol: "1.square"),
                        .init(value: .all, title: "All displays", symbol: "rectangle.on.rectangle"),
                    ])
                if settings.displayMode == .specific {
                    SettingsRow(title: "Display") {
                        Picker("", selection: $settings.specificDisplay) {
                            ForEach(NSScreen.screens, id: \.displayUUID) { screen in
                                Text(screen.localizedName).tag(screen.displayUUID ?? "")
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        // Nothing chosen yet matches no tag, and the picker shows blank — while the
                        // dock itself already sits on the first screen, the fallback it uses.
                        .onAppear {
                            if settings.specificDisplay.isEmpty,
                               let first = NSScreen.screens.first?.displayUUID {
                                settings.specificDisplay = first
                            }
                        }
                    }
                }
            }
            SettingsSection(
                title: "iCloud", anchor: SettingsAnchor.iCloud,
                footer: SettingsSync.isAvailable
                    ? "Every Mac signed in to your iCloud account with this on shares one set of settings, kept in iCloud Drive ▸ DockIt. Hiding the macOS Dock stays per Mac."
                    : "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings ▸ Apple Account ▸ iCloud."
            ) {
                SettingsToggle(
                    title: "Sync settings with iCloud",
                    subtitle: "Size, magnification, hover, pinned apps, stacks and hidden apps.",
                    isOn: $settings.syncsWithICloud)
                    .disabled(!SettingsSync.isAvailable)
            }
            SettingsSection(title: "Backup", anchor: SettingsAnchor.backup) {
                SettingsRow(title: "Settings file", subtitle: "Move your whole setup between Macs, or keep a copy.") {
                    HStack(spacing: 8) {
                        Button("Export…") { SettingsFile.export(settings) }
                        Button("Import…") { SettingsFile.importInto(settings) }
                    }
                }
            }
        }
        .onChange(of: opensAtLogin) { _, on in
            if isResettingLogin {
                isResettingLogin = false
                return
            }
            setOpensAtLogin(on)
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            let enabled = SMAppService.mainApp.status == .enabled
            if enabled != opensAtLogin {
                isResettingLogin = true
                opensAtLogin = enabled
            }
        }
    }
}

private struct AppearancePane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(title: "Appearance", subtitle: "Where the dock sits and how big it is.") {
            SettingsSection(title: "Position", anchor: SettingsAnchor.position) {
                SettingsChoice(
                    title: "Position on screen",
                    selection: $settings.edge,
                    options: [
                        .init(value: .left, title: "Left", symbol: "rectangle.leftthird.inset.filled"),
                        .init(value: .bottom, title: "Bottom", symbol: "rectangle.bottomthird.inset.filled"),
                        .init(value: .right, title: "Right", symbol: "rectangle.rightthird.inset.filled"),
                    ])
            }
            SettingsSection(title: "Size", anchor: SettingsAnchor.size) {
                SettingsSlider(title: "Icon size", value: $settings.iconSize, range: 24...128)
                SettingsSlider(
                    title: "Icon padding", subtitle: "Space between neighbouring icons.",
                    value: $settings.iconPadding, range: 0...24)
                SettingsSlider(
                    title: "Dock padding", subtitle: "Space between the icons and the edge of the bar.",
                    value: $settings.dockPadding, range: 0...24)
            }
        }
    }
}

private struct InteractionsPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(title: "Interactions", subtitle: "How the dock answers the pointer.") {
            SettingsSection(title: "Auto-hide", anchor: SettingsAnchor.autoHide) {
                SettingsToggle(
                    title: "Automatically hide and show the dock",
                    subtitle: "Slides away when the pointer leaves it; push against the screen edge to bring it back.",
                    isOn: $settings.autoHides)
                SettingsSlider(
                    title: "Reveal sensitivity", subtitle: "How close to the edge the pointer must push.",
                    value: $settings.revealSensitivity, range: 1...20,
                    format: { "\(Int($0)) pt" })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Reveal delay", subtitle: "How long the pointer holds the edge first.",
                    value: $settings.revealDelay, range: 0...2, step: 0.1,
                    format: { $0 == 0 ? "None" : String(format: "%.1fs", $0) })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Hide delay", subtitle: "How long after the pointer leaves before it slides away.",
                    value: $settings.hideDelay, range: 0...2, step: 0.1,
                    format: { $0 == 0 ? "None" : String(format: "%.1fs", $0) })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Reveal speed",
                    value: $settings.revealSpeed, range: 0.25...4, step: 0.25,
                    format: { String(format: "%.2f×", $0) })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Hide speed",
                    value: $settings.hideSpeed, range: 0.25...4, step: 0.25,
                    format: { String(format: "%.2f×", $0) })
                    .disabled(!settings.autoHides)
            }
            SettingsSection(title: "Magnification", anchor: SettingsAnchor.magnification) {
                SettingsToggle(title: "Magnify icons under the pointer", isOn: $settings.magnifies)
                SettingsSlider(
                    title: "Amount", subtitle: "How much the hovered icon grows.",
                    value: $settings.magnifyAmount, range: 1.0...2.5, step: 0.05,
                    format: { String(format: "%.2f×", $0) })
                    .disabled(!settings.magnifies)
                SettingsSlider(
                    title: "Reach", subtitle: "How far along the bar the growth spreads.",
                    value: $settings.magnifyReach, range: 1.0...4.0, step: 1.0,
                    // Words, not "icons": the honest unit is icon-widths, which read as a glitch on
                    // the slider, and points would change meaning with every icon-size change.
                    format: { ["Narrow", "Medium", "Wide", "Widest"][min(max(Int($0), 1), 4) - 1] })
                    .disabled(!settings.magnifies)
                SettingsToggle(
                    title: "Magnify as the pointer approaches",
                    subtitle: "The bar swells to meet the pointer instead of waiting for it to arrive.",
                    isOn: $settings.magnifyOnApproach)
                    .disabled(!settings.magnifies)
                SettingsToggle(
                    title: "Smooth hover animation",
                    subtitle: "Icons glide after the pointer instead of snapping to it.",
                    isOn: $settings.smoothHover)
                    .disabled(!settings.magnifies)
                SettingsSlider(
                    title: "Hover highlight",
                    subtitle: "How strongly the icon under the pointer is lit. 0% turns it off.",
                    value: $settings.hoverIntensity, range: 0...40,
                    format: { "\(Int($0))%" })
            }
            SettingsSection(title: "Launching", anchor: SettingsAnchor.launching) {
                SettingsToggle(
                    title: "Bounce icons while apps open",
                    subtitle: "Stops once the app has finished launching.",
                    isOn: $settings.bouncesOnLaunch)
            }
            SettingsSection(
                title: "Window previews", anchor: SettingsAnchor.previews,
                footer: "Previews need Screen Recording permission the first time; DockIt asks when a preview would first appear."
            ) {
                SettingsToggle(
                    title: "Show window previews on hover",
                    subtitle: "Rest the pointer on a running app to see its windows. Click one to jump to it.",
                    isOn: $settings.showsWindowPreviews)
                SettingsSlider(
                    title: "Preview delay",
                    value: $settings.previewDelay, range: 0...2, step: 0.1,
                    format: { String(format: "%.1fs", $0) })
                    .disabled(!settings.showsWindowPreviews)
                SettingsToggle(
                    title: "Window controls",
                    subtitle: "A title and close button on each preview.",
                    isOn: $settings.previewShowsControls)
                    .disabled(!settings.showsWindowPreviews)
            }
        }
    }
}

private struct ApplicationsPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(title: "Applications", subtitle: "Drag icons in the dock to reorder them, or drop apps onto it.") {
            SettingsSection(
                title: "Pinned apps", anchor: SettingsAnchor.pinned,
                footer: "Finder is always first and cannot be removed."
            ) {
                if settings.pinnedApps.isEmpty {
                    SettingsWideRow(subtitle: "No pinned apps.") { EmptyView() }
                }
                ForEach(settings.pinnedApps, id: \.self) { path in
                    ItemRow(path: path) { settings.pinnedApps.removeAll { $0 == path } }
                }
                SettingsRow(title: "Add an application") {
                    Button("Add Application…", action: addApplications)
                }
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

private struct StacksPane: View {
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

private struct ItemRow: View {
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

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(title: "About", subtitle: "A Dock replacement for macOS.") {
            SettingsSection(title: "DockIt", anchor: SettingsAnchor.build) {
                SettingsRow(title: "Version") {
                    Text(version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(title: "Quit DockIt", subtitle: "Asks whether to bring the macOS Dock back first.") {
                    Button("Quit…") { NSApp.terminate(nil) }
                }
            }
        }
    }
}

// MARK: - Window

/// Hosts the settings window, the way Cmd-Tab's `SettingsPresenter` does: a full-size-content
/// window with a hidden title, so the sidebar runs the full height with the traffic lights over it;
/// an ordinary app (menu bar, Cmd-Tab entry) only while it is open.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let shared = SettingsWindow()
    private var window: NSWindow?

    static func show() { shared.present() }

    private func present() {
        let window = self.window ?? Self.makeWindow()
        self.window = window
        window.delegate = self
        // Installed before the policy change so the menu bar is never momentarily empty.
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.makeMainMenu() }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // The blunt form: the polite `activate()` can be declined in the moment the policy changes.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Back to a background app when Settings goes away, on the next turn of the run loop — at
    /// `willClose` the window is still on screen.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "DockIt Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Glass: the window paints nothing of its own, and a `.behindWindow` visual-effect view fills
        // it instead — with an opaque window underneath, the material would render as flat grey.
        window.isOpaque = false
        window.backgroundColor = .clear
        // Drawn for an opaque titlebar; over glass it reads as a scar across the top of the window.
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentView = glassContent()
        window.center()
        // A new name, so the size the earlier Liquid Glass version saved is not applied to this one.
        window.setFrameAutosaveName("DockItSettings.760")
        return window
    }

    /// One visual-effect view filling the whole frame, SwiftUI hosted on top. An `NSView` under the
    /// hosting view rather than a SwiftUI background, so it covers the titlebar strip too.
    private static func glassContent() -> NSView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        let host = NSHostingView(rootView: SettingsRootView(settings: .shared))
        host.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: backdrop.topAnchor),
            host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        return backdrop
    }

    /// The menu bar an ordinary app implies — including Edit, so the search field answers ⌘C and ⌘V.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide DockIt", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DockIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
