import AppKit
import SwiftUI
import RashunCore

struct ChartPoint {
    let date: Date
    let value: Double
}

struct ChartSeries: Identifiable {
    let label: String
    let color: NSColor
    let points: [ChartPoint]
    let forecast: [ChartPoint]
    let paceGuide: [ChartPoint]

    var id: String { label }
    var swiftUIColor: Color { Color(nsColor: color) }
}
