import SwiftUI

struct DockView: View {
    let model: DockModel
    let state: PanelState
    let settings: DockSettings

    var body: some View {
        let layout = model.layout(for: state)
        let metrics = layout.metrics
        let hovered = state.pointer.flatMap(layout.index(at:))
        let edge = settings.edge
        let horizontal = edge == .bottom
        let row = horizontal
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: metrics.spacing))
            : AnyLayout(VStackLayout(alignment: edge == .left ? .leading : .trailing, spacing: metrics.spacing))

        ZStack(alignment: edge.alignment) {
            Rectangle()
                .fill(.clear)
                .frame(
                    width: horizontal ? layout.length : metrics.thickness,
                    height: horizontal ? metrics.thickness : layout.length
                )
                .glassEffect(.regular, in: .rect(cornerRadius: settings.barCornerRadius))
                // The tint sits over the glass, so the desktop still shows through the colour.
                .overlay {
                    if let tint = Color(hex: settings.barTint) {
                        RoundedRectangle(cornerRadius: settings.barCornerRadius, style: .continuous)
                            .fill(tint.opacity(settings.barTintIntensity / 100))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityLabel("Dock")
                .contextMenu {
                    Button("Add Spacer") { model.addSpacer() }
                    Divider()
                    DockMenuFooter()
                }
                .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: nil) }
                .padding(edge.alongStart, layout.start)

            row {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    let size = index < layout.sizes.count ? layout.sizes[index] : metrics.iconSize
                    switch item.kind {
                    case .separator:
                        SeparatorView(extent: size, iconSize: metrics.iconSize, horizontal: horizontal)
                    case .spacer:
                        SpacerTile(item: item, extent: size, iconSize: metrics.iconSize, horizontal: horizontal, model: model)
                    case .minimizedWindow:
                        MinimizedTile(item: item, extent: size, iconSize: metrics.iconSize, horizontal: horizontal, model: model)
                    case .nowPlaying:
                        NowPlayingTile(width: size, height: metrics.iconSize)
                            .onDrag { model.dragPayload(for: item) }
                            .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
                    case .weather:
                        WeatherTile(width: size, height: metrics.iconSize)
                            .onDrag { model.dragPayload(for: item) }
                            .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
                    case .clock:
                        ClockTile(width: size, height: metrics.iconSize)
                            .onDrag { model.dragPayload(for: item) }
                            .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
                    case .app, .folder, .trash:
                        DockIcon(item: item, size: size, isHovered: index == hovered, edge: edge, model: model)
                    }
                }
            }
            .padding(edge.alongStart, layout.start + metrics.padding)
            .padding(edge.screenEdge, metrics.padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
        .offset(state.isHidden ? edge.hiddenOffset(metrics.thickness + 8) : .zero)
    }
}

private struct DockIcon: View {
    let item: DockItem
    let size: CGFloat
    let isHovered: Bool
    let edge: DockEdge
    let model: DockModel
    @State private var isTargeted = false

    private var isBouncing: Bool { model.settings.bouncesOnLaunch && model.launching.contains(item.id) }

