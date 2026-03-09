import SwiftUI
import RashunCore

struct UsageChartRepresentable: NSViewRepresentable {
    let series: [ChartSeries]
    let visibleStartDate: Date?
    let visibleEndDate: Date?

    func makeNSView(context: Context) -> UsageChartView {
        let view = UsageChartView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: UsageChartView, context: Context) {
        _ = context
        nsView.series = series
        nsView.visibleStartDate = visibleStartDate
        nsView.visibleEndDate = visibleEndDate
        nsView.showLegend = false
    }
}
