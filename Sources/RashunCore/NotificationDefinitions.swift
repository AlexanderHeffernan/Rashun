import Foundation

public enum NotificationDefinitions {
    public static func generic(
        sourceName: String,
        pacingLookbackStart: ((NotificationContext, Date) -> Date?)? = nil
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

        var definitions = [percentRemainingBelow, recentSpike]
        if pacingLookbackStart != nil {
            definitions.append(pacingAlert(sourceName: sourceName, pacingLookbackStart: pacingLookbackStart))
        }
        return definitions
    }

    private static func pacingAlert(
        sourceName: String,
        pacingLookbackStart: ((NotificationContext, Date) -> Date?)?
    ) -> NotificationDefinition {
        NotificationDefinition(
            id: "pacingAlert",
            title: "Pacing alert",
            detail: "Notifies if current usage trend is projected to hit 0% before reset.",
            inputs: [],
            evaluate: { context in
                let now = Date()
                guard let resetDate = context.current.resetDate, resetDate > now else {
                    return nil
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

                let title = "\(sourceName) pacing alert"
                let body = "At current pace, projected 0% by \(formatter.string(from: projectedZeroDate)) before reset at \(formatter.string(from: resetDate))."

                let cycleFormatter = ISO8601DateFormatter()
                let cycleKey = cycleFormatter.string(from: resetDate)
                return NotificationEvent(title: title, body: body, cooldownSeconds: 3600, cycleKey: cycleKey)
            }
        )
    }
}
