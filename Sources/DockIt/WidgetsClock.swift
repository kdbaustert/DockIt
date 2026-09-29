import Foundation

extension WidgetsModel {
    func configureClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard settings.showsClock else { return }
        // New instances, not a new `dateFormat` on the old ones: the per-tick formatters these
        // replace picked up a new time zone or locale for free, and this keeps that without relying
        // on whether a long-lived formatter would follow either change on its own.
        clockTimeFormatter = DateFormatter()
        clockTimeFormatter.dateFormat = settings.clock24Hour ? "HH:mm" : "h:mm a"
        clockDateFormatter = DateFormatter()
        clockDateFormatter.dateFormat = "EEE MMM d"
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
        clockTime = clockTimeFormatter.string(from: .now)
        clockDate = clockDateFormatter.string(from: .now)
    }
}