    var body: some View {
        Image(nsImage: model.icon(for: item))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let badge = model.badges[item.id] { BadgeView(text: badge, iconSize: size) }
            }
            // Bounces away from the screen edge while the app launches. Before the highlight and
            // label: an offset moves what is drawn, not the frame, so those stay put and only the
            // icon itself jumps. When `repeating` goes false the track freezes wherever it is, so
            // the lift applies only while bouncing: a launch that ended on the timeout, mid-cycle,
            // left the icon hanging half an icon up until DockIt restarted.
            .keyframeAnimator(initialValue: CGFloat(0), repeating: isBouncing) {
                [edge, isBouncing] icon, lift in
                icon.offset(edge.hiddenOffset(isBouncing ? -lift : 0))
            } keyframes: { [bounce = model.metrics.iconSize * 0.5] _ in
                // A thrown ball, as the macOS Dock's launch bounce moves: decelerating to the top,
                // accelerating back down, and straight into the next with no rest between. Height
                // from the resting size, so a magnified icon does not bounce higher.
                // `DockModel.bounceCycle` must equal the two durations — the bounce stops only on
                // a whole cycle, so the icon is never left in the air.
                KeyframeTrack {
                    LinearKeyframe(bounce, duration: 0.3, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.3, timingCurve: .easeIn)
                }
            }
            .brightness(isTargeted ? 0.15 : 0)
            .shadow(color: .black.opacity(model.settings.iconShadows ? 0.35 : 0), radius: 3, y: 1)
            .overlay(alignment: edge.dotAlignment) {
                if model.settings.showsRunningDots, item.isRunning, item.kind == .app {
                    Circle()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 4, height: 4)
                        .offset(edge.hiddenOffset(model.metrics.padding / 2 + 2))
                }
            }
            // Reaches half the icon padding past the icon, so neighbouring highlights never touch.
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(.primary.opacity(model.settings.hoverIntensity / 100))
                        .padding(-model.metrics.spacing / 2)
                        // Every pointer update is animated (see DockController.tick), so without
                        // this the old highlight and label fade out while the new ones fade in, and
                        // two names overlap. They move with the pointer, so they switch instantly.
                        .transition(.identity)
                }
            }
            .overlay(alignment: edge.labelAlignment) {
                // Fades in, as DockFix's does, but vanishes at once, so the outgoing name never
                // overlaps the incoming one.
                if isHovered { label.transition(.asymmetric(insertion: .opacity, removal: .identity)) }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.open(item) }
            .contextMenu {
                DockItemMenu(item: item, model: model)
                Divider()
                DockMenuFooter()
            }
            .onDrag { model.dragPayload(for: item) }
            .onDrop(of: DockModel.dropTypes, isTargeted: $isTargeted) { model.handleDrop($0, onto: item) }
            // One element per icon, read by its name: the hover label and the badge are drawn
            // children, and would otherwise be read out as separate items.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isButton)
            // The tap gesture is not an action VoiceOver can press; this is.
            .accessibilityAction { model.open(item) }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if item.kind == .app, item.isRunning { parts.append("running") }
        if isBouncing { parts.append("launching") }
        if let badge = model.badges[item.id] { parts.append("badge \(badge)") }
        if item.kind == .trash, model.trashIsFull { parts.append("full") }
        return parts.joined(separator: ", ")
    }

    /// The name, beside the icon on the side away from the screen edge. The overlay puts a zero-size
    /// frame on the icon's edge and the label hangs off it outward, 10 points clear — no need to know
    /// the label's size. (Alignment guides on the label were tried first and were ignored: the label
    /// sat over the top half of the icon.)
    @ViewBuilder private var label: some View {
        let text = Text(item.name)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
        switch edge {
        case .bottom: text.frame(height: 0, alignment: .bottom).offset(y: -10)
        case .left: text.frame(width: 0, alignment: .leading).offset(x: 10)
        case .right: text.frame(width: 0, alignment: .trailing).offset(x: -10)
        }
    }
}

private struct SeparatorView: View {
    let extent: CGFloat
    let iconSize: CGFloat
    let horizontal: Bool

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.25))
            .frame(width: horizontal ? 1 : iconSize * 0.75, height: horizontal ? iconSize * 0.75 : 1)
            .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
            .contentShape(Rectangle())
            .contextMenu { DockMenuFooter() }
            .accessibilityHidden(true)
    }
}

private struct DockItemMenu: View {
    let item: DockItem
    let model: DockModel

    var body: some View {
        switch item.kind {
        case .app:
            if item.isRunning && item.id != DockModel.finderID {
                Button("Quit") { model.quit(item) }
                Button("Force Quit") { model.forceQuit(item) }
                Divider()
            }
            if item.id != DockModel.finderID {
                if item.isPinned {
                    Button("Remove from Dock") { model.unpin(item) }
                } else {
                    Button("Keep in Dock") { model.pin(item) }
                }
                if item.url != nil {
                    Button("Hide from Dock") { model.hideFromDock(item) }
                }
            }
            if let bundleID = item.url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
                AssignToMenu(bundleID: bundleID)
            }
            if item.url != nil {
                Button("Show in Finder") { model.reveal(item) }
            }
        case .folder:
            Button("Open") { model.open(item) }
            Button("Show in Finder") { model.reveal(item) }
            Divider()
            Button("Remove from Dock") { model.unpin(item) }
        case .trash:
            Button("Open") { model.open(item) }
            Button("Empty Trash") { model.emptyTrash() }
        case .minimizedWindow:
            Button("Restore") { model.open(item) }
            if let windowID = item.windowID, let pid = item.pid {
                Button("Close Window") { WindowActions.close(windowID, pid: pid) }
            }
        case .spacer:
            Button("Remove from Dock") { model.unpin(item) }
        case .separator, .nowPlaying, .weather, .clock:
            EmptyView()
        }
    }
}

