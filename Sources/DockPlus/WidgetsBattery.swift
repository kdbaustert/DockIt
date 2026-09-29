import Foundation
import IOKit.ps

/// One reading of the internal battery, as the tile shows it.
struct BatteryReading: Equatable, Sendable {
    let percent: Int
    let isCharging: Bool
    /// On the adapter, charging or not: a full battery, or one macOS is holding at 80% to spare it,
    /// is plugged in without charging.
    let isPluggedIn: Bool

    /// From a power source's IOKit description; nil when it carries no charge to show. Pure, for the
    /// tests.
    init?(description: [String: Any]) {
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
        else { return nil }
        self.init(
            percent: Int((Double(current) / Double(max) * 100).rounded()),
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
            isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }

    init(percent: Int, isCharging: Bool, isPluggedIn: Bool) {
        self.percent = min(max(percent, 0), 100)
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
    }

    /// The bolt while charging; otherwise the nearest of the quarter steps the symbol set has.
    var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        return "battery.\((percent + 12) / 25 * 25)percent"
    }

    var status: String {
        if isCharging { return "Charging" }
        return isPluggedIn ? "Plugged In" : "On Battery"
    }
}

extension WidgetsModel {
    // MARK: - Battery (IOKit power sources)
    //
    // Pushed, never polled: the power-source notification calls back on the main run loop whenever
    // any source changes. Measured on a MacBook on battery, it fired every 35–60 s — the time-remaining
    // estimate moving — against about every 95 s for the percentage alone, so most callbacks carry
    // nothing new; the reading is compared and the tile left alone unless it changed.

    /// Whether this Mac has an internal battery, asked once: a Mac does not grow one. A UPS is a
    /// power source too, and is not counted.
    nonisolated static let hasBattery = internalBattery() != nil

    /// One source for the life of the model, added and removed as the tile comes and goes. A new
    /// source per change leaked a Mach port each time, releasing it or not — 200 over 200 cycles,
    /// measured — and every visit to the Widgets pane made one; the same source re-added costs none.
    func configureBattery() {
        let main = CFRunLoopGetMain()
        guard settings.showsBattery || isPreviewing, Self.hasBattery else {
            if let batterySource { CFRunLoopRemoveSource(main, batterySource, .commonModes) }
            battery = nil
            return
        }
        if batterySource == nil {
            // A C callback cannot capture, so the model rides along as the context, unretained:
            // `shared` never goes, so the source cannot outlive it.
            let context = Unmanaged.passUnretained(self).toOpaque()
            batterySource = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<WidgetsModel>.fromOpaque(context).takeUnretainedValue().readBattery()
                }
            }, context)?.takeRetainedValue()
        }
        guard let batterySource else { return }
        // Adding a source already on the run loop does nothing.
        CFRunLoopAddSource(main, batterySource, .commonModes)
        readBattery()
    }

    private func readBattery() {
        let reading = Self.internalBattery().flatMap(BatteryReading.init(description:))
        if reading != battery { battery = reading }
    }

    private nonisolated static func internalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return description
        }
        return nil
    }
}
