import SwiftUI

struct WidgetsPane: View {
    @Bindable var settings: DockSettings

    var body: some View {
        SettingsPage(title: "Widgets", subtitle: "Add widgets and spacers to the dock, or take them off.") {
            SettingsSection(
                title: "Widgets", anchor: SettingsAnchor.widgets,
                footer: "Drag a widget into your dock, or click to add it; click again to take it off. Widgets sit at the end of the bar, beside the Trash, and show when the dock is at the bottom. Now playing asks macOS once for permission to control each player, and the calendar asks for access to your calendars."
            ) {
                WidgetGallery(settings: settings)
            }
            SettingsSection(title: "Options", anchor: SettingsAnchor.widgetOptions) {
                WeatherLocationRow(settings: settings)
                    .disabled(!settings.showsWeather)
                SettingsToggle(title: "Fahrenheit", isOn: $settings.weatherFahrenheit)
                    .disabled(!settings.showsWeather)
                // The calendar's times follow it too, so the two tiles never disagree.
                SettingsToggle(title: "24-hour time", isOn: $settings.clock24Hour)
                    .disabled(!settings.showsClock && !settings.showsCalendar)
                CalendarAccessRow(settings: settings)
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
}

/// Every widget drawn by the tile the bar itself uses, so what is picked is what lands. A card drags
/// the payload a tile on the bar drags — the bar's drop handling places it where it lands — or a
/// click switches it on and off in place.
private struct WidgetGallery: View {
    @Bindable var settings: DockSettings
    private let widgets = WidgetsModel.shared

    /// The tiles' height on the bar at the default icon size; the widths are the bar's, with now
    /// playing and the calendar narrowed to fit a card.
    private static let tileHeight: CGFloat = 48
    private static let cards: [(name: String, title: String, width: CGFloat)] = [
        ("nowPlaying", "Now Playing", 150), ("weather", "Weather", 128), ("clock", "Clock", 84),
        ("calendar", "Calendar", 150), ("battery", "Battery", 84),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 14) {
            // Not offered at all without a battery: the tile could never show.
            ForEach(Self.cards.filter { $0.name != "battery" || WidgetsModel.hasBattery }, id: \.name) {
                card($0.name, title: $0.title, width: $0.width)
            }
        }
        .padding(SettingsChrome.rowInset)
        .onAppear { widgets.isPreviewing = true }
        .onDisappear { widgets.isPreviewing = false }
    }

    private func card(_ name: String, title: String, width: CGFloat) -> some View {
        let isOn = DockSettings.widgetSwitches[name].map { settings[keyPath: $0] } ?? false
        return VStack(spacing: 8) {
            tile(name, width: width)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsChrome.cardFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isOn ? Color.accentColor : SettingsChrome.cardBorder,
                            lineWidth: isOn ? 1.5 : SettingsChrome.hairline))
                .overlay(alignment: .topTrailing) {
                    if isOn {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .padding(6)
                    }
                }
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .contentShape(Rectangle())
        // A tap gesture rather than a Button: a button takes the mouse-down, and the drag never starts.
        .onTapGesture { toggle(name, isOn: isOn) }
        // The drag image is the tile alone, as it will look on the bar — not the card around it.
        .onDrag { DockModel.dragPayload(forWidget: name) } preview: { tile(name, width: width) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "In the dock" : "Not in the dock")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle(name, isOn: isOn) }
    }

    /// The bar's own tile, inert: its clicks and menu belong to the bar, not to a preview.
    @ViewBuilder
    private func tile(_ name: String, width: CGFloat) -> some View {
        Group {
            switch name {
            case "nowPlaying": NowPlayingTile(width: width, height: Self.tileHeight)
            case "weather": WeatherTile(width: width, height: Self.tileHeight)
            case "clock": ClockTile(width: width, height: Self.tileHeight)
            case "calendar": CalendarTile(width: width, height: Self.tileHeight)
            case "battery": BatteryTile(width: width, height: Self.tileHeight)
            default: EmptyView()
            }
        }
        .allowsHitTesting(false)
    }

    private func toggle(_ name: String, isOn: Bool) {
        guard let key = DockSettings.widgetSwitches[name] else { return }
        if isOn {
            settings[keyPath: key] = false
        } else {
            widgets.add(name)
        }
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