/// Options ▸ Assign To, as in the macOS Dock. Toggles rather than Buttons: in a SwiftUI menu a
/// Toggle is what draws the checkmark (measured in FinderPlus — checkmark images on Buttons did not
/// render). Read when the menu is built, since the assignment lives in another app's preferences
/// and nothing announces a change to it.
private struct AssignToMenu: View {
    let bundleID: String

    var body: some View {
        let current = DesktopAssignments.assignment(of: bundleID)
        Menu("Options") {
            Section("Assign To") {
                option("All Desktops", .allDesktops, current)
                option("This Desktop", .thisDesktop, current)
                    .disabled(!DesktopAssignments.canAssignThisDesktop)
                if case .otherDesktop(let number) = current {
                    Toggle(number.map { "Desktop \($0)" } ?? "Another Desktop", isOn: .constant(true))
                        .disabled(true)
                }
                option("None", .none, current)
            }
        }
    }

    private func option(
        _ title: String, _ target: DesktopAssignments.Assignment, _ current: DesktopAssignments.Assignment
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { current == target },
            // Picking the ticked item again would only rewrite the binding and restart the Dock.
            set: { on in
                if on, target != current { DesktopAssignments.assign(bundleID, to: target) }
            }
        ))
    }
}

/// Invisible, but draggable and removable — a gap the user placed.
private struct SpacerTile: View {
    let item: DockItem
    let extent: CGFloat
    let iconSize: CGFloat
    let horizontal: Bool
    let model: DockModel

    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            // Invisible until the pointer is on it: a gap that never announces itself, but can
            // still be found, grabbed and dragged.
            .fill(.primary.opacity(isHovered ? 0.12 : 0))
            .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .contextMenu {
                DockItemMenu(item: item, model: model)
                Divider()
                DockMenuFooter()
            }
            .onDrag {
                model.dragPayload(for: item)
            } preview: {
                // Dragging an invisible view drags an invisible image, which reads as a broken drag.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.primary.opacity(0.25))
                    .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
            }
            .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
            // An invisible gap, and nothing to press.
            .accessibilityHidden(true)
    }
}

/// A minimized window: its own snapshot, restored by a click — the real Dock's right side.
private struct MinimizedTile: View {
    let item: DockItem
    let extent: CGFloat
    let iconSize: CGFloat
    let horizontal: Bool
    let model: DockModel

    var body: some View {
        Group {
            if let windowID = item.windowID, let thumb = model.minimizedThumbs[windowID] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                // The snapshot arrives late; until then, the owning app's icon marks the spot.
                Image(nsImage: item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.8)
            }
        }
        // `extent` runs along the bar, which is vertical on a side dock.
        .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
        .help(item.name)
        .contentShape(Rectangle())
        .onTapGesture { model.open(item) }
        .contextMenu {
            DockItemMenu(item: item, model: model)
            Divider()
            DockMenuFooter()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.open(item) }
    }

    /// The window's title and whose it is — a title alone ("Untitled") says little.
    private var accessibilityLabel: String {
        let app = item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return ["Minimized window", item.name.isEmpty ? nil : item.name, app].compactMap(\.self).joined(separator: ", ")
    }
}

