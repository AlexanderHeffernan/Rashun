import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol UpdateVersionFetching: Sendable {
    func fetchLatestVersion(for repository: String) async -> String?
}

public struct GitHubUpdateVersionFetcher: UpdateVersionFetching {
    public init() {}

    public func fetchLatestVersion(for repository: String) async -> String? {
        let urlString = "https://api.github.com/repos/\(repository)/releases/latest"
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

        return tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

public protocol UpdateInstaller {
    @MainActor
    func installUpdate(from repository: String) throws
}

@MainActor
public final class UpdateCheckService {
    private let repository: String
    private let checkInterval: TimeInterval
    private let currentVersionProvider: () -> String
    private let fetcher: any UpdateVersionFetching
    private var lastCheckAttemptDate: Date?

    public var nowProvider: () -> Date = Date.init
    public private(set) var availableVersion: String?
    public private(set) var isChecking = false

    public init(
        repository: String,
        checkInterval: TimeInterval = 6 * 60 * 60,
        currentVersionProvider: @escaping () -> String,
        fetcher: any UpdateVersionFetching = GitHubUpdateVersionFetcher()
    ) {
        self.repository = repository
        self.checkInterval = checkInterval
        self.currentVersionProvider = currentVersionProvider
        self.fetcher = fetcher
    }

    public var checkIntervalSeconds: TimeInterval {
        checkInterval
    }

    public var updateAvailable: Bool {
        guard let available = availableVersion else { return false }
        return isNewerVersion(available, than: currentVersionProvider())
    }

    public func reserveDueCheck() -> Bool {
        let now = nowProvider()
        if let lastCheckAttemptDate,
           now.timeIntervalSince(lastCheckAttemptDate) < checkInterval {
            return false
        }
        lastCheckAttemptDate = now
        return true
    }

    public func resetDueWindow() {
        lastCheckAttemptDate = nil
    }

    public func markCheckedNow() {
        lastCheckAttemptDate = nowProvider()
    }

    @discardableResult
    public func checkForUpdate() async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }

        guard let version = await fetcher.fetchLatestVersion(for: repository) else {
            return false
        }

        availableVersion = version
        return isNewerVersion(version, than: currentVersionProvider())
    }
}
