import Foundation

public enum SourcePacingBehavior: Sendable {
    case resetWindow
    case refillOnly
    case none
}

public enum UsageForecastModePreference {
    public static let userDefaultsKey = "ai.forecastingMode.v1"

    public static var current: UsageForecastEngine.Mode {
        guard let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey),
              let mode = UsageForecastEngine.Mode(rawValue: rawValue) else {
            return .smart
        }
        return mode
    }

    public static func setCurrent(_ mode: UsageForecastEngine.Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
    }
}

public enum UsagePacingRecommendation: String, Sendable {
    case pushHard
    case push
    case pushLightly
    case onPace
    case conserveLightly
    case conserve
    case conserveHard
    case limitReached

    public var label: String {
        switch self {
        case .pushHard:
            return "Push hard"
        case .push:
            return "Push"
        case .pushLightly:
            return "Push lightly"
        case .onPace:
            return "On pace"
        case .conserveLightly:
            return "Conserve lightly"
        case .conserve:
            return "Conserve"
        case .conserveHard:
            return "Conserve hard"
        case .limitReached:
            return "Limit reached"
        }
    }
}

public struct UsagePacingAssessment: Sendable {
    public let score: Double
    public let recommendation: UsagePacingRecommendation
    public let confidence: Double
    public let projectedZeroDate: Date?
    public let activeHoursUntilReset: Double?
    public let message: String

    public init(
        score: Double,
        recommendation: UsagePacingRecommendation,
        confidence: Double,
        projectedZeroDate: Date?,
        activeHoursUntilReset: Double?,
        message: String
    ) {
        self.score = score
        self.recommendation = recommendation
        self.confidence = confidence
        self.projectedZeroDate = projectedZeroDate
        self.activeHoursUntilReset = activeHoursUntilReset
        self.message = message
    }
}

public enum UsageForecastEngine {
    public enum Mode: String, Sendable {
        case simple
        case smart
    }

    public static func resetWindowForecast(
        sourceLabel: String,
        current: UsageResult,
        history: [UsageSnapshot],
        resetDate: Date,
        historyWindowHours: Double,
        now: Date = Date(),
        calendar: Calendar = .current,
        mode: Mode = UsageForecastModePreference.current
    ) -> ForecastResult? {
        guard resetDate > now else { return nil }

        let currentPercent = clampedPercent(current.percentRemaining)
        var points: [ForecastPoint] = [ForecastPoint(date: now, value: currentPercent)]
        let filteredHistory = historyForCurrentCycle(history, current: current)
        let activeProfile = ActiveHoursProfile(history: history, current: current, now: now, calendar: calendar, mode: mode)
        let estimate = burnRatePerActiveSecond(
            from: filteredHistory,
            current: current,
            now: now,
            lookbackHours: historyWindowHours,
            calendar: calendar,
            activeProfile: activeProfile,
            mode: mode
        )
        let preReset = resetDate.addingTimeInterval(-1)

        let projectedPreReset: Double
        if estimate.rate > 0 {
            let activeSecondsToReset = max(0, activeSeconds(from: now, to: preReset, calendar: calendar, activeProfile: activeProfile))
            let secondsToZero = currentPercent / estimate.rate
            let horizon = min(secondsToZero, activeSecondsToReset)
            let steps = max(12, min(80, Int(horizon / 1800)))

            if steps > 0, horizon > 0 {
                for index in 1...steps {
                    let activeOffset = horizon * Double(index) / Double(steps)
                    let date = dateByAddingActiveSeconds(activeOffset, to: now, calendar: calendar, activeProfile: activeProfile, limit: preReset)
                    let value = max(currentPercent - estimate.rate * activeOffset, 0)
                    points.append(ForecastPoint(date: date, value: value))
                }
            }

            projectedPreReset = max(currentPercent - estimate.rate * activeSecondsToReset, 0)
        } else {
            projectedPreReset = currentPercent
            if preReset > now {
                points.append(ForecastPoint(date: preReset, value: currentPercent))
            }
        }

        points.append(ForecastPoint(date: resetDate, value: projectedPreReset))
        points.append(ForecastPoint(date: resetDate, value: 100))

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"

        let summary: String
        if let zeroDate = projectedZeroDate(currentPercent: currentPercent, burnRate: estimate.rate, now: now, resetDate: resetDate, calendar: calendar, activeProfile: activeProfile) {
            summary = "\(sourceLabel): projected 0% by \(formatter.string(from: zeroDate)); resets \(formatter.string(from: resetDate))"
        } else if estimate.rate > 0 {
            summary = "\(sourceLabel): projected \(String(format: "%.0f", projectedPreReset))% at reset; resets \(formatter.string(from: resetDate))"
        } else {
            summary = "\(sourceLabel): resets \(formatter.string(from: resetDate))"
        }

        return ForecastResult(points: points, summary: summary)
    }