private struct NowPlayingTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let artwork = widgets.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: height * 0.4))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.primary.opacity(0.08))
                }
            }
            .frame(width: height * 0.82, height: height * 0.82)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(widgets.trackTitle ?? (widgets.deniedPlayer == nil ? "Nothing Playing" : "Not Allowed"))
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text(widgets.trackTitle == nil ? deniedHint : widgets.trackArtist)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if widgets.trackTitle != nil {
                Image(systemName: widgets.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .widgetTile(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            if widgets.trackTitle == nil, widgets.deniedPlayer != nil {
                openAutomationSettings()
            } else {
                widgets.playPause()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Playing")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { widgets.playPause() }
        .accessibilityAction(named: "Next Track") { widgets.nextTrack() }
        .accessibilityAction(named: "Previous Track") { widgets.previousTrack() }
        .contextMenu {
            Button("Play/Pause") { widgets.playPause() }
            Button("Next Track") { widgets.nextTrack() }
            Button("Previous Track") { widgets.previousTrack() }
            if widgets.deniedPlayer != nil {
                Button("Open Automation Settings…") { openAutomationSettings() }
            }
            Divider()
            // The same setting as Settings ▸ Widgets ▸ Now playing.
            Button("Remove from Dock") { DockSettings.shared.showsNowPlaying = false }
            Divider()
            DockMenuFooter()
        }
    }

    /// Where the permission is granted, once the tile says it is missing.
    private var deniedHint: String {
        widgets.deniedPlayer.map { "Allow control of \($0)" } ?? ""
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private var accessibilityValue: String {
        if widgets.trackTitle == nil, let denied = widgets.deniedPlayer {
            return "DockIt is not allowed to control \(denied)"
        }
        guard let title = widgets.trackTitle else { return "Nothing playing" }
        let track = widgets.trackArtist.isEmpty ? title : "\(title) by \(widgets.trackArtist)"
        return "\(track), \(widgets.isPlaying ? "playing" : "paused")"
    }
}

private struct WeatherTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        HStack(spacing: 6) {
            Text(widgets.weatherTemperature ?? "--°")
                .font(.system(size: height * 0.42, weight: .semibold))
            Image(systemName: widgets.weatherSymbol)
                .font(.system(size: height * 0.3))
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 0) {
                Text(widgets.weatherPlace)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(widgets.weatherHighLow)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .widgetTile(width: width, height: height)
        // The symbol is decoration here; the words carry it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weather")
        // Without a role the element is AXUnknown, and its value was never read out (measured).
        .accessibilityAddTraits(.isStaticText)
        .accessibilityValue(
            [widgets.weatherTemperature, widgets.weatherPlace, widgets.weatherHighLow]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "))
        .contextMenu {
            // The same setting as Settings ▸ Widgets ▸ Weather.
            Button("Remove from Dock") { DockSettings.shared.showsWeather = false }
            Divider()
            DockMenuFooter()
        }
    }
}

private struct ClockTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Text(widgets.clockTime)
                .font(.system(size: height * 0.34, weight: .semibold, design: .rounded))
            Text(widgets.clockDate)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .widgetTile(width: width, height: height)
        .accessibilityElement(children: .combine)
        .contextMenu {
            // The same setting as Settings ▸ Widgets ▸ Clock.
            Button("Remove from Dock") { DockSettings.shared.showsClock = false }
            Divider()
            DockMenuFooter()
        }
    }
}

/// The red count in an icon's corner, as the macOS Dock draws it: sized from the icon, never
/// narrower than a circle, and hanging a little past the corner.
private struct BadgeView: View {
    let text: String
    let iconSize: CGFloat

    var body: some View {
        let height = iconSize * 0.36
        Text(text)
            .font(.system(size: height * 0.62, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.28)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(.red))
            .fixedSize()
            .offset(x: height * 0.2, y: -height * 0.12)
    }
}

private struct DockMenuFooter: View {
    var body: some View {
        // The macOS Dock's own wording, and the same setting as Settings ▸ General ▸ Visibility.
        Button(DockSettings.shared.autoHides ? "Turn Hiding Off" : "Turn Hiding On") {
            DockSettings.shared.autoHides.toggle()
        }
        // Worded to match, and the same setting as Settings ▸ Interactions ▸ Window previews.
        Button(DockSettings.shared.showsWindowPreviews ? "Turn Previews Off" : "Turn Previews On") {
            DockSettings.shared.showsWindowPreviews.toggle()
        }
        Divider()
        Button("DockIt Settings…") { SettingsWindow.show() }
        Button("Quit DockIt") { NSApp.terminate(nil) }
    }
}

private extension View {
    /// The widget tiles' shared chrome: their size and the faint rounded backing.
    func widgetTile(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

private extension DockEdge {
    var alignment: Alignment {
        switch self {
        case .bottom: .bottomLeading
        case .left: .topLeading
        case .right: .topTrailing
        }
    }

    /// Where the along-axis offset is measured from: the strip's left end, or its top.
    var alongStart: Edge.Set { self == .bottom ? .leading : .top }

    var screenEdge: Edge.Set {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    func hiddenOffset(_ distance: CGFloat) -> CGSize {
        switch self {
        case .bottom: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        case .right: CGSize(width: distance, height: 0)
        }
    }

    /// Where the running dot sits: against the screen edge.
    var dotAlignment: Alignment {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    var labelAlignment: Alignment {
        switch self {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }
}
