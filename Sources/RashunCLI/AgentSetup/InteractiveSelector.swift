import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SelectableItem {
    let label: String
    let detail: String
    var isSelected: Bool
}

enum InteractiveSelector {
    /// Present a checkbox selector. Returns indices of selected items, or nil if cancelled.
    static func select(
        items: inout [SelectableItem],
        prompt: String = "(↑/↓ to move, space to toggle, enter to confirm)",
        formatter: OutputFormatter
    ) -> [Int]? {
        #if canImport(Darwin) || canImport(Glibc)
        if stdinIsTTY() {
            return rawSelect(items: &items, prompt: prompt, formatter: formatter)
        }
        #endif
        return fallbackSelect(items: &items, formatter: formatter)
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func rawSelect(
        items: inout [SelectableItem],
        prompt: String,
        formatter: OutputFormatter
    ) -> [Int]? {
        var cursor = 0
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)

        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        raw.c_cc.6 = 1  // VMIN
        raw.c_cc.5 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }

        render(items: items, cursor: cursor, prompt: prompt, formatter: formatter, isInitial: true)

        while true {
            let c = readByte()
            switch c {
            case 0x1B: // Escape sequence
                let next = readByte()
                guard next == 0x5B else { continue } // '['
                let arrow = readByte()
                if arrow == 0x41 { // Up
                    cursor = (cursor - 1 + items.count) % items.count
                } else if arrow == 0x42 { // Down
                    cursor = (cursor + 1) % items.count
                }
                render(items: items, cursor: cursor, prompt: prompt, formatter: formatter, isInitial: false)

            case 0x20: // Space — toggle
                items[cursor].isSelected.toggle()
                render(items: items, cursor: cursor, prompt: prompt, formatter: formatter, isInitial: false)

            case 0x0A, 0x0D: // Enter — confirm
                clearLines(items.count + 1)
                return items.indices.filter { items[$0].isSelected }

            case 0x03: // Ctrl-C
                clearLines(items.count + 1)
                return nil

            default:
                break
            }
        }
    }

    private static func readByte() -> UInt8 {
        var byte: UInt8 = 0
        _ = read(STDIN_FILENO, &byte, 1)
        return byte
    }

    private static func render(
        items: [SelectableItem],
        cursor: Int,
        prompt: String,
        formatter: OutputFormatter,
        isInitial: Bool
    ) {
        if !isInitial {
            clearLines(items.count + 1)
        }

        for (index, item) in items.enumerated() {
            let pointer = index == cursor ? formatter.colorize(">", as: .cyan) : " "
            let checkbox = item.isSelected
                ? formatter.colorize("[•]", as: .green)
                : "[ ]"
            let detail = formatter.colorize(item.detail, as: .cyan)
            print("  \(pointer) \(checkbox) \(item.label)  \(detail)")
        }
        print()
        print("  \(formatter.colorize(prompt, as: .cyan))", terminator: "")
        fflush(stdout)
    }

    private static func clearLines(_ count: Int) {
        for _ in 0..<count {
            print("\u{001B}[A\u{001B}[2K", terminator: "")
        }
        print("\r", terminator: "")
        fflush(stdout)
    }

    private static func stdinIsTTY() -> Bool {
        isatty(STDIN_FILENO) != 0
    }
    #endif

    private static func fallbackSelect(
        items: inout [SelectableItem],
        formatter: OutputFormatter
    ) -> [Int]? {
        for (index, item) in items.enumerated() {
            let checkbox = item.isSelected ? "[•]" : "[ ]"
            print("  \(index + 1). \(checkbox) \(item.label)  \(item.detail)")
        }
        print()
        print("Enter numbers to toggle (e.g. 1,3), then press enter to confirm:")

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.isEmpty else {
            return items.indices.filter { items[$0].isSelected }
        }

        let toggles = input.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        for number in toggles {
            let index = number - 1
            guard items.indices.contains(index) else { continue }
            items[index].isSelected.toggle()
        }

        return items.indices.filter { items[$0].isSelected }
    }
}