    public static func resetWindowPacingAssessment(
        current: UsageResult,
        history: [UsageSnapshot],
        resetDate: Date,
        historyWindowHours: Double = 24,
        now: Date = Date(),
        calendar: Calendar = .current,
        mode: Mode = UsageForecastModePreference.current
    ) -> UsagePacingAssessment? {
        let currentPercent = clampedPercent(current.percentRemaining)
        if Int(round(currentPercent)) <= 0 {
            return UsagePacingAssessment(
                score: -100,
                recommendation: .limitReached,
                confidence: 1,
                projectedZeroDate: now,
                activeHoursUntilReset: 0,
                message: "Limit reached"
            )
        }

        guard resetDate > now else { return nil }
        let filteredHistory = historyForCurrentCycle(history, current: current)
        let activeProfile = ActiveHoursProfile(history: history, current: current, now: now, calendar: calendar, mode: mode)
        let estimate = burnRatePerActiveSecond(
            from: filteredHistory,
            current: current,
            now: now,
            lookbackHours: historyWindowHours,
            calendar: calendar,
            activeProfile: activeProfile,
            mode: mode
        )

        let activeRemaining = max(0, activeSeconds(from: now, to: resetDate, calendar: calendar, activeProfile: activeProfile))
        let activeTotal = activeCycleDuration(current: current, resetDate: resetDate, now: now, calendar: calendar, activeProfile: activeProfile)
        let idealPercent = activeTotal > 0 ? (activeRemaining / activeTotal) * 100 : currentPercent
        let baselineScore = currentPercent - idealPercent

        guard estimate.rate > 0 else {
            return assessment(
                score: baselineScore,
                confidence: estimate.confidence,
                zeroDate: nil,
                activeSecondsUntilReset: activeRemaining
            )
        }

        let projectedUsed = estimate.rate * activeRemaining
        let projectedRemaining = currentPercent - projectedUsed
        let forecastScore = projectedRemaining
        let blend = min(max(estimate.confidence, 0), 1)
        let score = (baselineScore * (1 - blend)) + (forecastScore * blend)
        let zeroDate = projectedZeroDate(
            currentPercent: currentPercent,
            burnRate: estimate.rate,
            now: now,
            resetDate: resetDate,
            calendar: calendar,
            activeProfile: activeProfile
        )

        return assessment(
            score: score,
            confidence: estimate.confidence,
            zeroDate: zeroDate,
            activeSecondsUntilReset: activeRemaining
        )
    }

    public static func resetWindowPaceGuide(
        current: UsageResult,
        history: [UsageSnapshot],
        resetDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        mode: Mode = UsageForecastModePreference.current
    ) -> PaceGuideResult? {
        guard resetDate > now else { return nil }
        let cycleStart = current.cycleStartDate ?? historyForCurrentCycle(history, current: current).first?.timestamp
        guard let cycleStart, cycleStart < resetDate else { return nil }

        let activeProfile = ActiveHoursProfile(history: history, current: current, now: now, calendar: calendar, mode: mode)
        let activeTotal = activeSeconds(from: cycleStart, to: resetDate, calendar: calendar, activeProfile: activeProfile)
        guard activeTotal > 0 else { return nil }

        let guideStart = cycleStart
        let totalSeconds = resetDate.timeIntervalSince(guideStart)
        let steps = max(12, min(80, Int(totalSeconds / 1800)))
        var points: [ForecastPoint] = []

        for index in 0...steps {
            let fraction = Double(index) / Double(steps)
            let date = guideStart.addingTimeInterval(totalSeconds * fraction)
            let activeElapsed = activeSeconds(from: cycleStart, to: date, calendar: calendar, activeProfile: activeProfile)
            let value = max(100 - (activeElapsed / activeTotal) * 100, 0)
            points.append(ForecastPoint(date: date, value: value))
        }

        if points.last?.date != resetDate {
            points.append(ForecastPoint(date: resetDate, value: 0))
        }

        return PaceGuideResult(points: points)
    }

