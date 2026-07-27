import Foundation

public struct TrackingLabel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(), name: String, colorHex: String = "#7C5CFC", createdAt: Date = Date(),
        updatedAt: Date = Date(), archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

public enum TrackedUsageObservationOrigin: String, Codable, Sendable {
    case start, poll, stop, recovery
}
public enum TrackedSessionCompletionState: String, Codable, Sendable {
    case active, completed, interrupted
}

public enum TrackedUsageCommandError: Error, Equatable, LocalizedError {
    case labelNotFound(String)
    case ambiguousLabel(String)
    case sessionAlreadyActive(String)
    case noActiveSession

    public var errorDescription: String? {
        switch self {
        case .labelNotFound(let label): "No existing tracking label matches '\(label)'."
        case .ambiguousLabel(let label):
            "More than one active tracking label matches '\(label)'. Use its UUID instead."
        case .sessionAlreadyActive(let label):
            "A tracking session is already active for '\(label)'."
        case .noActiveSession: "No tracking session is active."
        }
    }
}

public enum TrackedUsageStoreError: Error, Equatable, LocalizedError {
    case invalidPayload
    case unsupportedSchema(Int)
    case emptyLabelName
    case duplicateActiveLabelName(String)
    case invalidObservation

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "Stored tracking data is malformed and was left unchanged."
        case .unsupportedSchema(let version):
            "Stored tracking data uses unsupported schema version \(version) and was left unchanged."
        case .emptyLabelName:
            "Tracking label names cannot be empty."
        case .duplicateActiveLabelName(let name):
            "An active tracking label named '\(name)' already exists."
        case .invalidObservation:
            "Tracking observations must contain finite remaining and limit values."
        }
    }
}

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

    public init(
        id: UUID = UUID(), timestamp: Date = Date(), sourceName: String, metricID: String,
        metricTitle: String, remaining: Double, limit: Double, resetDate: Date? = nil,
        cycleStartDate: Date? = nil, origin: TrackedUsageObservationOrigin
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceName = sourceName
        self.metricID = metricID
        self.metricTitle = metricTitle
        self.remaining = remaining
        self.limit = limit
        self.resetDate = resetDate
        self.cycleStartDate = cycleStartDate
        self.origin = origin
    }

    public var usage: UsageResult {
        UsageResult(
            remaining: remaining, limit: limit, resetDate: resetDate, cycleStartDate: cycleStartDate
        )
    }
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
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), labelID: UUID, labelNameSnapshot: String, startedAt: Date = Date(),
        endedAt: Date? = nil, observations: [TrackedUsageObservation] = [],
        completionState: TrackedSessionCompletionState = .active, interruptionNote: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.labelID = labelID
        self.labelNameSnapshot = labelNameSnapshot
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.observations = observations
        self.completionState = completionState
        self.interruptionNote = interruptionNote
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, labelID, labelNameSnapshot, startedAt, endedAt, observations, completionState,
            interruptionNote, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        labelID = try values.decode(UUID.self, forKey: .labelID)
        labelNameSnapshot = try values.decode(String.self, forKey: .labelNameSnapshot)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        observations = try values.decode([TrackedUsageObservation].self, forKey: .observations)
        completionState = try values.decode(
            TrackedSessionCompletionState.self, forKey: .completionState)
        interruptionNote = try values.decodeIfPresent(String.self, forKey: .interruptionNote)
        updatedAt =
            try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? endedAt ?? startedAt
    }
}

public struct TrackedUsageTombstone: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let deletedAt: Date
    public init(id: UUID, deletedAt: Date = Date()) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

