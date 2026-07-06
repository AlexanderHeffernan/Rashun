import AppKit
import Foundation
import SwiftUI
import RashunCore

struct MenuDropdownMetricRowModel: Identifiable {
    let id = UUID()
    let title: String
    let valueText: String
    let detailText: String?
    let progress: Double
    let hasValue: Bool
    let hasWarning: Bool
}

struct MenuDropdownSourceCardView: View {
    let sourceName: String
    let logoImage: NSImage?
    let sourceColorHex: UInt32
    let rows: [MenuDropdownMetricRowModel]

    private var sourceColor: Color { Color(hex: sourceColorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let logoImage {
                    Image(nsImage: logoImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                Text(sourceName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            ForEach(rows) { row in
                menuMetricRow(row)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private func menuMetricRow(_ row: MenuDropdownMetricRowModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                GeometryReader { proxy in
                    let clamped = min(max(row.progress, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.42))
                            .frame(height: 5)

                        Capsule()
                            .fill(sourceColor)
                            .frame(width: proxy.size.width * clamped, height: 5)
                    }
                }
                .frame(height: 5)

                if row.hasWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(BrandPalette.warning)
                }

                Text(row.valueText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(row.hasValue ? sourceColor : .secondary.opacity(0.85))
            }

            if let detailText = row.detailText {
                Text(detailText)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.78))
                    .lineLimit(1)
            }
        }
    }
}
