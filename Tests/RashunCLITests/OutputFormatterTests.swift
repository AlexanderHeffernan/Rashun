import XCTest
@testable import RashunCLI

final class OutputFormatterTests: XCTestCase {
    func testInitNoColorDisablesColorAndEmoji() {
        let formatter = OutputFormatter(noColor: true, stdoutIsTTY: true)
        XCTAssertFalse(formatter.useColor)
        XCTAssertFalse(formatter.useEmoji)
    }

    func testInitNonTTYDisablesColorAndEmoji() {
        let formatter = OutputFormatter(noColor: false, stdoutIsTTY: false)
        XCTAssertFalse(formatter.useColor)
        XCTAssertFalse(formatter.useEmoji)
    }

    func testColorizeReturnsRawTextWhenColorsDisabled() {
        let formatter = OutputFormatter(noColor: true, stdoutIsTTY: true)
        XCTAssertEqual(formatter.colorize("hello", as: .cyan), "hello")
    }

    func testColorizeWrapsTextWhenColorsEnabled() {
        let formatter = OutputFormatter(noColor: false, stdoutIsTTY: true)
        let expected = "\u{001B}[36mhello\u{001B}[0m"
        XCTAssertEqual(formatter.colorize("hello", as: .cyan), expected)
    }

    func testEmojiUsesFallbackWhenEmojiDisabled() {
        let formatter = OutputFormatter(noColor: true, stdoutIsTTY: true)
        XCTAssertEqual(formatter.emoji("✅", fallback: "[ok]"), "[ok]")
    }

    func testProgressBarClampsLowerBound() {
        let formatter = OutputFormatter(noColor: true, stdoutIsTTY: true)
        XCTAssertEqual(formatter.progressBar(percent: -5, width: 5), "░░░░░")
    }

    func testProgressBarClampsUpperBound() {
        let formatter = OutputFormatter(noColor: true, stdoutIsTTY: true)
        XCTAssertEqual(formatter.progressBar(percent: 150, width: 4), "████")
    }

    func testProgressBarRoundsFilledCells() {
        let formatter = OutputFormatter(noColor: true, stdoutIsTTY: true)
        XCTAssertEqual(formatter.progressBar(percent: 50, width: 7), "████░░░")
    }

    func testColorForPercentRemainingThresholds() {
        XCTAssertEqual(OutputFormatter.color(forPercentRemaining: 75), .green)
        XCTAssertEqual(OutputFormatter.color(forPercentRemaining: 45), .yellow)
        XCTAssertEqual(OutputFormatter.color(forPercentRemaining: 10), .red)
    }
}
