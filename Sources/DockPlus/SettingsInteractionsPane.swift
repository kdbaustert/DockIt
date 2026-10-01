import AppKit
import SwiftUI

struct InteractionsPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(title: "Interactions", subtitle: "How the dock answers the pointer.") {
            SettingsSection(title: "Auto-hide", anchor: SettingsAnchor.autoHide) {
                SettingsToggle(
                    title: "Automatically hide and show the dock",
                    subtitle: "Slides away when the pointer leaves it; push against the screen edge to bring it back.",
                    isOn: $settings.autoHides)
                SettingsToggle(
                    title: "Only when a window overlaps the dock",
                    subtitle: "Stays shown until a window reaches into the bar, then hides as above.",
                    isOn: $settings.autoHidesOnlyWhenOverlapped)
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Reveal sensitivity", subtitle: "How close to the edge the pointer must push.",
                    value: $settings.revealSensitivity, range: DockSettings.revealSensitivityRange,
                    format: { "\(Int($0)) pt" })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Reveal delay", subtitle: "How long the pointer holds the edge first.",
                    value: $settings.revealDelay, range: DockSettings.revealDelayRange, step: 0.1,
                    format: { $0 == 0 ? "None" : String(format: "%.1fs", $0) })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Hide delay", subtitle: "How long after the pointer leaves before it slides away.",
                    value: $settings.hideDelay, range: DockSettings.hideDelayRange, step: 0.1,
                    format: { $0 == 0 ? "None" : String(format: "%.1fs", $0) })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Reveal speed",
                    value: $settings.revealSpeed, range: DockSettings.revealSpeedRange, step: 0.25,
                    format: { String(format: "%.2f×", $0) })
                    .disabled(!settings.autoHides)
                SettingsSlider(
                    title: "Hide speed",
                    value: $settings.hideSpeed, range: DockSettings.hideSpeedRange, step: 0.25,
                    format: { String(format: "%.2f×", $0) })
                    .disabled(!settings.autoHides)
            }
            SettingsSection(title: "Magnification", anchor: SettingsAnchor.magnification) {
                SettingsToggle(title: "Magnify icons under the pointer", isOn: $settings.magnifies)
                SettingsSlider(
                    title: "Amount", subtitle: "How much the hovered icon grows.",
                    value: $settings.magnifyAmount, range: DockSettings.magnifyAmountRange, step: 0.05,
                    format: { String(format: "%.2f×", $0) })
                    .disabled(!settings.magnifies)
                SettingsSlider(
                    title: "Reach", subtitle: "How far along the bar the growth spreads.",
                    value: $settings.magnifyReach, range: DockSettings.magnifyReachRange, step: 1.0,
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
                    value: $settings.hoverIntensity, range: DockSettings.hoverIntensityRange,
                    format: { "\(Int($0))%" })
            }
            SettingsSection(title: "Launching", anchor: SettingsAnchor.launching) {
                SettingsToggle(
                    title: "Bounce icons while apps open",
                    subtitle: "Stops once the app has finished launching.",
                    isOn: $settings.bouncesOnLaunch)
            }
            SettingsSection(
                title: "Clicking", anchor: SettingsAnchor.clicking,
                footer: "Command-click shows an item in Finder. Option-click opens an app and hides all the others."
            ) {
                SettingsToggle(
                    title: "Click the frontmost app's icon to hide it",
                    subtitle: "Clicking it again brings it back.",
                    isOn: $settings.clickHidesFrontmostApp)
            }
            SettingsSection(
                title: "Window previews", anchor: SettingsAnchor.previews,
                footer: "Previews need Screen Recording permission the first time; DockPlus asks when a preview would first appear."
            ) {
                SettingsToggle(
                    title: "Show window previews on hover",
                    subtitle: "Rest the pointer on a running app to see its windows. Click one to jump to it.",
                    isOn: $settings.showsWindowPreviews)
                SettingsSlider(
                    title: "Preview delay",
                    value: $settings.previewDelay, range: DockSettings.previewDelayRange, step: 0.1,
                    format: { String(format: "%.1fs", $0) })
                    .disabled(!settings.showsWindowPreviews)
                SettingsToggle(
                    title: "Window controls",
                    subtitle: "A title and close button on each preview.",
                    isOn: $settings.previewShowsControls)
                    .disabled(!settings.showsWindowPreviews)
                SettingsToggle(
                    title: "Live previews",
                    subtitle: "The open panel keeps refreshing its thumbnails.",
                    isOn: $settings.livePreviews)
                    .disabled(!settings.showsWindowPreviews)
                SettingsToggle(
                    title: "Show only this display's windows in previews",
                    subtitle: "With a dock on every display, each shows the windows on its own screen.",
                    isOn: $settings.previewsShowOnlyThisDisplay)
                    .disabled(!settings.showsWindowPreviews || settings.displayMode != .all)
            }
            SettingsSection(
                title: "Windows", anchor: SettingsAnchor.windows,
                // Read at render, not polled: the pane is rebuilt each time the tab is opened, which
                // is when someone coming back from General ▸ Permissions would look.
                footer: "Minimized windows appear as their own tiles beside the Trash, as in the macOS Dock."
                    + (AXIsProcessTrusted() ? "" : " Needs Accessibility — see General ▸ Permissions.")
            ) {
                SettingsToggle(title: "Show minimized windows in the dock", isOn: $settings.showsMinimizedWindows)
            }
        }
    }
}
