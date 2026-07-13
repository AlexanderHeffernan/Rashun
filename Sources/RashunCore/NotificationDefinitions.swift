import Foundation

public enum NotificationDefinitions {
    public static func generic(
        sourceName: String,
        pacingLookbackStart: ((NotificationContext, Date) -> Date?)? = nil,
        pacingAssessment: ((NotificationContext, Date) -> UsagePacingAssessment?)? = nil
    ) -> [NotificationDefinition] {
        let percentRemainingBelow = NotificationDefinition(
            id: "percentRemainingBelow",
            title: "Percent remaining below",
            detail: "Notifies when remaining percent drops below your threshold.",
            inputs: [
                NotificationInputSpec(
                    id: "threshold",
                    label: "Threshold",
                    unit: "%",
                    defaultValue: 50,
                    min: 1,
                    max: 99,
                    step: 1
                )
            ],
            evaluate: { context in
                let threshold = context.value(for: "threshold", defaultValue: 50)
                let current = context.current.percentRemaining
                let previous = context.previous?.usage.percentRemaining

                guard current < threshold else { return nil }
                if let prev = previous, prev < threshold {
                    return nil
                }

                let title = "\(sourceName) usage alert"
                let body = "Remaining is now \(String(format: "%.0f", current))%, below \(String(format: "%.0f", threshold))%."
                return NotificationEvent(title: title, body: body, cooldownSeconds: 3600, cycleKey: nil)
            }
        )

        let recentSpike = NotificationDefinition(
            id: "recentUsageSpike",
            title: "Recent usage spike",
            detail: "Notifies when usage drops quickly within a time window.",
            inputs: [
                NotificationInputSpec(
                    id: "dropPercent",
                    label: "Drop",
                    unit: "%",
                    defaultValue: 10,
                    min: 1,
                    max: 100,
                    step: 1
                ),
                NotificationInputSpec(
                    id: "minutes",
                    label: "Window",
                    unit: "min",
                    defaultValue: 30,
                    min: 2,
                    max: 240,
                    step: 1
                )
            ],
            evaluate: { context in
                let drop = context.value(for: "dropPercent", defaultValue: 10)
                let minutes = context.value(for: "minutes", defaultValue: 30)
                guard let past = context.snapshot(minutesAgo: minutes) else { return nil }

                let current = context.current.percentRemaining
                let previous = past.usage.percentRemaining
                let used = max(0, previous - current)
                guard used >= drop else { return nil }

                let title = "\(sourceName) usage spike"
                let body = "You used about \(String(format: "%.0f", used))% in the last \(Int(minutes)) minutes."
                return NotificationEvent(title: title, body: body, cooldownSeconds: 3600, cycleKey: nil)
            }
        )

        let metricReset = NotificationDefinition(
            id: "metricReset",
            title: "Metric reset",
            detail: "Notifies when this metric resets to a higher remaining amount.",
            inputs: [],
            evaluate: { context in
                guard let previous = context.previous else { return nil }

                let current = context.current.percentRemaining
                let previousPercent = previous.usage.percentRemaining
                guard current > previousPercent else { return nil }
                guard current >= 95 else { return nil }
                guard current - previousPercent >= 20 else { return nil }
                let previousReset = previous.usage.resetDate
                let currentReset = context.current.resetDate
                if let previousReset, let currentReset {
                    guard currentReset > previousReset else { return nil }
                } else {
                    guard previousPercent < 95 else { return nil }
                }

                let title = "\(sourceName) reset"
                let body = "Remaining reset to \(String(format: "%.0f", current))%."
                let cycleKey = currentReset.map { ISO8601DateFormatter().string(from: $0) }
                return NotificationEvent(title: title, body: body, cooldownSeconds: nil, cycleKey: cycleKey)
            }
        )

        var definitions = [percentRemainingBelow, recentSpike, metricReset]
        if pacingLookbackStart != nil || pacingAssessment != nil {
            definitions.append(pacingAlert(
                sourceName: sourceName,
                pacingLookbackStart: pacingLookbackStart,
                pacingAssessment: pacingAssessment
            ))
        }
        return definitions
    }

    private static func pacingAlert(
        sourceName: String,
        pacingLookbackStart: ((NotificationContext, Date) -> Date?)?,
        pacingAssessment: ((NotificationContext, Date) -> UsagePacingAssessment?)?
    ) -> NotificationDefinition {
        NotificationDefinition(
            id: "pacingAlert",
            title: "Pacing guidance",
            detail: "Notifies when your current usage pace needs attention before reset.",
            inputs: [],
            evaluate: { context in
                let now = context.now
                guard let resetDate = context.current.resetDate, resetDate > now else {
                    return nil
                }

                if let assessment = pacingAssessment?(context, now) {
                    guard assessment.confidence >= 0.35 else { return nil }
                    guard [.conserveLightly, .conserve, .conserveHard].contains(assessment.recommendation) else { return nil }

                    let formatter = DateFormatter()
                    formatter.dateFormat = "MMM d, h:mm a"

                    let title = "\(sourceName) \(assessment.recommendation.label.lowercased())"
                    let body: String
                    if let projectedZeroDate = assessment.projectedZeroDate {
                        body = "\(assessment.recommendation.label): projected empty around \(formatter.string(from: projectedZeroDate)). Reset is \(formatter.string(from: resetDate))."
                    } else {
                        body = "\(assessment.recommendation.label). Reset is \(formatter.string(from: resetDate))."
                    }

                    let cycleFormatter = ISO8601DateFormatter()
                    let cycleKey = cycleFormatter.string(from: resetDate)
                    return NotificationEvent(title: title, body: body, cooldownSeconds: 3600, cycleKey: cycleKey)
                }

                let defaultStart = context.current.cycleStartDate ?? now.addingTimeInterval(-24 * 3600)
                let lookbackStart = pacingLookbackStart?(context, now) ?? defaultStart
                let recent = context.history.filter { $0.timestamp >= lookbackStart && $0.timestamp <= now }

                var xs = recent.map(\.timestamp).map(\.timeIntervalSinceReferenceDate)
                var ys = recent.map { min(max($0.usage.percentRemaining, 0), 100) }

                let currentPercent = min(max(context.current.percentRemaining, 0), 100)
                if xs.isEmpty || xs.last != now.timeIntervalSinceReferenceDate {
                    xs.append(now.timeIntervalSinceReferenceDate)
                    ys.append(currentPercent)
                }
                guard xs.count >= 3,
                      let minX = xs.min(),
                      let maxX = xs.max(),
                      (maxX - minX) >= (15 * 60) else {
                    return nil
                }

                guard let slope = LinearRegression.slope(xs: xs, ys: ys) else {
                    return nil
                }
                let burnRate = max(0, -slope)
                guard burnRate > 0 else { return nil }

                let secondsToZero = currentPercent / burnRate
                guard secondsToZero.isFinite else { return nil }
                let projectedZeroDate = now.addingTimeInterval(secondsToZero)
                guard projectedZeroDate < resetDate else { return nil }

                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, h:mm a"

                let title = "\(sourceName) conserve"
                let body = "Conserve: projected empty around \(formatter.string(from: projectedZeroDate)). Reset is \(formatter.string(from: resetDate))."

                let cycleFormatter = ISO8601DateFormatter()
                let cycleKey = cycleFormatter.string(from: resetDate)
                return NotificationEvent(title: title, body: body, cooldownSeconds: 3600, cycleKey: cycleKey)
            }
        )
    }
}
