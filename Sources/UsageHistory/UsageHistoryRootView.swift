import AppKit
import SwiftUI

struct UsageHistoryRootView: View {
    @ObservedObject var model: UsageHistoryViewModel
    @State private var hoveredLegendLabel: String?

    var body: some View {
        ZStack {
            BrandPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    rangeSelector
                    chartCard
                    summaryCard
                }
                .frame(maxWidth: 1100, alignment: .topLeading)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Usage History")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(BrandPalette.textPrimary)
            Text("Track source usage trends and forecast reset windows")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(BrandPalette.textSecondary)
        }
    }

    private var rangeSelector: some View {
        BrandSegmentedControl(
            options: ChartTimeRange.allCases,
            selection: $model.timeRange,
            label: { $0.rawValue }
        )
    }

    private var chartCard: some View {
        BrandCard(title: "Remaining Quota") {
            if !model.hasEnabledSources {
                emptyState("No enabled sources. Enable one in Preferences.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    legend
                    if model.visibleSeries.isEmpty {
                        emptyState("All sources are hidden. Click a legend item to show it.")
                    } else if model.visibleSeries.allSatisfy({ $0.points.isEmpty && $0.forecast.isEmpty }) {
                        emptyState("Not enough data yet. Refresh a source to build history.")
                    } else {
                        chartView
                    }
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(BrandPalette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 340, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(BrandPalette.background.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(BrandPalette.primary.opacity(0.16), lineWidth: 1)
                    )
            )
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(model.series) { series in
                Button(action: { model.toggleSeriesVisibility(series.label) }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(series.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text(series.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(BrandPalette.textPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(BrandPalette.primary.opacity(hoveredLegendLabel == series.label ? 0.14 : 0))
                    )
                }
                .buttonStyle(.plain)
                .opacity(model.isSeriesVisible(series.label) ? 1 : 0.38)
                .onHover { isHovered in
                    hoveredLegendLabel = isHovered ? series.label : (hoveredLegendLabel == series.label ? nil : hoveredLegendLabel)
                    if isHovered {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            Spacer()
            Text("Solid: actual  Dashed: forecast")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandPalette.textSecondary)
        }
    }

    private var chartView: some View {
        UsageChartRepresentable(
            series: model.visibleSeries,
            visibleStartDate: model.visibleStartDate,
            visibleEndDate: model.visibleEndDate
        )
        .frame(height: 360)
    }

    private var summaryCard: some View {
        BrandCard(title: "Forecast Insights") {
            if model.summaryLines.isEmpty {
                Text("No forecast insights for this range.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.summaryLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(BrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
