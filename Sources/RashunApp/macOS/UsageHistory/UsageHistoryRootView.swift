import AppKit
import SwiftUI
import RashunCore

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
                        chartToolbar
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
        VStack(alignment: .leading, spacing: 10) {
            FlowWrapLayout(spacing: 10, rowSpacing: 8) {
                ForEach(model.series) { series in
                    Button(action: { model.toggleSeriesVisibility(series.label) }) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(series.swiftUIColor)
                                .frame(width: 8, height: 8)
                            Text(series.label)
                                .lineLimit(1)
                                .truncationMode(.tail)
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
                    .fixedSize()
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    lineStyleKey(label: "Recorded", dashed: false)
                    lineStyleKey(label: "Forecasted", dashed: true)
                }
            }
        }
    }

    private var chartToolbar: some View {
        HStack(spacing: 10) {
            if model.supportsViewportScrolling {
                Text("Scroll sideways or use arrows")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    chartNavigationButton(
                        systemName: "chevron.left",
                        label: "Show earlier history",
                        isEnabled: model.canMoveViewportBackward
                    ) {
                        model.moveViewport(.backward)
                    }
                    chartNavigationButton(
                        systemName: "chevron.right",
                        label: "Show later history",
                        isEnabled: model.canMoveViewportForward
                    ) {
                        model.moveViewport(.forward)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: model.supportsViewportScrolling ? 30 : 0, alignment: .trailing)
    }

    private func chartNavigationButton(systemName: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(BrandPalette.textPrimary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BrandPalette.cardAlt.opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(BrandPalette.primary.opacity(0.34), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .accessibilityLabel(label)
        .help(label)
    }

    private func lineStyleKey(label: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: 22, y: 5))
            }
            .stroke(
                BrandPalette.textSecondary.opacity(0.95),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [5, 4] : [])
            )
            .frame(width: 22, height: 10)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandPalette.textSecondary)
        }
    }

    private var chartView: some View {
        UsageChartRepresentable(
            series: model.visibleSeries,
            visibleStartDate: model.visibleStartDate,
            visibleEndDate: model.visibleEndDate,
            onHorizontalScroll: model.scrollViewport
        )
        .frame(height: 360)
    }
}

private struct FlowWrapLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        let totalHeight = y + rowHeight
        return CGSize(width: proposal.width ?? usedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
