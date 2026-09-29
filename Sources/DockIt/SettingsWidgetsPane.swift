import SwiftUI

struct WidgetsPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(title: "Widgets", subtitle: "Add widgets and spacers to the dock, or take them off.") {
            SettingsSection(
                title: "Widgets", anchor: SettingsAnchor.widgets,
                footer: "Widgets sit at the end of the bar, beside the Trash. Right-click one in the dock to remove it. Widgets show when the dock is at the bottom."
            ) {
                SettingsToggle(
                    title: "Now playing",
                    subtitle: "The current Spotify or Music track, with artwork. Click to play or pause. macOS asks permission to control each player once.",
                    isOn: $settings.showsNowPlaying)
                SettingsToggle(title: "Weather", isOn: $settings.showsWeather)
                WeatherLocationRow(settings: settings)
                    .disabled(!settings.showsWeather)
                SettingsToggle(title: "Fahrenheit", isOn: $settings.weatherFahrenheit)
                    .disabled(!settings.showsWeather)
                SettingsToggle(title: "Clock", isOn: $settings.showsClock)
                // The calendar's times follow it too, so the two tiles never disagree.
                SettingsToggle(title: "24-hour time", isOn: $settings.clock24Hour)
                    .disabled(!settings.showsClock && !settings.showsCalendar)
                SettingsToggle(
                    title: "Calendar",
                    subtitle: "Your next event today. macOS asks once for access to your calendars when you turn this on.",
                    isOn: calendarBinding)
                CalendarAccessRow(settings: settings)
                // Not offered at all without a battery: the tile could never show.
                if WidgetsModel.hasBattery {
                    SettingsToggle(
                        title: "Battery", subtitle: "Charge level, and whether it is charging.",
                        isOn: $settings.showsBattery)
                }
            }
            SettingsSection(
                title: "Spacers", anchor: SettingsAnchor.spacers,
                footer: "A spacer is added after the pinned apps; drag it to where you want the gap. Right-click one in the dock to remove just that one."
            ) {
                SettingsRow(
                    title: "Spacers on the dock",
                    subtitle: settings.spacerCount == 0 ? "None." : "\(settings.spacerCount) on the dock."
                ) {
                    HStack(spacing: 8) {
                        Button("Add Spacer") { settings.addSpacer() }
                        Button("Remove All") { settings.removeAllSpacers() }
                            .disabled(settings.spacerCount == 0)
                    }
                }
            }
        }
    }

    /// Turning the widget on here is the one place it asks for calendar access — a switch the user
    /// just flipped, rather than a prompt at launch or when sync turns it on from another Mac.
    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { settings.showsCalendar },
            set: { on in
                settings.showsCalendar = on
                if on { WidgetsModel.shared.requestCalendarAccess() }
            })
    }
}

/// Appears only while the widget is on and access is missing, and says where to give it back.
private struct CalendarAccessRow: View {
    let settings: DockSettings
    private let widgets = WidgetsModel.shared

    var body: some View {
        if settings.showsCalendar, widgets.calendarAccess == .denied {
            SettingsRow(
                title: "Calendar access is off",
                subtitle: "Turn on DockIt in System Settings › Privacy & Security › Calendars."
            ) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// Commits on Return or when the field loses focus, not per keystroke: every change to the setting
/// is a geocode and a forecast, and each half-typed name ("L", "Lo", "Lon"…) would fetch a real
/// place's weather and show it.
private struct WeatherLocationRow: View {
    @Bindable var settings: DockSettings
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @State private var hits: [WidgetsModel.City] = []
    @State private var searchTask: Task<Void, Never>?
    /// Set by a pick so its own write to the draft doesn't search for the city just chosen.
    @State private var isPicking = false

    var body: some View {
        Group {
            SettingsRow(title: "Weather location", subtitle: "Type to search for a city.") {
                TextField("City", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            }
            // Matches straight from the geocoder, so the pick pins exact coordinates — the search
            // is what disambiguates the world's many Springfields.
            ForEach(hits) { city in
                Button {
                    choose(city)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(city.label).font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsChrome.rowInset)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsRowDivider()
            }
        }
        .onAppear { draft = settings.weatherLocation }
        // Switching tabs mid-edit removes the field without a focus change.
        .onDisappear(perform: commit)
        // A change from elsewhere — sync, an import — shows, unless it would overwrite typing.
        .onChange(of: settings.weatherLocation) { _, location in
            if !isFocused { draft = location }
        }
        .onChange(of: draft) { _, text in
            searchTask?.cancel()
            let query = text.trimmingCharacters(in: .whitespaces)
            // Only typing searches: appear and sync write the draft unfocused, and a pick flags
            // its own write. Not "differs from the saved name" — retyping the saved city to pin it
            // is exactly when the list is needed.
            let isPick = isPicking
            isPicking = false
            guard isFocused, !isPick, query.count >= 2 else {
                hits = []
                return
            }
            searchTask = Task {
                // Debounced: two keystrokes in 300 ms cost one request.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let found = await WidgetsModel.searchCities(query)
                guard !Task.isCancelled else { return }
                hits = found
            }
        }
    }

    private func choose(_ city: WidgetsModel.City) {
        searchTask?.cancel()
        hits = []
        // Only when the draft will change; otherwise no onChange fires to clear the flag.
        isPicking = draft != city.placeName
        draft = city.placeName
        settings.weatherLocation = city.placeName
        settings.weatherLatitude = city.latitude
        settings.weatherLongitude = city.longitude
        isFocused = false
    }

    /// Return with no pick: the typed name stands, and clearing the pin sends it to the geocoder.
    private func commit() {
        searchTask?.cancel()
        hits = []
        guard draft != settings.weatherLocation else { return }
        settings.weatherLocation = draft
        settings.weatherLatitude = 0
        settings.weatherLongitude = 0
    }
}