public struct TrackedUsageSyncSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let labels: [TrackingLabel]
    public let sessions: [TrackedSession]
    public let deletedLabels: [TrackedUsageTombstone]
    public let deletedSessions: [TrackedUsageTombstone]
    public init(
        schemaVersion: Int = 1, labels: [TrackingLabel], sessions: [TrackedSession],
        deletedLabels: [TrackedUsageTombstone], deletedSessions: [TrackedUsageTombstone]
    ) {
        self.schemaVersion = schemaVersion
        self.labels = labels
        self.sessions = sessions
        self.deletedLabels = deletedLabels
        self.deletedSessions = deletedSessions
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
        let grouped = Dictionary(
            grouping: session.observations, by: { "\($0.sourceName)::\($0.metricID)" })
        return grouped.values.compactMap(result).filter { $0.totalConsumedNativeUnits > 0 }.sorted {
            $0.id < $1.id
        }
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
            guard let prior = previous else {
                segments[segments.count - 1].append(observation)
                continue
            }
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
        if sessionBoundaryMissing(observations) {
            warnings.append("Incomplete observation: no stop reading.")
        }
        let builtSegments = segments.filter { !$0.isEmpty }.map { segment -> TrackedUsageSegment in
            var segmentConsumed = 0.0
            for pair in zip(segment, segment.dropFirst()) {
                segmentConsumed += max(pair.0.remaining - pair.1.remaining, 0)
            }
            let normalized = zip(segment, segment.dropFirst()).reduce(0.0) { total, pair in
                guard pair.0.limit > 0 else { return total }
                return total + max((pair.0.remaining - pair.1.remaining) / pair.0.limit * 100, 0)
            }
            return TrackedUsageSegment(
                id: UUID(), cycleStartDate: segment.first?.cycleStartDate, observations: segment,
                consumedNativeUnits: segmentConsumed, percentagePointsConsumed: normalized)
        }
        let percentage = builtSegments.reduce(0) { $0 + $1.percentagePointsConsumed }
        return TrackedMetricUsage(
            sourceName: first.sourceName, metricID: first.metricID, metricTitle: first.metricTitle,
            totalConsumedNativeUnits: consumed, percentagePointsConsumed: percentage,
            segments: builtSegments, observationCount: observations.count,
            isComplete: warnings.isEmpty, warnings: warnings)
    }

    private static func sameReading(_ a: TrackedUsageObservation, _ b: TrackedUsageObservation)
        -> Bool
    {
        a.remaining == b.remaining && a.limit == b.limit && a.resetDate == b.resetDate
            && a.cycleStartDate == b.cycleStartDate
    }
    private static func sessionBoundaryMissing(_ observations: [TrackedUsageObservation]) -> Bool {
        observations.last?.origin != .stop
    }
    private static func isNewCycle(
        from previous: TrackedUsageObservation, to current: TrackedUsageObservation
    ) -> Bool {
        if let a = previous.cycleStartDate, let b = current.cycleStartDate, a != b { return true }
        if let a = previous.resetDate, let b = current.resetDate, b > a,
            current.remaining >= previous.remaining
        {
            return true
        }
        // A large near-full upward jump is only accepted as a reset if a cycle signal also agrees.
        return current.remaining - previous.remaining >= max(previous.limit * 0.2, 1)
            && current.remaining / max(current.limit, 1) >= 0.85
            && ((current.resetDate != nil && current.resetDate != previous.resetDate)
                || current.cycleStartDate != nil)
    }
}

