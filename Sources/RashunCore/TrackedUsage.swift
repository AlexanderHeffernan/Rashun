import Foundation

public struct TrackingLabel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(id: UUID = UUID(), name: String, colorHex: String = "#7C5CFC", createdAt: Date = Date(), updatedAt: Date = Date(), archivedAt: Date? = nil) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.createdAt = createdAt; self.updatedAt = updatedAt; self.archivedAt = archivedAt
    }
}

public enum TrackedUsageObservationOrigin: String, Codable, Sendable { case start, poll, stop, recovery }
public enum TrackedSessionCompletionState: String, Codable, Sendable { case active, completed, interrupted }

public struct TrackedUsageObservation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var sourceName: String
    public var metricID: String
    public var metricTitle: String
    public var remaining: Double
    public var limit: Double
    public var resetDate: Date?
    public var cycleStartDate: Date?
    public var origin: TrackedUsageObservationOrigin

    public init(id: UUID = UUID(), timestamp: Date = Date(), sourceName: String, metricID: String, metricTitle: String, remaining: Double, limit: Double, resetDate: Date? = nil, cycleStartDate: Date? = nil, origin: TrackedUsageObservationOrigin) {
        self.id = id; self.timestamp = timestamp; self.sourceName = sourceName; self.metricID = metricID; self.metricTitle = metricTitle; self.remaining = remaining; self.limit = limit; self.resetDate = resetDate; self.cycleStartDate = cycleStartDate; self.origin = origin
    }

    public var usage: UsageResult { UsageResult(remaining: remaining, limit: limit, resetDate: resetDate, cycleStartDate: cycleStartDate) }
}

public struct TrackedSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var labelID: UUID
    public var labelNameSnapshot: String
    public var startedAt: Date
    public var endedAt: Date?
    public var observations: [TrackedUsageObservation]
    public var completionState: TrackedSessionCompletionState
    public var interruptionNote: String?

    public init(id: UUID = UUID(), labelID: UUID, labelNameSnapshot: String, startedAt: Date = Date(), endedAt: Date? = nil, observations: [TrackedUsageObservation] = [], completionState: TrackedSessionCompletionState = .active, interruptionNote: String? = nil) {
        self.id = id; self.labelID = labelID; self.labelNameSnapshot = labelNameSnapshot; self.startedAt = startedAt; self.endedAt = endedAt; self.observations = observations; self.completionState = completionState; self.interruptionNote = interruptionNote
    }
}

public struct TrackedUsageSegment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let cycleStartDate: Date?
    public let observations: [TrackedUsageObservation]
    public let consumedNativeUnits: Double
    public let percentagePointsConsumed: Double
}

public struct TrackedMetricUsage: Identifiable, Hashable, Sendable {
    public var id: String { "\(sourceName)::\(metricID)" }
    public let sourceName: String
    public let metricID: String
    public let metricTitle: String
    public let totalConsumedNativeUnits: Double
    public let percentagePointsConsumed: Double
    public let segments: [TrackedUsageSegment]
    public let observationCount: Int
    public let isComplete: Bool
    public let warnings: [String]
}

public enum TrackedUsageAttributionEngine {
    public static func results(for session: TrackedSession) -> [TrackedMetricUsage] {
        let grouped = Dictionary(grouping: session.observations, by: { "\($0.sourceName)::\($0.metricID)" })
        return grouped.values.compactMap(result).filter { $0.totalConsumedNativeUnits > 0 }.sorted { $0.id < $1.id }
    }

    public static func result(observations raw: [TrackedUsageObservation]) -> TrackedMetricUsage? {
        let observations = raw.sorted { $0.timestamp < $1.timestamp }
        guard let first = observations.first else { return nil }
        var segments: [[TrackedUsageObservation]] = [[]]
        var warnings: [String] = []
        var previous: TrackedUsageObservation?
        var consumed = 0.0

        for observation in observations {
            defer { previous = observation }
            guard let prior = previous else { segments[segments.count - 1].append(observation); continue }
            if sameReading(prior, observation) { continue }
            if isNewCycle(from: prior, to: observation) {
                segments.append([observation])
                continue
            }
            segments[segments.count - 1].append(observation)
            let delta = prior.remaining - observation.remaining
            if delta > 0 { consumed += delta }
            // Regeneration is deliberately a new local baseline, never negative consumption.
        }
        if first.origin != .start { warnings.append("Incomplete observation: no start reading.") }
        if sessionBoundaryMissing(observations) { warnings.append("Incomplete observation: no stop reading.") }
        let builtSegments = segments.filter { !$0.isEmpty }.map { segment -> TrackedUsageSegment in
            var segmentConsumed = 0.0
            for pair in zip(segment, segment.dropFirst()) { segmentConsumed += max(pair.0.remaining - pair.1.remaining, 0) }
            let normalized = zip(segment, segment.dropFirst()).reduce(0.0) { total, pair in
                guard pair.0.limit > 0 else { return total }
                return total + max((pair.0.remaining - pair.1.remaining) / pair.0.limit * 100, 0)
            }
            return TrackedUsageSegment(id: UUID(), cycleStartDate: segment.first?.cycleStartDate, observations: segment, consumedNativeUnits: segmentConsumed, percentagePointsConsumed: normalized)
        }
        let percentage = builtSegments.reduce(0) { $0 + $1.percentagePointsConsumed }
        return TrackedMetricUsage(sourceName: first.sourceName, metricID: first.metricID, metricTitle: first.metricTitle, totalConsumedNativeUnits: consumed, percentagePointsConsumed: percentage, segments: builtSegments, observationCount: observations.count, isComplete: warnings.isEmpty, warnings: warnings)
    }

