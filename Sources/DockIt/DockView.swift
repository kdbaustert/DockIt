import SwiftUI

struct DockView: View {
    let model: DockModel
    let state: PanelState
    let settings: DockSettings

    var body: some View {
        let metrics = model.metrics
        let layout = model.layout(for: state)
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
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .contentShape(Rectangle())
                .contextMenu { DockMenuFooter() }
                .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: nil) }
                .padding(edge.alongStart, layout.start)

            row {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    let size = index < layout.sizes.count ? layout.sizes[index] : metrics.iconSize
                    if item.kind == .separator {
                        SeparatorView(extent: size, iconSize: metrics.iconSize, horizontal: horizontal)
                    } else {
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

    var body: some View {
        Image(nsImage: model.icon(for: item))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            // Bounces away from the screen edge while the app launches. Before the highlight and
            // label: an offset moves what is drawn, not the frame, so those stay put and only the
            // icon itself jumps. When `repeating` goes false the track holds its start value, 0.
            .keyframeAnimator(initialValue: CGFloat(0), repeating: model.settings.bouncesOnLaunch && model.launching.contains(item.id)) {
                [edge] icon, lift in
                icon.offset(edge.hiddenOffset(-lift))
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
    }
}

private struct DockItemMenu: View {
    let item: DockItem
    let model: DockModel

    var body: some View {
        switch item.kind {
        case .app:
            if item.isRunning && item.id != DockModel.finderID {
                Button("Hide") { model.hide(item) }
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
        case .separator:
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

private struct DockMenuFooter: View {
    var body: some View {
        // The macOS Dock's own wording, and the same setting as Settings ▸ General ▸ Visibility.
        Button(DockSettings.shared.autoHides ? "Turn Hiding Off" : "Turn Hiding On") {
            DockSettings.shared.autoHides.toggle()
        }
        Divider()
        Button("DockIt Settings…") { SettingsWindow.show() }
        Button("Quit DockIt") { NSApp.terminate(nil) }
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

    var labelAlignment: Alignment {
        switch self {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }
}
