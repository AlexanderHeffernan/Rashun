import Foundation
import RashunCore

struct SourceHealthRecord: Codable {
    var lastSuccessfulUsage: UsageResult?
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var consecutiveFailures: Int
    var shortErrorMessage: String?
    var detailedErrorMessage: String?
}

@MainActor
final class SourceHealthStore {
    static let shared = SourceHealthStore()

    private let userDefaultsKey = "ai.sourceHealth.v1"
    private var recordsBySource: [String: SourceHealthRecord] = [:]

    private init() {
        load()
    }

    private func scopedName(sourceName: String, metricId: String?) -> String {
        guard let metricId else { return sourceName }
        return "\(sourceName)::\(metricId)"
    }

    func recordSuccess(sourceName: String, metricId: String, usage: UsageResult) {
        recordSuccess(sourceName: scopedName(sourceName: sourceName, metricId: metricId), usage: usage)
    }

    func recordSuccess(sourceName: String, usage: UsageResult) {
        var record = recordsBySource[sourceName] ?? SourceHealthRecord(
            lastSuccessfulUsage: nil,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            consecutiveFailures: 0,
            shortErrorMessage: nil,
            detailedErrorMessage: nil
        )
        record.lastSuccessfulUsage = usage
        record.lastSuccessAt = Date()
        record.consecutiveFailures = 0
        record.shortErrorMessage = nil
        record.detailedErrorMessage = nil
        recordsBySource[sourceName] = record
        persistAndNotify()
    }

    func recordFailure(sourceName: String, metricId: String, presentation: SourceFetchErrorPresentation) {
        recordFailure(sourceName: scopedName(sourceName: sourceName, metricId: metricId), presentation: presentation)
    }

    func recordFailure(sourceName: String, presentation: SourceFetchErrorPresentation) {
        var record = recordsBySource[sourceName] ?? SourceHealthRecord(
            lastSuccessfulUsage: nil,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            consecutiveFailures: 0,
            shortErrorMessage: nil,
            detailedErrorMessage: nil
        )
        record.lastFailureAt = Date()
        record.consecutiveFailures += 1
        record.shortErrorMessage = presentation.shortMessage
        record.detailedErrorMessage = presentation.detailedMessage
        recordsBySource[sourceName] = record
        persistAndNotify()
    }

    func health(for sourceName: String) -> SourceHealthRecord? {
        recordsBySource[sourceName]
    }

    func health(for sourceName: String, metricId: String) -> SourceHealthRecord? {
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

extension Notification.Name {
    static let aiSourceHealthChanged = Notification.Name("ai.sourceHealth.changed")
}
