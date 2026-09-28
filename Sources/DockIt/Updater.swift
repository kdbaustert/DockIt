import Foundation
import Sparkle

/// Updates from GitHub Releases, through Sparkle: it downloads the new version, checks its EdDSA
/// signature against `SUPublicEDKey`, and replaces the app. Each archive is an asset of its release;
/// the feed is served by GitHub Pages — see `SUFeedURL` in Info.plist and release.sh.
enum Updater {
    /// Whether this build can update itself: a release carries both a feed and a public key.
    /// `build.sh` strips the feed from local builds, so a development copy never replaces itself.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }
}

/// Which of the feed's channels this copy accepts. Stable releases carry no channel and reach
/// everyone; betas carry "beta" and are offered only when the user has opted in.
///
/// The preference lives in `UserDefaults` rather than on a main-actor object because Sparkle asks
/// from its own thread, and `UserDefaults` is safe to read from any.
final class UpdateChannels: NSObject, SPUUpdaterDelegate {
    private static let betaKey = "ReceiveBetaUpdates"

    static var receivesBetas: Bool {
        get { UserDefaults.standard.bool(forKey: betaKey) }
        set { UserDefaults.standard.set(newValue, forKey: betaKey) }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.receivesBetas ? ["beta"] : []
    }

    /// Set just before Sparkle quits DockIt to relaunch the update. The quit it then sends must not
    /// stop on the Restore-the-Dock dialog: nobody asked to quit, and a cancel would abort the update.
    private(set) var isRelaunchingForUpdate = false

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        isRelaunchingForUpdate = true
    }
}