    public static func refillOnlyPacingAssessment(current: UsageResult) -> UsagePacingAssessment? {
        let percent = clampedPercent(current.percentRemaining)
        if Int(round(percent)) <= 0 {
            return UsagePacingAssessment(
                score: 0,
                recommendation: .onPace,
                confidence: 1,
                projectedZeroDate: nil,
                activeHoursUntilReset: nil,
                message: "Recharging"
            )
        }
        return nil
    }

    public static func historyForCurrentCycle(_ history: [UsageSnapshot], current: UsageResult) -> [UsageSnapshot] {
        let epsilon: TimeInterval = 1
        return history.filter { snapshot in
            if let currentReset = current.resetDate {
                guard let snapshotReset = snapshot.usage.resetDate else { return false }
                return abs(snapshotReset.timeIntervalSince(currentReset)) <= epsilon
            }
            if let cycleStart = current.cycleStartDate {
                return snapshot.timestamp >= cycleStart
            }
            return true
        }
    }

    private struct BurnEstimate {
        let rate: Double
        let confidence: Double
    }

    private static func burnRatePerActiveSecond(
        from history: [UsageSnapshot],
        current: UsageResult,
        now: Date,
        lookbackHours: Double,
        calendar: Calendar,
        activeProfile: ActiveHoursProfile,
        mode: Mode
    ) -> BurnEstimate {
        let currentPercent = clampedPercent(current.percentRemaining)
        let lookbackStart = now.addingTimeInterval(-(lookbackHours * 3600))
        var points = history
            .filter { $0.timestamp >= lookbackStart && $0.timestamp <= now }
            .map { (date: $0.timestamp, value: clampedPercent($0.usage.percentRemaining)) }
            .sorted { $0.date < $1.date }

        if points.last?.date != now {
            points.append((date: now, value: currentPercent))
        }

        guard points.count >= 2 else { return BurnEstimate(rate: 0, confidence: 0) }

        let cycleStart = current.cycleStartDate ?? points.first?.date ?? now
        let activeElapsed = max(0, activeSeconds(from: cycleStart, to: now, calendar: calendar, activeProfile: activeProfile))
        let activeCycle = activeCycleDuration(current: current, resetDate: current.resetDate ?? now, now: now, calendar: calendar, activeProfile: activeProfile)
        let earlyCycleFactor = mode == .smart ? min(1, activeElapsed / max(30 * 60, activeCycle * 0.08)) : 1
        let evidenceFactor = min(1, Double(points.count - 1) / 5.0)
        let profileFactor = mode == .smart ? activeProfile.confidence : 1
        let confidence = min(1, max(0, earlyCycleFactor * evidenceFactor * max(0.6, profileFactor)))

        let rates: [Double]
        if mode == .simple {
            rates = [cycleAverageRate(current: current, now: now, calendar: calendar, activeProfile: activeProfile)]
                .compactMap { $0 }
                .filter { $0 > 0 && $0.isFinite }
        } else {
            rates = [
                ordinaryLeastSquaresRate(points: points, calendar: calendar, activeProfile: activeProfile),
                theilSenRate(points: points, calendar: calendar, activeProfile: activeProfile),
                exponentiallyWeightedIntervalRate(points: points, calendar: calendar, activeProfile: activeProfile),
                cycleAverageRate(current: current, now: now, calendar: calendar, activeProfile: activeProfile)
            ].compactMap { $0 }.filter { $0 > 0 && $0.isFinite }
        }

        guard !rates.isEmpty else { return BurnEstimate(rate: 0, confidence: confidence) }

        let sortedRates = rates.sorted()
        let rawRate = sortedRates[sortedRates.count / 2]
        let dampedRate = mode == .smart ? rawRate * (0.25 + 0.75 * confidence) : rawRate
        return BurnEstimate(rate: dampedRate, confidence: confidence)
    }

