import Foundation

public struct SourceHealthRecord: Codable {
    public var lastSuccessfulUsage: UsageResult?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var consecutiveFailures: Int
    public var shortErrorMessage: String?
    public var detailedErrorMessage: String?

    public init(
        lastSuccessfulUsage: UsageResult? = nil,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        consecutiveFailures: Int = 0,
        shortErrorMessage: String? = nil,
        detailedErrorMessage: String? = nil
    ) {
        self.lastSuccessfulUsage = lastSuccessfulUsage
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.consecutiveFailures = consecutiveFailures
        self.shortErrorMessage = shortErrorMessage
        self.detailedErrorMessage = detailedErrorMessage
    }
}

@MainActor
public final class SourceHealthStore {
    public static let shared = SourceHealthStore()

    private let userDefaultsKey = "ai.sourceHealth.v1"
    private var recordsBySource: [String: SourceHealthRecord] = [:]

    private init() {
        load()
    }

    private func scopedName(sourceName: String, metricId: String?) -> String {
        guard let metricId else { return sourceName }
        return "\(sourceName)::\(metricId)"
    }

    public func recordSuccess(sourceName: String, metricId: String, usage: UsageResult) {
        recordSuccess(sourceName: scopedName(sourceName: sourceName, metricId: metricId), usage: usage)
    }

    public func recordSuccess(sourceName: String, usage: UsageResult) {
        var record = recordsBySource[sourceName] ?? SourceHealthRecord()
        record.lastSuccessfulUsage = usage
        record.lastSuccessAt = Date()
        record.consecutiveFailures = 0
        record.shortErrorMessage = nil
        record.detailedErrorMessage = nil
        recordsBySource[sourceName] = record
        persistAndNotify()
    }

    public func recordFailure(sourceName: String, metricId: String, presentation: SourceFetchErrorPresentation) {
        recordFailure(sourceName: scopedName(sourceName: sourceName, metricId: metricId), presentation: presentation)
    }

    public func recordFailure(sourceName: String, presentation: SourceFetchErrorPresentation) {
        var record = recordsBySource[sourceName] ?? SourceHealthRecord()
        record.lastFailureAt = Date()
        record.consecutiveFailures += 1
        record.shortErrorMessage = presentation.shortMessage
        record.detailedErrorMessage = presentation.detailedMessage
        recordsBySource[sourceName] = record
        persistAndNotify()
    }

    public func health(for sourceName: String) -> SourceHealthRecord? {
        recordsBySource[sourceName]
    }

    public func health(for sourceName: String, metricId: String) -> SourceHealthRecord? {
        recordsBySource[scopedName(sourceName: sourceName, metricId: metricId)]
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: SourceHealthRecord].self, from: data) else {
            return
        }
        recordsBySource = decoded
    }

    private func persistAndNotify() {
        if let data = try? JSONEncoder().encode(recordsBySource) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        NotificationCenter.default.post(name: .aiSourceHealthChanged, object: nil)
    }
}
