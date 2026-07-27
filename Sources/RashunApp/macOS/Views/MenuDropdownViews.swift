import AppKit
import Foundation
import RashunCore
import SwiftUI

private struct NaturalTextWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct HoverRevealText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var naturalWidth: CGFloat = 0
    @State private var isRevealed = false

    static func overflowDistance(naturalWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        max(0, naturalWidth - availableWidth)
    }

    static func revealDuration(for distance: CGFloat) -> TimeInterval {
        min(1.4, max(0.45, TimeInterval(distance / 90)))
    }

    var body: some View {
        GeometryReader { proxy in
            let overflow = Self.overflowDistance(
                naturalWidth: naturalWidth,
                availableWidth: proxy.size.width
            )

            Text(text)
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.secondary.opacity(0.78))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { textProxy in
                        Color.clear.preference(
                            key: NaturalTextWidthPreferenceKey.self,
                            value: textProxy.size.width
                        )
                    }
                }
                .offset(x: isRevealed ? -overflow : 0)
                .onHover { hovering in
                    guard overflow > 0.5 else {
                        isRevealed = false
                        return
                    }
                    if reduceMotion {
                        isRevealed = hovering
                    } else if hovering {
                        withAnimation(
                            .easeInOut(duration: Self.revealDuration(for: overflow)).delay(0.4)
                        ) {
                            isRevealed = true
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) {
                            isRevealed = false
                        }
                    }
                }
        }
        .frame(height: 11)
        .clipped()
        .contentShape(Rectangle())
        .onPreferenceChange(NaturalTextWidthPreferenceKey.self) { naturalWidth = $0 }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

struct MenuDropdownMetricRowModel: Identifiable {
    let id = UUID()
    let title: String
    let valueText: String
    let detailText: String?
    let progress: Double
    let colorHex: UInt32?
    let hasValue: Bool
    let hasWarning: Bool
}

struct MenuDropdownSourceCardView: View {
    let sourceName: String
    let headerDetailText: String?
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

                if let headerDetailText {
                    Text(headerDetailText)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.78))
                        .lineLimit(1)
                }
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
        let rowColor = Color(hex: row.colorHex ?? sourceColorHex)

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
                            .fill(rowColor)
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
                    .foregroundColor(row.hasValue ? rowColor : .secondary.opacity(0.85))
            }

            if let detailText = row.detailText {
                HoverRevealText(text: detailText)
            }
        }
    }
}
