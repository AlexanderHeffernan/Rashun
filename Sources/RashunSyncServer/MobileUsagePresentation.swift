import Foundation

public struct MobileMetricPresentation: Sendable, Equatable {
    public let providerID: String
    public let metricID: String
    public let sourceName: String
    public let metricTitle: String
    public let headerDetail: String?
    public let detailText: String?
    public let iconName: String?
    public let colorHex: String

    public init(
        providerID: String, metricID: String, sourceName: String, metricTitle: String,
        headerDetail: String?, detailText: String?, iconName: String?, colorHex: String
    ) {
        self.providerID = providerID
        self.metricID = metricID
        self.sourceName = sourceName
        self.metricTitle = metricTitle
        self.headerDetail = headerDetail
        self.detailText = detailText
        self.iconName = iconName
        self.colorHex = colorHex
    }
}

public actor MobileUsagePresentationStore {
    public static let shared = MobileUsagePresentationStore()
    private var value: [MobileMetricPresentation]?

    public func replace(_ presentations: [MobileMetricPresentation]) { value = presentations }
    public func snapshot() -> [MobileMetricPresentation]? { value }
    public func reset() { value = nil }
}
