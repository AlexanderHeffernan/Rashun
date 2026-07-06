import AppKit
import Foundation
import RashunCore

@MainActor
final class UsageHistoryViewModel: ObservableObject {
    @Published var timeRange: ChartTimeRange = .week {
        didSet {
            viewportOffset = 0
            reloadChart()
        }
    }
    @Published private(set) var series: [ChartSeries] = []
    @Published private(set) var visibleStartDate: Date?
    @Published private(set) var visibleEndDate: Date?
    @Published private(set) var hasEnabledSources = false
    @Published private(set) var hiddenSeriesLabels: Set<String> = []

    private var currentSources: [AISource] = []
    private var viewportOffset: TimeInterval = 0
    private var cachedSeries: [ChartSeries] = []
    private var cachedDataRange: (earliest: Date, latest: Date)?

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed
    ]

    var visibleSeries: [ChartSeries] {
        series.filter { !hiddenSeriesLabels.contains($0.label) }
    }

    var supportsViewportScrolling: Bool {
        timeRange != .all
    }

    var canMoveViewportBackward: Bool {
        guard let limits = viewportOffsetLimits() else { return false }
        return viewportOffset > limits.min
    }

    var canMoveViewportForward: Bool {
        guard let limits = viewportOffsetLimits() else { return false }
        return viewportOffset < limits.max
    }

    func isSeriesVisible(_ label: String) -> Bool {
        !hiddenSeriesLabels.contains(label)
    }

    func toggleSeriesVisibility(_ label: String) {
        if hiddenSeriesLabels.contains(label) {
            hiddenSeriesLabels.remove(label)
        } else {
            hiddenSeriesLabels.insert(label)
        }
    }

    func configure(withSources sources: [AISource]) {
        currentSources = sources
        reloadChart()
    }

    func reloadChart() {
        let enabledSources = currentSources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        hasEnabledSources = !enabledSources.isEmpty

        var chartSeries: [ChartSeries] = []
        let now = Date()
        let baseBounds = timeRange.rangeBounds(now: now)
        let showForecastLines = timeRange != .all
        var seriesIndex = 0
        var dates: [Date] = []

        for source in enabledSources {
            let enabledMetrics = source.metrics
                .filter { SettingsStore.shared.isMetricEnabled(sourceName: source.name, metricId: $0.id) }

            if source.metrics.count <= 1 {
                let color = Self.palette[seriesIndex % Self.palette.count]
                seriesIndex += 1
                let history = UsageHistoryStore.shared.history(for: source.name)
                let points = allPoints(history)
                let metricId = source.metrics.first?.id ?? "default"
                let forecastPoints = forecastPoints(source: source, metricId: metricId, history: history, points: points, showForecast: showForecastLines)
                dates.append(contentsOf: points.map(\.date))
                dates.append(contentsOf: forecastPoints.map(\.date))
                chartSeries.append(ChartSeries(label: source.displayName, color: color, points: points, forecast: forecastPoints))
                continue
            }

            for metric in enabledMetrics {
                let color = Self.palette[seriesIndex % Self.palette.count]
                seriesIndex += 1
                let history = loadMetricHistory(source: source, metric: metric)

                let points = allPoints(history)
                let forecastPoints = forecastPoints(source: source, metricId: metric.id, history: history, points: points, showForecast: showForecastLines)
                dates.append(contentsOf: points.map(\.date))
                dates.append(contentsOf: forecastPoints.map(\.date))

                chartSeries.append(
                    ChartSeries(
                        label: "\(source.displayName) - \(metric.title)",
                        color: color,
                        points: points,
                        forecast: forecastPoints
                    )
                )
            }
        }

        cachedSeries = chartSeries
        if let earliest = dates.min(), let latest = dates.max() {
            cachedDataRange = (earliest, latest)
        } else {
            cachedDataRange = nil
        }
        clampViewportOffset(to: viewportOffsetLimits(baseBounds: baseBounds))
        updateVisibleChart(baseBounds: baseBounds)
        let availableLabels = Set(chartSeries.map(\.label))
        hiddenSeriesLabels = hiddenSeriesLabels.intersection(availableLabels)
    }

    func scrollViewport(byHorizontalPixels pixels: CGFloat, visibleWidth: CGFloat) {
        guard timeRange != .all,
              visibleWidth > 0,
              let visibleStartDate,
              let visibleEndDate else {
            return
        }

        let duration = visibleEndDate.timeIntervalSince(visibleStartDate)
        guard duration > 0 else { return }

        setViewportOffset(viewportOffset - TimeInterval(pixels / visibleWidth) * duration)
        updateVisibleChart()
    }

    func moveViewport(_ direction: ViewportDirection) {
        guard timeRange != .all,
              let visibleStartDate,
              let visibleEndDate else {
            return
        }

        let duration = visibleEndDate.timeIntervalSince(visibleStartDate)
        guard duration > 0 else { return }

        setViewportOffset(viewportOffset + duration * 0.85 * direction.multiplier)
        updateVisibleChart()
    }

    private func setViewportOffset(_ proposedOffset: TimeInterval) {
        viewportOffset = proposedOffset
        clampViewportOffset(to: viewportOffsetLimits())
    }

    private func clampViewportOffset(to limits: (min: TimeInterval, max: TimeInterval)?) {
        guard let limits else {
            viewportOffset = 0
            return
        }
        viewportOffset = min(max(viewportOffset, limits.min), limits.max)
    }

    private func viewportOffsetLimits(baseBounds: (start: Date?, end: Date?)? = nil) -> (min: TimeInterval, max: TimeInterval)? {
        guard timeRange != .all else { return nil }

        let bounds = baseBounds ?? timeRange.rangeBounds(now: Date())
        guard let baseStart = bounds.start,
              let baseEnd = bounds.end,
              baseEnd > baseStart,
              let dataRange = cachedDataRange else {
            return nil
        }

        let duration = baseEnd.timeIntervalSince(baseStart)
        let edgeInset = duration * 0.05

        return (
            min: dataRange.earliest.timeIntervalSince(baseEnd) + edgeInset,
            max: dataRange.latest.timeIntervalSince(baseStart) - edgeInset
        )
    }

    private func shiftedBounds(for bounds: (start: Date?, end: Date?)) -> (start: Date?, end: Date?) {
        guard viewportOffset != 0 else { return bounds }
        return (
            bounds.start?.addingTimeInterval(viewportOffset),
            bounds.end?.addingTimeInterval(viewportOffset)
        )
    }

    private func metricHistorySeriesName(source: AISource, metric: AISourceMetric) -> String {
        "\(source.name)::\(metric.id)"
    }

    private func legacyMetricHistorySeriesName(source: AISource, metric: AISourceMetric) -> String {
        "\(source.name) - \(metric.title)"
    }

    private func loadMetricHistory(source: AISource, metric: AISourceMetric) -> [UsageSnapshot] {
        let preferred = UsageHistoryStore.shared.history(for: metricHistorySeriesName(source: source, metric: metric))
        if !preferred.isEmpty {
            return preferred
        }

        let legacy = UsageHistoryStore.shared.history(for: legacyMetricHistorySeriesName(source: source, metric: metric))
        if !legacy.isEmpty {
            return legacy
        }

        if metric.id == source.metrics.first?.id {
            return UsageHistoryStore.shared.history(for: source.name)
        }

        return []
    }

    private func updateVisibleChart(baseBounds: (start: Date?, end: Date?)? = nil) {
        let bounds = shiftedBounds(for: baseBounds ?? timeRange.rangeBounds(now: Date()))
        series = cachedSeries.map { rawSeries in
            ChartSeries(
                label: rawSeries.label,
                color: rawSeries.color,
                points: clippedPoints(rawSeries.points, bounds: bounds),
                forecast: clippedPoints(rawSeries.forecast, bounds: bounds)
            )
        }
        visibleStartDate = bounds.start
        visibleEndDate = bounds.end
    }

    private func allPoints(_ history: [UsageSnapshot]) -> [ChartPoint] {
        history
            .map { ChartPoint(date: $0.timestamp, value: $0.usage.percentRemaining) }
            .sorted(by: { $0.date < $1.date })
    }

    private func interpolatedValue(at date: Date, in points: [ChartPoint]) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if date < first.date || date > last.date { return nil }

        if points.count == 1 {
            return first.value
        }

        if let upperIndex = points.firstIndex(where: { $0.date >= date }) {
            if upperIndex == 0 {
                return points[0].value
            }
            let upper = points[upperIndex]
            let lower = points[upperIndex - 1]
            let span = upper.date.timeIntervalSince(lower.date)
            if span <= 0 {
                return upper.value
            }
            let fraction = date.timeIntervalSince(lower.date) / span
            return lower.value + (upper.value - lower.value) * fraction
        }

        return last.value
    }

    private func forecastPoints(
        source: AISource,
        metricId: String,
        history: [UsageSnapshot],
        points: [ChartPoint],
        showForecast: Bool
    ) -> [ChartPoint] {
        guard showForecast,
              let current = history.last?.usage,
              let forecast = source.forecast(for: metricId, current: current, history: history) else {
            return []
        }

        var sourceForecastPoints = forecast.points
            .map { ChartPoint(date: $0.date, value: $0.value) }
            .sorted(by: { $0.date < $1.date })

        if let lastActual = points.last,
           let firstForecast = sourceForecastPoints.first,
           firstForecast.date > lastActual.date {
            sourceForecastPoints.insert(lastActual, at: 0)
        }

        return sourceForecastPoints
    }

    private func clippedPoints(_ sortedPoints: [ChartPoint], bounds: (start: Date?, end: Date?)) -> [ChartPoint] {
        guard !sortedPoints.isEmpty else { return [] }

        var points = sortedPoints

        if let start = bounds.start {
            points = points.filter { $0.date >= start }
            if let startValue = interpolatedValue(at: start, in: sortedPoints),
               points.first?.date != start {
                points.insert(ChartPoint(date: start, value: startValue), at: 0)
            }
        }

        if let end = bounds.end {
            points = points.filter { $0.date <= end }
            if let endValue = interpolatedValue(at: end, in: sortedPoints),
               points.last?.date != end {
                points.append(ChartPoint(date: end, value: endValue))
            }
        }

        return points.sorted(by: { $0.date < $1.date })
    }

}

enum ViewportDirection {
    case backward
    case forward

    var multiplier: TimeInterval {
        switch self {
        case .backward:
            return -1
        case .forward:
            return 1
        }
    }
}
