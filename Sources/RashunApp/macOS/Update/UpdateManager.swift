import Cocoa
import RashunCore

@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let repo = "alexanderheffernan/rashun"
    private let updateService: UpdateCheckService
    private let installer: any UpdateInstaller

    // Internal test seams for deterministic unit testing.
    var dueCheckRunner: ((Bool) async -> Bool)?
    var autoUpdateCheckEnabledOverride: Bool?

    private(set) var isInstalling = false

    private init(
        updateService: UpdateCheckService? = nil,
        installer: (any UpdateInstaller)? = nil
    ) {
        self.updateService = updateService ?? UpdateCheckService(
            repository: repo,
            currentVersionProvider: {
                Versioning.versionString(bundle: .main)
            }
        )
        self.installer = installer ?? MacOSShellUpdateInstaller()
    }

    var nowProvider: () -> Date {
        get { updateService.nowProvider }
        set { updateService.nowProvider = newValue }
    }

    var availableVersion: String? {
        updateService.availableVersion
    }

    var isChecking: Bool {
        updateService.isChecking
    }

    var checkIntervalSecondsForTesting: TimeInterval {
        updateService.checkIntervalSeconds
    }

    /// Current app version from the bundle's Info.plist.
    var currentVersion: String {
        Versioning.versionString(bundle: .main)
    }

    /// Whether an update is available and newer than the current version.
    var updateAvailable: Bool {
        updateService.updateAvailable
    }

    /// Start update checks and perform an immediate check if enabled.
    func startPeriodicChecks() {
        guard autoUpdateChecksEnabled else { return }
        updateService.resetDueWindow()
        Task { await checkForUpdate(notify: true) }
        updateService.markCheckedNow()
    }

    func stopPeriodicChecks() {
        updateService.resetDueWindow()
    }

    /// Called from the main poll cycle; checks for updates only when the interval has elapsed.
    @discardableResult
    func checkForUpdateIfDue(notify: Bool = true) async -> Bool {
        guard autoUpdateChecksEnabled else { return false }
        guard updateService.reserveDueCheck() else {
            return false
        }

        if let dueCheckRunner {
            return await dueCheckRunner(notify)
        }
        return await checkForUpdate(notify: notify)
    }

    func resetTestingState() {
        updateService.nowProvider = Date.init
        dueCheckRunner = nil
        autoUpdateCheckEnabledOverride = nil
        updateService.resetDueWindow()
    }

    /// Check GitHub for the latest release. If `notify` is true, sends a macOS notification when a new version is found.
    @discardableResult
    func checkForUpdate(notify: Bool = false) async -> Bool {
        NotificationCenter.default.post(name: .updateStatusChanged, object: nil)
        defer { NotificationCenter.default.post(name: .updateStatusChanged, object: nil) }

        let isNew = await updateService.checkForUpdate()
        if isNew && notify {
            let version = availableVersion ?? "new"
            NotificationManager.shared.sendNotification(
                title: "Rashun Update Available",
                body: "Version \(version) is available. You're on \(currentVersion). Open Settings to install.",
                route: .preferencesUpdates
            )
        }
        return isNew
    }

    /// Download and install the update by running install.sh, then relaunch.
    func installUpdate() {
        guard updateAvailable, !isInstalling else { return }
        isInstalling = true
        NotificationCenter.default.post(name: .updateStatusChanged, object: nil)

        do {
            try installer.installUpdate(from: repo)
        } catch {
            isInstalling = false
            NotificationCenter.default.post(name: .updateStatusChanged, object: nil)
            return
        }

        // The install script will quit this app and reopen the new version.
        // Give it a moment, then quit ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Private

    private var autoUpdateChecksEnabled: Bool {
        autoUpdateCheckEnabledOverride ?? SettingsStore.shared.autoUpdateCheckEnabled
    }
}

@MainActor
struct MacOSShellUpdateInstaller: UpdateInstaller {
    func installUpdate(from repository: String) throws {
        let installURL = "https://raw.githubusercontent.com/\(repository)/main/install.sh"
        let script = """
        curl -fsSL \(installURL) | bash -s -- --update
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.qualityOfService = .userInitiated
        try process.run()
    }
}
