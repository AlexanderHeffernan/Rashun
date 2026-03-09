import Cocoa
import RashunCore

@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let repo = "alexanderheffernan/rashun"
    private let checkInterval: TimeInterval = 6 * 60 * 60 // 6 hours
    private var lastCheckAttemptDate: Date?

    // Internal test seams for deterministic unit testing.
    var nowProvider: () -> Date = Date.init
    var dueCheckRunner: ((Bool) async -> Bool)?
    var autoUpdateCheckEnabledOverride: Bool?

    private(set) var availableVersion: String?
    private(set) var isChecking = false
    private(set) var isInstalling = false

    private init() {}

    var checkIntervalSecondsForTesting: TimeInterval {
        checkInterval
    }

    /// Current app version from the bundle's Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Whether an update is available and newer than the current version.
    var updateAvailable: Bool {
        guard let available = availableVersion else { return false }
        return compareVersions(available, isNewerThan: currentVersion)
    }

    /// Start update checks and perform an immediate check if enabled.
    func startPeriodicChecks() {
        guard autoUpdateChecksEnabled else { return }
        lastCheckAttemptDate = nil
        Task { await checkForUpdate(notify: true) }
        lastCheckAttemptDate = nowProvider()
    }

    func stopPeriodicChecks() {
        lastCheckAttemptDate = nil
    }

    /// Called from the main poll cycle; checks for updates only when the interval has elapsed.
    @discardableResult
    func checkForUpdateIfDue(notify: Bool = true) async -> Bool {
        guard autoUpdateChecksEnabled else { return false }
        let now = nowProvider()
        if let lastCheckAttemptDate,
           now.timeIntervalSince(lastCheckAttemptDate) < checkInterval {
            return false
        }

        lastCheckAttemptDate = now
        if let dueCheckRunner {
            return await dueCheckRunner(notify)
        }
        return await checkForUpdate(notify: notify)
    }

    func resetTestingState() {
        nowProvider = Date.init
        dueCheckRunner = nil
        autoUpdateCheckEnabledOverride = nil
        lastCheckAttemptDate = nil
    }

    /// Check GitHub for the latest release. If `notify` is true, sends a macOS notification when a new version is found.
    @discardableResult
    func checkForUpdate(notify: Bool = false) async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer {
            isChecking = false
            NotificationCenter.default.post(name: .updateStatusChanged, object: nil)
        }

        NotificationCenter.default.post(name: .updateStatusChanged, object: nil)

        guard let version = await fetchLatestVersion() else { return false }
        availableVersion = version

        let isNew = compareVersions(version, isNewerThan: currentVersion)
        if isNew && notify {
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

        let installURL = "https://raw.githubusercontent.com/\(repo)/main/install.sh"
        let script = """
        curl -fsSL \(installURL) | bash -s -- --update
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.qualityOfService = .userInitiated

        do {
            try process.run()
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

    private func fetchLatestVersion() async -> String? {
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            return nil
        }

        // Tag is like "v0.1.2" — strip the "v" prefix
        return tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    private func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        isNewerVersion(a, than: b)
    }
}

extension Notification.Name {
    static let updateStatusChanged = Notification.Name("ai.update.statusChanged")
}

/// Compare two semantic version strings. Returns true if `a` is strictly newer than `b`.
func isNewerVersion(_ a: String, than b: String) -> Bool {
    let aParts = a.split(separator: ".").compactMap { Int($0) }
    let bParts = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(aParts.count, bParts.count) {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        if av > bv { return true }
        if av < bv { return false }
    }
    return false
}
