import AppKit
import Observation

/// The data behind the bar's widget tiles. Each source runs only while its tile is on, and each
/// keeps its own cadence: the clock ticks, the weather ambles, now-playing waits for the players.
@MainActor
@Observable
final class WidgetsModel {
    static let shared = WidgetsModel(settings: .shared)

    // MARK: Clock
    private(set) var clockTime = ""
    private(set) var clockDate = ""

    // MARK: Weather
    private(set) var weatherTemperature: String?
    private(set) var weatherHighLow = ""
    private(set) var weatherSymbol = "cloud.fill"
    private(set) var weatherPlace = ""

    // MARK: Now playing
    private(set) var trackTitle: String?
    private(set) var trackArtist = ""
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// A running player DockIt is not allowed to ask, when no other answered. Denied looked exactly
    /// like nothing playing, which left no clue that a permission was the reason.
    private(set) var deniedPlayer: String?
    /// Which player answered last — where the controls go.
    private var player: String?
    @ObservationIgnored private var artworkURL: String?

    @ObservationIgnored private let settings: DockSettings
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var weatherTimer: Timer?
    @ObservationIgnored private var playerNotices: PlayerNotices?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    /// The one pending retry after a failed fetch. Held so a new configuration can cancel it, and
    /// so failures replace it rather than stacking one sleeper each.
    @ObservationIgnored private var weatherRetry: Task<Void, Never>?
    /// The location the shown reading belongs to — a failed fetch for a different one must not
    /// leave the old city's temperature standing in for it.
    @ObservationIgnored private var weatherReadingLocation: String?
    /// Set while a poll's osascript round trips are running; a notice arriving then waits for it
    /// rather than piling a second poll onto a player that is slow to answer.
    @ObservationIgnored private var isPollingPlayer = false
    /// A notice that landed mid-poll, which may carry a newer state than the one being read. Polled
    /// for once that poll ends: no timer comes along later to catch it.
    @ObservationIgnored private var needsPlayerRepoll = false

