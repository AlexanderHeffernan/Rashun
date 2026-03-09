import Foundation

public struct ForecastPoint: Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct ForecastResult: Sendable {
    public let points: [ForecastPoint]
    public let summary: String

    public init(points: [ForecastPoint], summary: String) {
        self.points = points
        self.summary = summary
    }
}
