import Foundation
import RashunCore

public enum HistoryProjector {
    public static func project(_ observations: [UsageObservation], cap: Int = 10_000) -> [String:
        [UsageSnapshot]]
    {
        Dictionary(grouping: observations, by: \.series).reduce(into: [:]) { result, entry in
            let ordered = entry.value.sorted(by: observationOrder)
            var projected: [UsageSnapshot] = []
            var index = 0
            while index < ordered.count {
                let first = ordered[index]
                var last = first
                index += 1
                while index < ordered.count, equalUsage(ordered[index], first) {
                    last = ordered[index]
                    index += 1
                }
                projected.append(
                    UsageSnapshot(timestamp: first.observedAt, usage: first.usageResult))
                if last.id != first.id {
                    projected.append(
                        UsageSnapshot(timestamp: last.observedAt, usage: last.usageResult))
                }
            }
            result[entry.key.description] = Array(projected.suffix(max(0, cap)))
        }
    }

    public static func current(_ observations: [UsageObservation]) -> [UsageSeriesID:
        UsageObservation]
    {
        observations.reduce(into: [:]) { result, value in
            if let old = result[value.series] {
                if observationOrder(old, value) { result[value.series] = value }
            } else {
                result[value.series] = value
            }
        }
    }

    private static func observationOrder(_ lhs: UsageObservation, _ rhs: UsageObservation) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.origin.deviceID != rhs.origin.deviceID {
            return lhs.origin.deviceID.uuidString < rhs.origin.deviceID.uuidString
        }
        if lhs.origin.epoch != rhs.origin.epoch {
            return lhs.origin.epoch.uuidString < rhs.origin.epoch.uuidString
        }
        if lhs.originSequence != rhs.originSequence {
            return lhs.originSequence < rhs.originSequence
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func equalUsage(_ lhs: UsageObservation, _ rhs: UsageObservation) -> Bool {
        lhs.remaining == rhs.remaining && lhs.limit == rhs.limit && lhs.resetAt == rhs.resetAt
            && lhs.cycleStartedAt == rhs.cycleStartedAt
    }
}
