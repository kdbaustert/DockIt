import SwiftUI

struct AppearancePane: View {
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
            SettingsSection(title: "Theme", anchor: SettingsAnchor.theme) {
                SettingsRow(title: "Bar tint", subtitle: "A colour washed over the glass. Reset returns to plain glass.") {
                    HStack(spacing: 8) {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: settings.barTint) ?? .clear },
                            set: { settings.barTint = $0.hexString ?? settings.barTint }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Button("Reset") { settings.barTint = "" }
                            .disabled(settings.barTint.isEmpty)
                    }
                }
                SettingsSlider(
                    title: "Tint intensity",
                    value: $settings.barTintIntensity, range: 0...60,
                    format: { "\(Int($0))%" })
                    .disabled(settings.barTint.isEmpty)
                SettingsSlider(title: "Corner radius", value: $settings.barCornerRadius, range: 8...24)
                SettingsToggle(title: "Icon shadows", isOn: $settings.iconShadows)
                SettingsToggle(
                    title: "Running app dots",
                    subtitle: "A small dot under each running app.",
                    isOn: $settings.showsRunningDots)
            }
        }
    }
}