    init(settings: DockSettings) {
        self.settings = settings
        // One observation per source, each reading only its own settings: typing a weather location
        // must not re-poll the players or rebuild the clock's timer.
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.showsClock, settings.clock24Hour)
        } onChange: { [weak self] in
            self?.configureClock()
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.showsWeather, settings.weatherLocation, settings.weatherFahrenheit,
                 settings.weatherLatitude, settings.weatherLongitude)
        } onChange: { [weak self] in
            self?.configureWeather()
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = settings.showsNowPlaying
        } onChange: { [weak self] in
            self?.configurePlayer()
        }
        // The minute timer runs on a clock that stops during sleep, so after a wake it showed the
        // time the Mac went to sleep until it next fired — and then fired off the minute. A clock
        // or time zone change is the same problem without the sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureClock() }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configureClock() }
            }
        }
        configureClock()
        configureWeather()
        configurePlayer()
    }

    // MARK: - Clock

    private func configureClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard settings.showsClock else { return }
        tickClock()
        // Aligned to the next minute, then per minute — no seconds are shown.
        let timer = Timer(fire: Date.now.addingTimeInterval(60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)),
                          interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func tickClock() {
        let time = DateFormatter()
        time.dateFormat = settings.clock24Hour ? "HH:mm" : "h:mm a"
        clockTime = time.string(from: .now)
        let date = DateFormatter()
        date.dateFormat = "EEE MMM d"
        clockDate = date.string(from: .now)
    }

    // MARK: - Weather (Open-Meteo: keyless, and fine with a request every 15 minutes)

    private func configureWeather() {
        weatherTimer?.invalidate()
        weatherTimer = nil
        weatherTask?.cancel()
        weatherRetry?.cancel()
        weatherRetry = nil
        guard settings.showsWeather, !settings.weatherLocation.isEmpty else {
            // All of the reading: the temperature alone left the old city and its high and low.
            weatherTemperature = nil
            weatherPlace = ""
            weatherHighLow = ""
            weatherReadingLocation = nil
            return
        }
        refreshWeather()
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWeather() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        weatherTimer = timer
    }

    private func refreshWeather() {
        let place = settings.weatherLocation
        let fahrenheit = settings.weatherFahrenheit
        // Coordinates picked from the city search win over geocoding the typed name: the search
        // already disambiguated ("Springfield" names dozens of places).
        let pinned: Located? = settings.weatherLatitude != 0 || settings.weatherLongitude != 0
            ? Located(name: place, latitude: settings.weatherLatitude, longitude: settings.weatherLongitude)
            : nil
        weatherTask?.cancel()
        weatherTask = Task { [weak self] in
            // Not `??`: its right side is an autoclosure, which cannot await.
            let located: Located?
            if let pinned {
                located = pinned
            } else {
                located = await Self.geocode(place)
            }
            var current: Current?
            if let located {
                current = await Self.forecast(
                    latitude: located.latitude, longitude: located.longitude, fahrenheit: fahrenheit)
            }
            // A cancelled fetch was superseded or switched off; it neither shows nor retries.
            guard let self, !Task.isCancelled else { return }
            guard let located, let current else { return weatherFailed(for: place) }
            weatherReadingLocation = place
            weatherPlace = located.name
            weatherTemperature = "\(Int(current.temperature.rounded()))°"
            weatherHighLow = "↑\(Int(current.high.rounded())) ↓\(Int(current.low.rounded()))"
            weatherSymbol = Self.symbol(for: current.code)
        }
    }

    /// A reading for another location is wrong, not stale, so it goes; "--°" is honest. Then one
    /// retry a minute on: a transient failure at launch otherwise leaves "--°" a whole cycle. It
    /// fires only if nothing has changed or succeeded since.
    private func weatherFailed(for place: String) {
        if weatherReadingLocation != place {
            weatherReadingLocation = nil
            weatherTemperature = nil
            weatherPlace = ""
            weatherHighLow = ""
        }
        weatherRetry?.cancel()
        weatherRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, settings.showsWeather, settings.weatherLocation == place, weatherTemperature == nil
            else { return }
            weatherRetry = nil
            refreshWeather()
        }
    }

    private struct Located: Sendable { let name: String; let latitude: Double; let longitude: Double }

    /// One city-search hit, ready for a results list.
    struct City: Identifiable, Sendable {
        let name: String
        let region: String
        let country: String
        let latitude: Double
        let longitude: Double
        var id: String { "\(latitude),\(longitude)" }
        var label: String {
            [name, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        /// City and state — what the dock shows. The country only helps tell hits apart in the list.
        var placeName: String { Self.placeName(name, region: region, country: country) }

        nonisolated static func placeName(_ name: String, region: String, country: String) -> String {
            [name, region.isEmpty ? country : region].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// The geocoder's best matches for a partial name — what the Settings search list shows.
    nonisolated static func searchCities(_ query: String) async -> [City] {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "6")]
        guard let (data, _) = try? await URLSession.shared.data(from: parts.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }
        return results.compactMap { hit in
            guard let name = hit["name"] as? String,
                  let latitude = hit["latitude"] as? Double,
                  let longitude = hit["longitude"] as? Double
            else { return nil }
            return City(
                name: name, region: hit["admin1"] as? String ?? "",
                country: hit["country"] as? String ?? "", latitude: latitude, longitude: longitude)
        }
    }
    private struct Current: Sendable { let temperature: Double; let high: Double; let low: Double; let code: Int }

    private nonisolated static func geocode(_ place: String) async -> Located? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "1")]
        guard let (data, _) = try? await URLSession.shared.data(from: parts.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double
        else { return nil }
        let name = City.placeName(
            first["name"] as? String ?? place, region: first["admin1"] as? String ?? "",
            country: first["country"] as? String ?? "")
        return Located(name: name, latitude: latitude, longitude: longitude)
    }

    private nonisolated static func forecast(latitude: Double, longitude: Double, fahrenheit: Bool) async -> Current? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: parts.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let daily = json["daily"] as? [String: Any],
              let high = (daily["temperature_2m_max"] as? [Double])?.first,
              let low = (daily["temperature_2m_min"] as? [Double])?.first
        else { return nil }
        return Current(temperature: temperature, high: high, low: low,
                       code: current["weather_code"] as? Int ?? 0)
    }

    /// WMO weather codes, coarsely.
    private nonisolated static func symbol(for code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    // MARK: - Now playing (Spotify and Music, over AppleScript)
    //
    // AppleScript rather than the MediaRemote framework: MediaRemote needs an Apple-only
    // entitlement on current macOS, and DockFix ships a whole helper adapter to get around that.
    // The two players this Mac actually uses both script cleanly. First poll prompts for
    // Automation permission per player, which is expected.
    //
    // Polled when a player says something changed, not on a timer. A 3 s timer launched osascript
    // up to twice per beat, forever, and every launch registered as an app — so the dock rebuilt
    // for each one's start and exit too. Measured, that was nearly all of DockIt's idle work.

    /// The players asked, in order, with the bundle ids that tell whether each is running.
    private static let players = [(name: "Spotify", bundleID: "com.spotify.client"),
                                  (name: "Music", bundleID: "com.apple.Music")]

    private func configurePlayer() {
        guard settings.showsNowPlaying else {
            playerNotices = nil
            trackTitle = nil
            deniedPlayer = nil
            clearArtwork()
            return
        }
        playerNotices = PlayerNotices(bundleIDs: Set(Self.players.map(\.bundleID))) { [weak self] in
            self?.pollPlayer()
        }
        pollPlayer()
    }

    private static let separator = "␟"

    private func pollPlayer() {
        guard settings.showsNowPlaying else { return }
        if isPollingPlayer {
            needsPlayerRepoll = true
            return
        }
        isPollingPlayer = true
        // Only players that are running: osascript for one that is not costs a process launch to
        // learn nothing.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let apps = Self.players.filter { running.contains($0.bundleID) }.map(\.name)
        Task { [weak self] in
            // A playing player beats a paused one: Music left paused must not hide Spotify playing.
            // A paused one shows only when nothing plays, and the first playing one ends the search.
            var shown: (app: String, parts: [String])?
            var denied: String?
            for app in apps {
                // The timeout bounds each Apple event a busy player sits on; the process kill in
                // runAppleScript backs it up should osascript hang anyway.
                let script = """
                    with timeout of 3 seconds
                        if application "\(app)" is running then
                            tell application "\(app)"
                                if player state is not stopped then
                                    try
                                        return (player state as string) & "\(Self.separator)" & \
                                            name of current track & "\(Self.separator)" & \
                                            artist of current track & "\(Self.separator)" & \
                                            \(app == "Spotify" ? "artwork url of current track" : "\"\"")
                                    end try
                                end if
                            end tell
                        end if
                    end timeout
                    """
                let output: String
                switch await Self.runAppleScript(script) {
                case .output(let text) where !text.isEmpty: output = text
                case .denied: denied = denied ?? app; continue
                default: continue
                }
                let parts = output.components(separatedBy: Self.separator)
                guard parts.count >= 3 else { continue }
                if shown == nil || parts[0] == "playing" { shown = (app, parts) }
                if parts[0] == "playing" { break }
            }
            guard let self else { return }
            defer {
                isPollingPlayer = false
                if needsPlayerRepoll {
                    needsPlayerRepoll = false
                    pollPlayer()
                }
            }
            // Switched off while the poll ran: configurePlayer has already cleared the tile.
            guard settings.showsNowPlaying else { return }
            deniedPlayer = shown == nil ? denied : nil
            guard let shown else {
                trackTitle = nil
                clearArtwork()
                player = nil
                return
            }
            player = shown.app
            isPlaying = shown.parts[0] == "playing"
            trackTitle = shown.parts[1]
            trackArtist = shown.parts[2]
            await loadArtwork(shown.parts.count > 3 ? shown.parts[3] : "")
        }
    }

    /// With the remembered URL: otherwise the same track coming back would match it and skip the
    /// download, leaving the tile with no artwork.
    private func clearArtwork() {
        artwork = nil
        artworkURL = nil
    }

    private func loadArtwork(_ url: String) async {
        guard url != artworkURL else { return }
        artworkURL = url
        guard let remote = URL(string: url), !url.isEmpty else {
            artwork = nil
            return
        }
        // A failed download clears rather than keeping the previous track's cover under this one —
        // URL included, so the next poll tries the download again.
        guard let (data, _) = try? await URLSession.shared.data(from: remote) else {
            if artworkURL == url { clearArtwork() }
            return
        }
        if artworkURL == url { artwork = NSImage(data: data) }
    }

    func playPause() { control("playpause") }
    func nextTrack() { control("next track") }
    func previousTrack() { control("previous track") }

    private func control(_ command: String) {
        guard let player else { return }
        let script = "tell application \"\(player)\" to \(command)"
        Task {
            _ = await Self.runAppleScript(script)
            // Not left to the player's notice alone: the tile answers even if none comes.
            try? await Task.sleep(for: .milliseconds(300))
            pollPlayer()
        }
    }

    enum AppleScriptResult: Sendable {
        case output(String)
        /// Automation permission refused (-1743).
        case denied
        case failed
    }

    /// osascript in a subprocess: NSAppleScript on the main thread can beachball on a busy player.
    private nonisolated static func runAppleScript(_ source: String) async -> AppleScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                // Killed if still running after 5 s: a player wedged past the script's own timeout
                // would otherwise hold this thread, and the poll with it, indefinitely.
                let kill = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: kill)
                    process.waitUntilExit()
                    kill.cancel()
                } catch {
                    continuation.resume(returning: .failed)
                    return
                }
                guard process.terminationStatus == 0 else {
                    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: message.contains("-1743") ? .denied : .failed)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: .output(text ?? ""))
            }
        }
    }
}

/// The players' own change notices, plus their quitting, which neither reliably announces.
///
/// The selector API because it is the only one that takes a suspension behavior: AppKit suspends
/// distributed delivery while an app is inactive, and DockIt is never the active app, so the
/// block API's coalescing default would hold every notice until Settings happened to be open.
@MainActor
private final class PlayerNotices: NSObject {
    private let bundleIDs: Set<String>
    private let onChange: @MainActor () -> Void

    init(bundleIDs: Set<String>, onChange: @escaping @MainActor () -> Void) {
        self.bundleIDs = bundleIDs
        self.onChange = onChange
        super.init()
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            distributed.addObserver(
                self, selector: #selector(playerChanged), name: .init(name), object: nil,
                suspensionBehavior: .deliverImmediately)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification,
            object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func playerChanged(_ note: Notification) {
        onChange()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let id = app?.bundleIdentifier, bundleIDs.contains(id) { onChange() }
    }
}