    private static func ordinaryLeastSquaresRate(points: [(date: Date, value: Double)], calendar: Calendar, activeProfile: ActiveHoursProfile) -> Double? {
        guard let start = points.first?.date else { return nil }
        let xs = points.map { activeSeconds(from: start, to: $0.date, calendar: calendar, activeProfile: activeProfile) }
        guard let maxX = xs.max(), maxX > 0 else { return nil }
        let ys = points.map(\.value)
        guard let slope = LinearRegression.slope(xs: xs, ys: ys) else { return nil }
        return max(0, -slope)
    }

    private static func theilSenRate(points: [(date: Date, value: Double)], calendar: Calendar, activeProfile: ActiveHoursProfile) -> Double? {
        guard points.count >= 3 else { return nil }
        let sampled = Array(points.suffix(36))
        var slopes: [Double] = []
        for i in 0..<sampled.count {
            for j in (i + 1)..<sampled.count {
                let dx = activeSeconds(from: sampled[i].date, to: sampled[j].date, calendar: calendar, activeProfile: activeProfile)
                guard dx > 0 else { continue }
                slopes.append((sampled[j].value - sampled[i].value) / dx)
            }
        }
        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        return max(0, -slopes[slopes.count / 2])
    }

    private static func exponentiallyWeightedIntervalRate(points: [(date: Date, value: Double)], calendar: Calendar, activeProfile: ActiveHoursProfile) -> Double? {
        guard points.count >= 2 else { return nil }
        var smoothed: Double?
        let alpha = 0.42
        for pair in zip(points.dropLast(), points.dropFirst()) {
            let active = activeSeconds(from: pair.0.date, to: pair.1.date, calendar: calendar, activeProfile: activeProfile)
            let drop = pair.0.value - pair.1.value
            guard active >= 60, drop > 0 else { continue }
            let rate = drop / active
            smoothed = smoothed.map { (alpha * rate) + ((1 - alpha) * $0) } ?? rate
        }
        return smoothed
    }

    private static func cycleAverageRate(current: UsageResult, now: Date, calendar: Calendar, activeProfile: ActiveHoursProfile) -> Double? {
        guard let cycleStart = current.cycleStartDate else { return nil }
        let activeElapsed = activeSeconds(from: cycleStart, to: now, calendar: calendar, activeProfile: activeProfile)
        guard activeElapsed >= 15 * 60 else { return nil }
        let used = 100 - clampedPercent(current.percentRemaining)
        guard used > 0 else { return nil }
        return used / activeElapsed
    }

    private static func activeCycleDuration(current: UsageResult, resetDate: Date, now: Date, calendar: Calendar, activeProfile: ActiveHoursProfile) -> TimeInterval {
        if let cycleStart = current.cycleStartDate, cycleStart < resetDate {
            return max(activeSeconds(from: cycleStart, to: resetDate, calendar: calendar, activeProfile: activeProfile), 1)
        }
        return max(activeSeconds(from: now.addingTimeInterval(-24 * 3600), to: resetDate, calendar: calendar, activeProfile: activeProfile), 1)
    }

    private static func projectedZeroDate(
        currentPercent: Double,
        burnRate: Double,
        now: Date,
        resetDate: Date,
        calendar: Calendar,
        activeProfile: ActiveHoursProfile
    ) -> Date? {
        guard burnRate > 0 else { return nil }
        let activeSecondsToZero = currentPercent / burnRate
        let activeSecondsToReset = activeSeconds(from: now, to: resetDate, calendar: calendar, activeProfile: activeProfile)
        guard activeSecondsToZero.isFinite, activeSecondsToZero < activeSecondsToReset else { return nil }
        return dateByAddingActiveSeconds(activeSecondsToZero, to: now, calendar: calendar, activeProfile: activeProfile, limit: resetDate)
    }

