import Cocoa

enum ChartTimeRange: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case all = "All"

    func rangeBounds(now: Date, calendar: Calendar = .current) -> (start: Date?, end: Date?) {
        switch self {
        case .day:
            let interval = calendar.dateInterval(of: .day, for: now)
            return (interval?.start, interval?.end)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return (interval?.start, interval?.end)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            return (interval?.start, interval?.end)
        case .all:
            return (nil, nil)
        }
    }
}

@MainActor
final class ChartWindowController: NSWindowController {
    static let shared = ChartWindowController()

    private let chartView = UsageChartView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private var currentSources: [AISource] = []
    private var timeRange: ChartTimeRange = .week

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed
    ]

    private init() {
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 450))

        let window = NSWindow(contentViewController: vc)
        window.title = "Usage History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 450))
        window.minSize = NSSize(width: 500, height: 300)

        super.init(window: window)

        setupLayout(in: vc.view)
        NotificationCenter.default.addObserver(self, selector: #selector(dataRefreshed), name: .aiDataRefreshed, object: nil)
    }

    required init?(coder: NSCoder) { return nil }

    func showWindowAndBringToFront() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func configure(withSources sources: [AISource]) {
        currentSources = sources
        reloadChart()
    }

    private func setupLayout(in container: NSView) {
        let segmented = NSSegmentedControl(
            labels: ChartTimeRange.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: self,
            action: #selector(timeRangeChanged(_:))
        )
        segmented.selectedSegment = ChartTimeRange.allCases.firstIndex(of: timeRange) ?? 1
        segmented.translatesAutoresizingMaskIntoConstraints = false

        chartView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        if let cell = summaryLabel.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = false
            cell.wraps = true
            cell.lineBreakMode = .byWordWrapping
        }
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(segmented)
        container.addSubview(chartView)
        container.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            chartView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            chartView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            chartView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            summaryLabel.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            summaryLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    @objc private func timeRangeChanged(_ sender: NSSegmentedControl) {
        timeRange = ChartTimeRange.allCases[sender.selectedSegment]
        reloadChart()
    }

    @objc private func dataRefreshed() {
        guard window?.isVisible == true else { return }
        reloadChart()
    }

    private func reloadChart() {
        let enabled = currentSources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        var chartSeries: [ChartSeries] = []
        var summaryParts: [String] = []
        let now = Date()
        let bounds = timeRange.rangeBounds(now: now)
        let showForecast = timeRange != .all
        chartView.visibleStartDate = bounds.start
        chartView.visibleEndDate = bounds.end

        for (i, source) in enabled.enumerated() {
            let color = Self.palette[i % Self.palette.count]
            let history = NotificationHistoryStore.shared.history(for: source.name)
            let allPoints = history.map { ChartPoint(date: $0.timestamp, value: $0.usage.percentRemaining) }
            var points = allPoints

            if let start = bounds.start {
                points = points.filter { $0.date >= start }
            }
            if let end = bounds.end {
                points = points.filter { $0.date <= end }
            }

            var forecastPoints: [ChartPoint] = []
            if showForecast,
               let current = history.last?.usage,
               let forecast = source.forecast(current: current, history: history) {
                forecastPoints = forecast.points.map { ChartPoint(date: $0.date, value: $0.value) }
                if let start = bounds.start {
                    forecastPoints = forecastPoints.filter { $0.date >= start }
                }
                if let end = bounds.end {
                    forecastPoints = forecastPoints.filter { $0.date <= end }
                }
                if let lastActual = points.last,
                   let firstForecast = forecastPoints.first,
                   firstForecast.date > lastActual.date {
                    forecastPoints.insert(lastActual, at: 0)
                }
                summaryParts.append(forecast.summary)
            }

            chartSeries.append(ChartSeries(label: source.name, color: color, points: points, forecast: forecastPoints))
        }

        chartView.series = chartSeries
        summaryLabel.stringValue = summaryParts.joined(separator: "\n")
    }
}