@MainActor
public final class TrackedUsageStore {
    public static let shared = TrackedUsageStore(backend: PersistenceBackendFactory.default())
    private static let storageKey = "trackedUsage.v1"
    private struct Payload: Codable {
        var schemaVersion: Int = 2
        var labels: [TrackingLabel] = []
        var sessions: [TrackedSession] = []
        var activeSession: TrackedSession?
        var deletedLabels: [TrackedUsageTombstone] = []
        var deletedSessions: [TrackedUsageTombstone] = []
        private enum CodingKeys: String, CodingKey {
            case schemaVersion, labels, sessions, activeSession, deletedLabels, deletedSessions
        }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            labels = try values.decodeIfPresent([TrackingLabel].self, forKey: .labels) ?? []
            sessions = try values.decodeIfPresent([TrackedSession].self, forKey: .sessions) ?? []
            activeSession = try values.decodeIfPresent(TrackedSession.self, forKey: .activeSession)
            deletedLabels =
                try values.decodeIfPresent([TrackedUsageTombstone].self, forKey: .deletedLabels)
                ?? []
            deletedSessions =
                try values.decodeIfPresent([TrackedUsageTombstone].self, forKey: .deletedSessions)
                ?? []
        }
    }
    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
        private enum CodingKeys: String, CodingKey { case schemaVersion }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }
    private let backend: PersistenceBackend
    private var payload: Payload

    public init(backend: PersistenceBackend) {
        self.backend = backend
        self.payload = Payload()
    }

    public func readLabels() throws -> [TrackingLabel] {
        try refresh()
        return payload.labels.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func readSessions() throws -> [TrackedSession] {
        try refresh()
        return payload.sessions.sorted { $0.startedAt > $1.startedAt }
    }
    public func readActiveSession() throws -> TrackedSession? {
        try refresh()
        return payload.activeSession
    }

    @discardableResult public func createLabel(name: String, colorHex: String = "#7C5CFC") throws
        -> TrackingLabel
    {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw TrackedUsageStoreError.emptyLabelName }
        let label = TrackingLabel(
            name: normalizedName, colorHex: colorHex)
        return try transaction { payload in
            guard !hasActiveLabel(named: normalizedName, excluding: nil, in: payload.labels) else {
                throw TrackedUsageStoreError.duplicateActiveLabelName(normalizedName)
            }
            payload.labels.append(label)
            return label
        }
    }
    public func updateLabel(_ label: TrackingLabel) throws {
        let changed = try transaction { payload in
            guard let index = payload.labels.firstIndex(where: { $0.id == label.id }) else {
                return false
            }
            var updated = label
            updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.name.isEmpty else { throw TrackedUsageStoreError.emptyLabelName }
            if updated.archivedAt == nil,
                hasActiveLabel(named: updated.name, excluding: updated.id, in: payload.labels)
            {
                throw TrackedUsageStoreError.duplicateActiveLabelName(updated.name)
            }
            updated.updatedAt = Date()
            payload.labels[index] = updated
            for sessionIndex in payload.sessions.indices
            where payload.sessions[sessionIndex].labelID == updated.id {
                payload.sessions[sessionIndex].labelNameSnapshot = updated.name
            }
            if payload.activeSession?.labelID == updated.id {
                payload.activeSession?.labelNameSnapshot = updated.name
            }
            return true
        }
        if changed { NotificationCenter.default.post(name: .aiDataRefreshed, object: nil) }
    }
    public func archiveLabel(id: UUID, archived: Bool = true) throws {
        try transaction { payload in
            guard let i = payload.labels.firstIndex(where: { $0.id == id }) else { return }
            if !archived,
                hasActiveLabel(
                    named: payload.labels[i].name, excluding: id, in: payload.labels)
            {
                throw TrackedUsageStoreError.duplicateActiveLabelName(payload.labels[i].name)
            }
            payload.labels[i].archivedAt = archived ? Date() : nil
            payload.labels[i].updatedAt = Date()
        }
    }
    public func deleteLabelPermanently(id: UUID) throws {
        try transaction { payload in
            guard
                !payload.sessions.contains(where: { $0.labelID == id })
                    && payload.activeSession?.labelID != id
            else { return }
            payload.labels.removeAll { $0.id == id }
            upsertTombstone(id: id, in: &payload.deletedLabels)
        }
    }
    public func start(label: TrackingLabel, at date: Date = Date()) throws -> TrackedSession {
        let session = TrackedSession(
            labelID: label.id, labelNameSnapshot: label.name, startedAt: date)
        return try transaction {
            if var active = $0.activeSession {
                finalize(&active, at: date, state: .interrupted, note: "Switched labels")
                $0.sessions.append(active)
            }
            $0.activeSession = session
            return session
        }
    }

    public func startExistingLabel(_ nameOrID: String, at date: Date = Date()) throws
        -> TrackedSession
    {
        try transaction { payload in
            if let active = payload.activeSession {
                throw TrackedUsageCommandError.sessionAlreadyActive(active.labelNameSnapshot)
            }
            let query = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UUID(uuidString: query),
                let label = payload.labels.first(where: { $0.archivedAt == nil && $0.id == id })
            {
                let session = TrackedSession(
                    labelID: label.id, labelNameSnapshot: label.name, startedAt: date)
                payload.activeSession = session
                return session
            }
            let matches = payload.labels.filter {
                $0.archivedAt == nil && $0.name.caseInsensitiveCompare(query) == .orderedSame
            }
            guard !matches.isEmpty else { throw TrackedUsageCommandError.labelNotFound(query) }
            guard matches.count == 1, let label = matches.first else {
                throw TrackedUsageCommandError.ambiguousLabel(query)
            }
            let session = TrackedSession(
                labelID: label.id, labelNameSnapshot: label.name, startedAt: date)
            payload.activeSession = session
            return session
        }
    }
    @discardableResult
    public func append(
        _ observation: TrackedUsageObservation, toActiveSessionID sessionID: UUID? = nil
    )
        throws -> Bool
    {
        try append(contentsOf: [observation], toActiveSessionID: sessionID)
    }

    @discardableResult
    public func append(
        contentsOf observations: [TrackedUsageObservation], toActiveSessionID sessionID: UUID? = nil
    ) throws -> Bool {
        guard !observations.isEmpty else { return false }
        guard observations.allSatisfy({ $0.remaining.isFinite && $0.limit.isFinite }) else {
            throw TrackedUsageStoreError.invalidObservation
        }
        return try transaction { payload in
            guard var session = payload.activeSession,
                sessionID == nil || session.id == sessionID
            else { return false }

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

            guard didAppend else { return false }
            payload.activeSession = session
            return true
        }
    }
    @discardableResult public func stop(at date: Date = Date()) throws -> TrackedSession? {
        try stop(activeSessionID: nil, at: date)
    }
    @discardableResult public func stop(activeSessionID sessionID: UUID, at date: Date = Date())
        throws
        -> TrackedSession?
    {
        try stop(activeSessionID: Optional(sessionID), at: date)
    }
    private func stop(activeSessionID sessionID: UUID?, at date: Date) throws -> TrackedSession? {
        try transaction { payload in
            guard var active = payload.activeSession else { return nil }
            guard sessionID == nil || active.id == sessionID else { return nil }
            finalize(&active, at: date, state: .completed, note: nil)
            payload.activeSession = nil
            guard !TrackedUsageAttributionEngine.results(for: active).isEmpty else { return nil }
            payload.sessions.append(active)
            return active
        }
    }
    @discardableResult public func stopActiveSession(at date: Date = Date()) throws
        -> TrackedSession
    {
        try transaction { payload in
            guard var active = payload.activeSession else {
                throw TrackedUsageCommandError.noActiveSession
            }
            finalize(&active, at: date, state: .completed, note: nil)
            payload.activeSession = nil
            payload.sessions.append(active)
            return active
        }
    }
    public func replaceSession(_ session: TrackedSession) throws {
        try transaction { payload in
            guard let i = payload.sessions.firstIndex(where: { $0.id == session.id }) else {
                return
            }
            var updated = session
            updated.updatedAt = Date()
            payload.sessions[i] = updated
        }
    }
    public func deleteSession(id: UUID) throws {
        try transaction { payload in
            payload.sessions.removeAll { $0.id == id }
            upsertTombstone(id: id, in: &payload.deletedSessions)
        }
    }
    public func syncSnapshot() throws -> TrackedUsageSyncSnapshot {
        try refresh()
        return TrackedUsageSyncSnapshot(
            labels: payload.labels,
            sessions: payload.sessions.filter { $0.completionState != .active },
            deletedLabels: payload.deletedLabels, deletedSessions: payload.deletedSessions)
    }
    @discardableResult public func mergeSyncSnapshot(_ remote: TrackedUsageSyncSnapshot) throws
        -> Bool
    {
        guard remote.schemaVersion == 1 else { return false }
        let changed = try transaction { payload in
            let before = try? JSONEncoder().encode(payload)
            payload.deletedLabels = mergedTombstones(payload.deletedLabels, remote.deletedLabels)
            payload.deletedSessions = mergedTombstones(
                payload.deletedSessions, remote.deletedSessions)
            let labelDeletes = Dictionary(
                uniqueKeysWithValues: payload.deletedLabels.map { ($0.id, $0.deletedAt) })
            let sessionDeletes = Dictionary(
                uniqueKeysWithValues: payload.deletedSessions.map { ($0.id, $0.deletedAt) })
            payload.labels = mergeByID(
                payload.labels, remote.labels, modified: \TrackingLabel.updatedAt
            ).filter { (labelDeletes[$0.id] ?? .distantPast) < $0.updatedAt }
            payload.sessions = mergeByID(
                payload.sessions, remote.sessions.filter { $0.completionState != .active },
                modified: \TrackedSession.updatedAt
            ).filter { (sessionDeletes[$0.id] ?? .distantPast) < $0.updatedAt }
            let names = Dictionary(uniqueKeysWithValues: payload.labels.map { ($0.id, $0.name) })
            for index in payload.sessions.indices {
                if let name = names[payload.sessions[index].labelID] {
                    payload.sessions[index].labelNameSnapshot = name
                }
            }
            if let duplicate = duplicateActiveLabelName(in: payload.labels) {
                throw TrackedUsageStoreError.duplicateActiveLabelName(duplicate)
            }
            return before != (try? JSONEncoder().encode(payload))
        }
        if changed { NotificationCenter.default.post(name: .aiDataRefreshed, object: nil) }
        return changed
    }
    private func finalize(
        _ session: inout TrackedSession, at date: Date, state: TrackedSessionCompletionState,
        note: String?
    ) {
        session.endedAt = date
        session.completionState = state
        session.interruptionNote = note
        session.updatedAt = date
    }
    private func upsertTombstone(id: UUID, in values: inout [TrackedUsageTombstone]) {
        values.removeAll { $0.id == id }
        values.append(.init(id: id))
    }
    private func mergedTombstones(
        _ local: [TrackedUsageTombstone], _ remote: [TrackedUsageTombstone]
    ) -> [TrackedUsageTombstone] {
        Dictionary(grouping: local + remote, by: \TrackedUsageTombstone.id).compactMap {
            $0.value.max { $0.deletedAt < $1.deletedAt }
        }
    }
    private func mergeByID<T: Identifiable>(_ local: [T], _ remote: [T], modified: KeyPath<T, Date>)
        -> [T] where T.ID == UUID
    {
        Dictionary(grouping: local + remote, by: \T.id).compactMap {
            $0.value.max { $0[keyPath: modified] < $1[keyPath: modified] }
        }
    }
    private func metricKey(for observation: TrackedUsageObservation) -> String {
        "\(observation.sourceName)::\(observation.metricID)"
    }
    private func shouldCoalesce(
        _ previous: TrackedUsageObservation, _ current: TrackedUsageObservation
    ) -> Bool {
        guard current.origin == .poll || current.origin == .recovery else { return false }
        return previous.remaining == current.remaining && previous.limit == current.limit
            && previous.resetDate == current.resetDate
            && previous.cycleStartDate == current.cycleStartDate
    }
    private func hasActiveLabel(
        named name: String, excluding excludedID: UUID?, in labels: [TrackingLabel]
    ) -> Bool {
        labels.contains {
            $0.id != excludedID && $0.archivedAt == nil
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }
    private func duplicateActiveLabelName(in labels: [TrackingLabel]) -> String? {
        var names: Set<String> = []
        for label in labels where label.archivedAt == nil {
            let normalized = label.name.folding(
                options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalized).inserted else { return label.name }
        }
        return nil
    }
    private func decodePayload(_ data: Data?) throws -> Payload {
        guard let data else { return Payload() }
        let decoder = JSONDecoder()
        let schema: SchemaEnvelope
        do {
            schema = try decoder.decode(SchemaEnvelope.self, from: data)
        } catch {
            throw TrackedUsageStoreError.invalidPayload
        }
        guard schema.schemaVersion <= 2 else {
            throw TrackedUsageStoreError.unsupportedSchema(schema.schemaVersion)
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            throw TrackedUsageStoreError.invalidPayload
        }
    }
    private func refresh() throws {
        payload = try decodePayload(try backend.data(forKey: Self.storageKey))
    }
    private func transaction<T>(_ mutation: (inout Payload) throws -> T) throws -> T {
        var result: T!
        var committedPayload: Payload!
        try backend.updateData(forKey: Self.storageKey) { data in
            var latest = try decodePayload(data)
            result = try mutation(&latest)
            latest.schemaVersion = 2
            let encoded = try JSONEncoder().encode(latest)
            committedPayload = latest
            return encoded
        }
        payload = committedPayload
        return result
    }
}