    private static func assessment(score: Double, confidence: Double, zeroDate: Date?, activeSecondsUntilReset: TimeInterval) -> UsagePacingAssessment {
        let clampedScore = clampedPacingScore(score)
        let recommendation = recommendation(for: clampedScore, zeroDate: zeroDate, confidence: confidence)
        let activeHours = activeSecondsUntilReset / 3600
        let message: String
        if recommendation == .limitReached {
            message = recommendation.label
        } else if let zeroDate, confidence >= 0.35 {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            message = "\(recommendation.label): projected empty around \(formatter.string(from: zeroDate))"
        } else if activeHours < 0.25 {
            message = "Reset soon"
        } else {
            message = recommendation.label
        }

        return UsagePacingAssessment(
            score: clampedScore,
            recommendation: recommendation,
            confidence: confidence,
            projectedZeroDate: zeroDate,
            activeHoursUntilReset: activeHours,
            message: message
        )
    }

    private static func recommendation(for score: Double, zeroDate: Date?, confidence: Double) -> UsagePacingRecommendation {
        if confidence < 0.25, score < -30 {
            return .onPace
        }
        if zeroDate != nil, confidence >= 0.55 {
            return score < -30 ? .conserveHard : .conserve
        }
        if score >= 30 { return .pushHard }
        if score >= 15 { return .push }
        if score > 5 { return .pushLightly }
        if score <= -30 { return .conserveHard }
        if score <= -15 { return .conserve }
        if score < -5 { return .conserveLightly }
        return .onPace
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func clampedPacingScore(_ value: Double) -> Double {
        min(max(value, -100), 100)
    }

    private struct ActiveHoursProfile {
        let hourlyWeights: [Double]
        let weekdayHourWeights: [Double]
        let confidence: Double

        init(history: [UsageSnapshot], current: UsageResult, now: Date, calendar: Calendar, mode: Mode) {
            guard mode == .smart else {
                hourlyWeights = Array(repeating: 1, count: 24)
                weekdayHourWeights = Array(repeating: 1, count: 7 * 24)
                confidence = 1
                return
            }

            let profileStart = now.addingTimeInterval(-90 * 24 * 3600)
            let recentHistory = history.filter { $0.timestamp >= profileStart && $0.timestamp <= now }
            let points = (recentHistory + [UsageSnapshot(timestamp: now, usage: current)])
                .map { (date: $0.timestamp, value: clampedPercent($0.usage.percentRemaining)) }
                .sorted { $0.date < $1.date }
                .suffix(1500)

            var usageByHour: [Int: Double] = [:]
            var usageByWeekdayHour: [Int: Double] = [:]
            var evidenceByWeekdayHour: [Int: Int] = [:]
            var evidenceCount = 0
            for pair in zip(points.dropLast(), points.dropFirst()) {
                let drop = pair.0.value - pair.1.value
                guard drop >= 0.05 else { continue }
                let hour = calendar.component(.hour, from: pair.1.date)
                let weekdayHour = Self.weekdayHourIndex(for: pair.1.date, calendar: calendar)
                usageByHour[hour, default: 0] += drop
                usageByWeekdayHour[weekdayHour, default: 0] += drop
                evidenceByWeekdayHour[weekdayHour, default: 0] += 1
                evidenceCount += 1
            }

            let meaningfulHours = usageByHour
                .filter { $0.value >= 0.2 }
                .map(\.key)

            guard evidenceCount >= 4, meaningfulHours.count >= 2 else {
                let fallbackHourlyWeights = (0..<24).map { (8...23).contains($0) ? 1.0 : 0.0 }
                hourlyWeights = fallbackHourlyWeights
                weekdayHourWeights = (0..<7).flatMap { _ in fallbackHourlyWeights }
                confidence = min(0.5, Double(evidenceCount) / 8.0)
                return
            }

            var smoothedUsage = Array(repeating: 0.0, count: 24)
            for hour in 0..<24 {
                let previous = usageByHour[(hour + 23) % 24, default: 0]
                let current = usageByHour[hour, default: 0]
                let next = usageByHour[(hour + 1) % 24, default: 0]
                smoothedUsage[hour] = (previous * 0.25) + (current * 0.5) + (next * 0.25)
            }

            let averageUsage = smoothedUsage.reduce(0, +) / 24
            let learnedHourlyWeights = smoothedUsage.map { usage in
                guard averageUsage > 0 else { return 0.0 }
                return min(max(usage / averageUsage, 0.05), 4.0)
            }

            var rawWeekdayHourWeights = Array(repeating: 0.0, count: 7 * 24)
            for weekday in 0..<7 {
                for hour in 0..<24 {
                    let previous = Self.weekdayHourIndex(weekday: weekday, hour: (hour + 23) % 24)
                    let current = Self.weekdayHourIndex(weekday: weekday, hour: hour)
                    let next = Self.weekdayHourIndex(weekday: weekday, hour: (hour + 1) % 24)
                    let smoothedWeekdayUsage =
                        (usageByWeekdayHour[previous, default: 0] * 0.25) +
                        (usageByWeekdayHour[current, default: 0] * 0.5) +
                        (usageByWeekdayHour[next, default: 0] * 0.25)
                    let weekdayEvidence =
                        evidenceByWeekdayHour[previous, default: 0] +
                        evidenceByWeekdayHour[current, default: 0] +
                        evidenceByWeekdayHour[next, default: 0]
                    let baselineUsage = smoothedUsage[hour]
                    let baselineWeight = learnedHourlyWeights[hour]

                    if weekdayEvidence >= 2, baselineUsage > 0, smoothedWeekdayUsage > 0 {
                        let adjustment = min(max(smoothedWeekdayUsage / baselineUsage, 0.35), 2.5)
                        rawWeekdayHourWeights[current] = min(max(baselineWeight * adjustment, 0.05), 4.0)
                    } else {
                        rawWeekdayHourWeights[current] = baselineWeight
                    }
                }
            }
            let weekdayAverage = rawWeekdayHourWeights.reduce(0, +) / Double(rawWeekdayHourWeights.count)
            weekdayHourWeights = rawWeekdayHourWeights.map { weight in
                guard weekdayAverage > 0 else { return weight }
                return min(max(weight / weekdayAverage, 0.05), 4.0)
            }
            hourlyWeights = learnedHourlyWeights
            confidence = min(1, Double(evidenceCount) / 16.0)
        }

        func contains(_ date: Date, calendar: Calendar) -> Bool {
            weight(for: date, calendar: calendar) > 0
        }

        func weight(for date: Date, calendar: Calendar) -> Double {
            let index = Self.weekdayHourIndex(for: date, calendar: calendar)
            guard weekdayHourWeights.indices.contains(index) else { return 0 }
            return weekdayHourWeights[index]
        }

        private static func weekdayHourIndex(for date: Date, calendar: Calendar) -> Int {
            let weekday = max(0, calendar.component(.weekday, from: date) - 1)
            let hour = calendar.component(.hour, from: date)
            return weekdayHourIndex(weekday: weekday, hour: hour)
        }

        private static func weekdayHourIndex(weekday: Int, hour: Int) -> Int {
            (weekday * 24) + hour
        }
    }

    private static func activeSeconds(from start: Date, to end: Date, calendar: Calendar, activeProfile: ActiveHoursProfile) -> TimeInterval {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        var cursor = start
        while cursor < end {
            guard let hourInterval = calendar.dateInterval(of: .hour, for: cursor) else {
                break
            }
            let segmentEnd = min(end, hourInterval.end)
            let weight = activeProfile.weight(for: cursor, calendar: calendar)
            if weight > 0, segmentEnd > cursor {
                total += segmentEnd.timeIntervalSince(cursor) * weight
            }
            cursor = segmentEnd
        }
        return total
    }

    private static func dateByAddingActiveSeconds(_ seconds: TimeInterval, to start: Date, calendar: Calendar, activeProfile: ActiveHoursProfile, limit: Date) -> Date {
        guard seconds > 0 else { return start }
        var remaining = seconds
        var cursor = start
        while cursor < limit {
            guard let hourInterval = calendar.dateInterval(of: .hour, for: cursor) else {
                return min(limit, cursor.addingTimeInterval(remaining))
            }

            let weight = activeProfile.weight(for: cursor, calendar: calendar)
            if weight > 0 {
                let available = min(limit, hourInterval.end).timeIntervalSince(cursor)
                let weightedAvailable = available * weight
                if remaining <= weightedAvailable {
                    return cursor.addingTimeInterval(remaining / weight)
                }
                remaining -= max(weightedAvailable, 0)
            }

            cursor = min(limit, hourInterval.end)
        }
        return limit
    }
}
