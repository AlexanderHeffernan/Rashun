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
    public let displayColorHex: String
    public let paceColorHex: String?
    public let paceScore: Double?
    public let iconPath: String?
    public let badgeColorHex: String
    public let menuBarBadgeText: String?
    public let hasWarning: Bool

    public init(
        providerID: String, metricID: String, sourceName: String, metricTitle: String,
        headerDetail: String?, detailText: String?, iconName: String?, colorHex: String,
        menuBarBadgeText: String? = nil, displayColorHex: String? = nil,
        paceColorHex: String? = nil, paceScore: Double? = nil, iconPath: String? = nil,
        badgeColorHex: String? = nil, hasWarning: Bool = false
    ) {
        self.providerID = providerID
        self.metricID = metricID
        self.sourceName = sourceName
        self.metricTitle = metricTitle
        self.headerDetail = headerDetail
        self.detailText = detailText
        self.iconName = iconName
        self.colorHex = colorHex
        self.displayColorHex = displayColorHex ?? colorHex
        self.paceColorHex = paceColorHex
        self.paceScore = paceScore
        self.iconPath = iconPath
        self.badgeColorHex = badgeColorHex ?? colorHex
        self.menuBarBadgeText = menuBarBadgeText
        self.hasWarning = hasWarning
    }
}

public struct MobileWidgetAppearance: Sendable, Equatable {
    public struct Metric: Sendable, Equatable {
        public let providerID: String
        public let metricID: String
        public init(providerID: String, metricID: String) {
            self.providerID = providerID
            self.metricID = metricID
        }
    }
    public let colorMode: String
    public let centerContentMode: String
    public let showMetricBadges: Bool
    public let metrics: [Metric]
    public let backgroundColorHex: String
    public let cardColorHex: String
    public let cardAlternateColorHex: String
    public let primaryTextColorHex: String
    public let secondaryTextColorHex: String
    public let warningColorHex: String
    public let primaryBrandColorHex: String
    public let accentBrandColorHex: String
    public let ringTrackColorHex: String
    public init(
        colorMode: String, centerContentMode: String, showMetricBadges: Bool,
        metrics: [Metric], backgroundColorHex: String = "#131129",
        cardColorHex: String = "#1C1836", cardAlternateColorHex: String = "#241E44",
        primaryTextColorHex: String = "#FFFFFF", secondaryTextColorHex: String = "#B9B4D6",
        warningColorHex: String = "#FFD166", primaryBrandColorHex: String = "#935AFD",
        accentBrandColorHex: String = "#0DE4D1", ringTrackColorHex: String = "#5C596A"
    ) {
        self.colorMode = colorMode
        self.centerContentMode = centerContentMode
        self.showMetricBadges = showMetricBadges
        self.metrics = metrics
        self.backgroundColorHex = backgroundColorHex
        self.cardColorHex = cardColorHex
        self.cardAlternateColorHex = cardAlternateColorHex
        self.primaryTextColorHex = primaryTextColorHex
        self.secondaryTextColorHex = secondaryTextColorHex
        self.warningColorHex = warningColorHex
        self.primaryBrandColorHex = primaryBrandColorHex
        self.accentBrandColorHex = accentBrandColorHex
        self.ringTrackColorHex = ringTrackColorHex
    }
}

public actor MobileUsagePresentationStore {
    public static let shared = MobileUsagePresentationStore()
    private var value: [MobileMetricPresentation]?
    private var appearance: MobileWidgetAppearance?

    public func replace(_ presentations: [MobileMetricPresentation]) { value = presentations }
    public func snapshot() -> [MobileMetricPresentation]? { value }
    public func replaceAppearance(_ value: MobileWidgetAppearance) { appearance = value }
    public func appearanceSnapshot() -> MobileWidgetAppearance? { appearance }
    public func reset() { value = nil; appearance = nil }
}