    private static func sameReading(_ a: TrackedUsageObservation, _ b: TrackedUsageObservation) -> Bool {
        a.remaining == b.remaining && a.limit == b.limit && a.resetDate == b.resetDate && a.cycleStartDate == b.cycleStartDate
    }
    private static func sessionBoundaryMissing(_ observations: [TrackedUsageObservation]) -> Bool { observations.last?.origin != .stop }
    private static func isNewCycle(from previous: TrackedUsageObservation, to current: TrackedUsageObservation) -> Bool {
        if let a = previous.cycleStartDate, let b = current.cycleStartDate, a != b { return true }
        if let a = previous.resetDate, let b = current.resetDate, b > a, current.remaining >= previous.remaining { return true }
        // A large near-full upward jump is only accepted as a reset if a cycle signal also agrees.
        return current.remaining - previous.remaining >= max(previous.limit * 0.2, 1) && current.remaining / max(current.limit, 1) >= 0.85 && ((current.resetDate != nil && current.resetDate != previous.resetDate) || current.cycleStartDate != nil)
    }
}

@MainActor
public final class TrackedUsageStore {
    public static let shared = TrackedUsageStore(backend: PersistenceBackendFactory.default())
    private static let storageKey = "trackedUsage.v1"
    private struct Payload: Codable { var schemaVersion: Int = 1; var labels: [TrackingLabel] = []; var sessions: [TrackedSession] = []; var activeSession: TrackedSession? }
    private let backend: PersistenceBackend
    private var payload: Payload

    public init(backend: PersistenceBackend) {
        self.backend = backend
        let decoded = backend.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        self.payload = (decoded?.schemaVersion ?? 1) <= 1 ? (decoded ?? Payload()) : Payload()
    }
    public var labels: [TrackingLabel] { payload.labels.sorted { $0.updatedAt > $1.updatedAt } }
    public var sessions: [TrackedSession] { payload.sessions.sorted { $0.startedAt > $1.startedAt } }
    public var activeSession: TrackedSession? { payload.activeSession }

    @discardableResult public func createLabel(name: String, colorHex: String = "#7C5CFC") -> TrackingLabel {
        let label = TrackingLabel(name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: colorHex); payload.labels.append(label); save(); return label
    }
    public func updateLabel(_ label: TrackingLabel) { guard let index = payload.labels.firstIndex(where: { $0.id == label.id }) else { return }; var updated = label; updated.updatedAt = Date(); payload.labels[index] = updated; save() }
    public func archiveLabel(id: UUID, archived: Bool = true) { guard let i = payload.labels.firstIndex(where: { $0.id == id }) else { return }; payload.labels[i].archivedAt = archived ? Date() : nil; payload.labels[i].updatedAt = Date(); save() }
    public func deleteLabelPermanently(id: UUID) { guard !payload.sessions.contains(where: { $0.labelID == id }) && payload.activeSession?.labelID != id else { return }; payload.labels.removeAll { $0.id == id }; save() }
    public func start(label: TrackingLabel, at date: Date = Date()) -> TrackedSession {
        if var active = payload.activeSession {
            finalize(&active, at: date, state: .interrupted, note: "Switched labels")
            payload.sessions.append(active)
        }
        let session = TrackedSession(labelID: label.id, labelNameSnapshot: label.name, startedAt: date)
        payload.activeSession = session
        save()
        return session
    }
    public func append(_ observation: TrackedUsageObservation) {
        append(contentsOf: [observation])
    }

    public func append(contentsOf observations: [TrackedUsageObservation]) {
        guard var session = payload.activeSession, !observations.isEmpty else { return }

        var latestByMetric: [String: TrackedUsageObservation] = [:]
        for existing in session.observations {
            latestByMetric[metricKey(for: existing)] = existing
        }

        var didAppend = false
        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = metricKey(for: observation)
            if let previous = latestByMetric[key], shouldCoalesce(previous, observation) {
                continue
            }
            session.observations.append(observation)
            latestByMetric[key] = observation
            didAppend = true
        }

        guard didAppend else { return }
        payload.activeSession = session
        save()
    }
    @discardableResult public func stop(at date: Date = Date()) -> TrackedSession? {
        guard var active = payload.activeSession else { return nil }
        finalize(&active, at: date, state: .completed, note: nil)
        payload.activeSession = nil
        guard !TrackedUsageAttributionEngine.results(for: active).isEmpty else { save(); return nil }
        payload.sessions.append(active)
        save()
        return active
    }
    public func replaceSession(_ session: TrackedSession) { guard let i = payload.sessions.firstIndex(where: { $0.id == session.id }) else { return }; payload.sessions[i] = session; save() }
    public func deleteSession(id: UUID) { payload.sessions.removeAll { $0.id == id }; save() }
    private func finalize(_ session: inout TrackedSession, at date: Date, state: TrackedSessionCompletionState, note: String?) { session.endedAt = date; session.completionState = state; session.interruptionNote = note }
    private func metricKey(for observation: TrackedUsageObservation) -> String { "\(observation.sourceName)::\(observation.metricID)" }
    private func shouldCoalesce(_ previous: TrackedUsageObservation, _ current: TrackedUsageObservation) -> Bool {
        guard current.origin == .poll || current.origin == .recovery else { return false }
        return previous.remaining == current.remaining &&
            previous.limit == current.limit &&
            previous.resetDate == current.resetDate &&
            previous.cycleStartDate == current.cycleStartDate
    }
    private func save() { if let data = try? JSONEncoder().encode(payload) { backend.set(data, forKey: Self.storageKey) } }
}
