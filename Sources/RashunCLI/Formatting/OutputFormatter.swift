import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

struct OutputFormatter {
    enum ANSIColor: String {
        case reset = "\u{001B}[0m"
        case red = "\u{001B}[31m"
        case green = "\u{001B}[32m"
        case yellow = "\u{001B}[33m"
        case magenta = "\u{001B}[35m"
        case cyan = "\u{001B}[36m"
        case bold = "\u{001B}[1m"
    }

    let useColor: Bool
    let useEmoji: Bool

    init(noColor: Bool, stdoutIsTTY: Bool = Self.stdoutIsTTY()) {
        let plain = noColor || !stdoutIsTTY
        self.useColor = !plain
        self.useEmoji = !plain
    }

    func colorize(_ text: String, as color: ANSIColor) -> String {
        guard useColor else { return text }
        return "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)"
    }

    func emoji(_ symbol: String, fallback: String) -> String {
        useEmoji ? symbol : fallback
    }

    func progressBar(percent: Double, width: Int = 14) -> String {
        let clamped = min(max(percent, 0), 100)
        let filled = Int((clamped / 100 * Double(width)).rounded())
        return String(repeating: "█", count: max(0, filled)) + String(repeating: "░", count: max(0, width - filled))
    }

    static func color(forPercentRemaining percent: Double) -> ANSIColor {
        if percent >= 60 { return .green }
        if percent >= 30 { return .yellow }
        return .red
    }

    private static func stdoutIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(STDOUT_FILENO) != 0
        #elseif canImport(WinSDK)
        return _isatty(_fileno(stdout)) != 0
        #else
        return true
        #endif
    }
}
