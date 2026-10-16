import AppKit
import MynahCore
import Sparkle

/// In-app updates via Sparkle.
///
/// The release workflow signs each DMG with the EdDSA key whose public half is
/// `SUPublicEDKey` in Info.plist, and adds it to the appcast on the `appcast`
/// branch (`SUFeedURL`). Pre-releases are tagged with the "beta" channel, which
/// this Mac only sees with "Beta versions" on.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// Sparkle needs a real app bundle; `swift run` and UI previews get a no-op updater.
    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && ProcessInfo.processInfo.environment["MYNAH_UI_PREVIEW"] == nil
    }

    nonisolated private static let betaKey = "MynahBetaUpdates"

    /// Postpones the relaunch while this is true (a meeting is being recorded).
    var isBusy: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController?
    private var postponeTimer: Timer?

    override init() {
        super.init()
        // Beta builds follow betas by default; stable builds follow stable releases.
        UserDefaults.standard.register(defaults: [Self.betaKey: Self.currentVersion.contains("-")])
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        guard Self.available else { return }
        controller?.startUpdater()
    }

    var canCheck: Bool { Self.available && controller?.updater.canCheckForUpdates == true }

    func checkForUpdates() {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var includeBetas: Bool {
        get { UserDefaults.standard.bool(forKey: Self.betaKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.betaKey)
            controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func versionComparator(for updater: SPUUpdater) -> (any SUVersionComparison)? {
        SemanticVersionComparator()
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaKey) ? ["beta"] : []
    }

    /// Don't quit mid-meeting: install once the recording has stopped.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard isBusy() else { return false }
            postponeTimer?.invalidate()
            postponeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard self?.isBusy() != true else { return }
                    timer.invalidate()
                    installHandler()
                }
            }
            return true
        }
    }
}

/// Mynah is a menu bar app, so a background check would otherwise put its
/// update window behind whatever the user is doing.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Appcast versions are release tags (0.2.0-beta.3), compared as semantic versions.
private final class SemanticVersionComparator: NSObject, SUVersionComparison {
    func compareVersion(_ versionA: String, toVersion versionB: String) -> ComparisonResult {
        SemanticVersion.compare(versionA, versionB)
    }
}
