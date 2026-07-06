import Foundation
import RashunCore

enum MenuBarColorMode: String, Codable, CaseIterable {
    case monochrome
    case brandGradient
    case sourceSolid
    case pace
}

enum MenuBarCenterContentMode: String, Codable, CaseIterable {
    case logo
    case percentage
    case pacePoints
}

struct MenuBarMetricSelection: Codable, Hashable {
    let sourceName: String
    let metricId: String
}

struct MenuBarAppearanceSettings: Codable {
    var colorMode: MenuBarColorMode
    var centerContentMode: MenuBarCenterContentMode
    var showMetricBadges: Bool
    var selectedMetrics: [MenuBarMetricSelection]

    init(
        colorMode: MenuBarColorMode = .monochrome,
        centerContentMode: MenuBarCenterContentMode = .logo,
        showMetricBadges: Bool = true,
        selectedMetrics: [MenuBarMetricSelection] = []
    ) {
        self.colorMode = Self.normalizedColorMode(colorMode)
        self.centerContentMode = centerContentMode
        self.showMetricBadges = showMetricBadges
        self.selectedMetrics = Self.unique(selectedMetrics)
    }

    static func normalized(
        colorMode: MenuBarColorMode,
        centerContentMode: MenuBarCenterContentMode,
        showMetricBadges: Bool,
        selectedMetrics: [MenuBarMetricSelection]
    ) -> MenuBarAppearanceSettings {
        MenuBarAppearanceSettings(
            colorMode: colorMode,
            centerContentMode: centerContentMode,
            showMetricBadges: showMetricBadges,
            selectedMetrics: selectedMetrics
        )
    }

    private static func unique(_ items: [MenuBarMetricSelection]) -> [MenuBarMetricSelection] {
        var seen: Set<MenuBarMetricSelection> = []
        var ordered: [MenuBarMetricSelection] = []
        for item in items {
            if seen.insert(item).inserted {
                ordered.append(item)
            }
        }
        return ordered
    }

    private static func normalizedColorMode(_ mode: MenuBarColorMode) -> MenuBarColorMode {
        // Legacy "brandGradient" setting now maps to the simpler "Color" mode.
        if mode == .brandGradient {
            return .sourceSolid
        }
        return mode
    }

    private enum CodingKeys: String, CodingKey {
        case colorMode
        case centerContentMode
        case showMetricBadges
        case selectedMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let colorMode = try container.decodeIfPresent(MenuBarColorMode.self, forKey: .colorMode) ?? .monochrome
        let centerContentMode = try container.decodeIfPresent(MenuBarCenterContentMode.self, forKey: .centerContentMode) ?? .logo
        let showMetricBadges = try container.decodeIfPresent(Bool.self, forKey: .showMetricBadges) ?? true
        let selectedMetrics = try container.decodeIfPresent([MenuBarMetricSelection].self, forKey: .selectedMetrics) ?? []
        self.init(
            colorMode: colorMode,
            centerContentMode: centerContentMode,
            showMetricBadges: showMetricBadges,
            selectedMetrics: selectedMetrics
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(centerContentMode, forKey: .centerContentMode)
        try container.encode(showMetricBadges, forKey: .showMetricBadges)
        try container.encode(selectedMetrics, forKey: .selectedMetrics)
    }
}
