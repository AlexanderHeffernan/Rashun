import AppKit
import Foundation
import RashunCore

@MainActor
final class UsageHistoryViewModel: ObservableObject {
    @Published var timeRange: ChartTimeRange = .week {
        didSet { reloadChart() }
    }
    @Published private(set) var series: [ChartSeries] = []
    @Published private(set) var summaryLines: [String] = []
    @Published private(set) var visibleStartDate: Date?
    @Published private(set) var visibleEndDate: Date?
    @Published private(set) var hasEnabledSources = false
    @Published private(set) var hiddenSeriesLabels: Set<String> = []

    private var currentSources: [AISource] = []

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed
    ]

    var visibleSeries: [ChartSeries] {
        series.filter { !hiddenSeriesLabels.contains($0.label) }
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
        var summaries: [String] = []
        let now = Date()
        let bounds = timeRange.rangeBounds(now: now)
        let showForecastLines = timeRange != .all
        var seriesIndex = 0

        for source in enabledSources {
            let enabledMetrics = source.metrics
                .filter { SettingsStore.shared.isMetricEnabled(sourceName: source.name, metricId: $0.id) }

            if source.metrics.count <= 1 {
                let color = Self.palette[seriesIndex % Self.palette.count]
                seriesIndex += 1
                let history = UsageHistoryStore.shared.history(for: source.name)
                let points = filterPoints(history, bounds: bounds)
                let metricId = source.metrics.first?.id ?? "default"
                let forecastPoints = filteredForecastPoints(source: source, metricId: metricId, history: history, points: points, bounds: bounds, showForecast: showForecastLines)
                if let current = history.last?.usage, let forecast = source.forecast(for: metricId, current: current, history: history) {
                    summaries.append(forecast.summary)
                }
                chartSeries.append(ChartSeries(label: source.name, color: color, points: points, forecast: forecastPoints))
                continue
            }

            for metric in enabledMetrics {
                let color = Self.palette[seriesIndex % Self.palette.count]
                seriesIndex += 1
                let history = loadMetricHistory(source: source, metric: metric)

                let points = filterPoints(history, bounds: bounds)
                let forecastPoints = filteredForecastPoints(source: source, metricId: metric.id, history: history, points: points, bounds: bounds, showForecast: showForecastLines)

                if let current = history.last?.usage, let forecast = source.forecast(for: metric.id, current: current, history: history) {
                    summaries.append(forecastSummary(label: "\(source.name) - \(metric.title)", original: forecast.summary))
                }

                chartSeries.append(
                    ChartSeries(
                        label: "\(source.name) - \(metric.title)",
                        color: color,
                        points: points,
                        forecast: forecastPoints
                    )
                )
            }
        }

        series = chartSeries
        let availableLabels = Set(chartSeries.map(\.label))
        hiddenSeriesLabels = hiddenSeriesLabels.intersection(availableLabels)
        summaryLines = summaries
        visibleStartDate = bounds.start
        visibleEndDate = bounds.end
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

    private func filterPoints(_ history: [UsageSnapshot], bounds: (start: Date?, end: Date?)) -> [ChartPoint] {
        let points = history
            .map { ChartPoint(date: $0.timestamp, value: $0.usage.percentRemaining) }
            .sorted(by: { $0.date < $1.date })

        return clippedPoints(points, bounds: bounds)
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

    private func filteredForecastPoints(
        source: AISource,
        metricId: String,
        history: [UsageSnapshot],
        points: [ChartPoint],
        bounds: (start: Date?, end: Date?),
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

        return clippedPoints(sourceForecastPoints, bounds: bounds)
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

    private func forecastSummary(label: String, original: String) -> String {
        if let separatorRange = original.range(of: ":") {
            return "\(label)\(original[separatorRange.lowerBound...])"
        }
        return "\(label): \(original)"
    }
}
