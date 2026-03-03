import AppKit
import Foundation

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

    private var currentSources: [AISource] = []

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed
    ]

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
        let showForecast = timeRange != .all

        for (index, source) in enabledSources.enumerated() {
            let color = Self.palette[index % Self.palette.count]
            let history = NotificationHistoryStore.shared.history(for: source.name)
            let allPoints = history
                .map { ChartPoint(date: $0.timestamp, value: $0.usage.percentRemaining) }
                .sorted(by: { $0.date < $1.date })
            var points = allPoints

            if let start = bounds.start {
                points = points.filter { $0.date >= start }
            }
            if let end = bounds.end {
                points = points.filter { $0.date <= end }
            }

            var sourceForecastPoints: [ChartPoint] = []
            if showForecast,
               let current = history.last?.usage,
               let forecast = source.forecast(current: current, history: history) {
                sourceForecastPoints = forecast.points
                    .map { ChartPoint(date: $0.date, value: $0.value) }
                    .sorted(by: { $0.date < $1.date })
                if let start = bounds.start {
                    sourceForecastPoints = sourceForecastPoints.filter { $0.date >= start }
                }
                if let end = bounds.end {
                    sourceForecastPoints = sourceForecastPoints.filter { $0.date <= end }
                }
                if let lastActual = points.last,
                   let firstForecast = sourceForecastPoints.first,
                   firstForecast.date > lastActual.date {
                    sourceForecastPoints.insert(lastActual, at: 0)
                }
                summaries.append(forecast.summary)
            }

            chartSeries.append(ChartSeries(label: source.name, color: color, points: points, forecast: sourceForecastPoints))
        }

        series = chartSeries
        summaryLines = summaries
        visibleStartDate = bounds.start
        visibleEndDate = bounds.end
    }
}
