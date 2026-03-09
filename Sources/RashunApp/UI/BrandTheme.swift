import SwiftUI
import RashunCore

enum BrandPalette {
    static let background = Color(hex: 0x131129)
    static let primary = Color(hex: 0x935AFD)
    static let accent = Color(hex: 0x0DE4D1)
    static let card = Color(hex: 0x1C1836)
    static let cardAlt = Color(hex: 0x241E44)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xB9B4D6)
    static let warning = Color(hex: 0xFFD166)

    static let gradient = LinearGradient(
        gradient: Gradient(colors: [primary, accent]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
