import Foundation

struct AmpSource: AISource {
    let name = "AMP"
    let requirements = "Requires the amp CLI installed at ~/.amp/bin/amp and executable."

    func fetchUsage() async throws -> UsageResult {
        let output = try runCommand()
        guard let result = parseUsage(from: output) else {
            throw NSError(domain: "AmpError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse: \(output)"])
        }
        return result
    }

    private func runCommand() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.amp/bin/amp")
        process.arguments = ["usage"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NSError(domain: "AmpError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No output"])
        }

        if process.terminationStatus != 0 {
            throw NSError(domain: "AmpError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }

        return output
    }

    func forecast(current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        let regenRatePerHour = 0.42 // Amp Free: +$0.42/hour
        guard current.limit > 0 else { return nil }
        let percentPerHour = (regenRatePerHour / current.limit) * 100
        let currentPercent = current.percentRemaining

        guard currentPercent < 100 else {
            return ForecastResult(points: [], summary: "AMP: fully charged ✓")
        }

        let hoursToFull = (100 - currentPercent) / percentPerHour
        let now = Date()
        let fullDate = now.addingTimeInterval(hoursToFull * 3600)

        let steps = min(100, max(10, Int(hoursToFull * 2)))
        var points: [ForecastPoint] = []
        for i in 0...steps {
            let fraction = Double(i) / Double(steps)
            let date = now.addingTimeInterval(fraction * hoursToFull * 3600)
            let value = min(currentPercent + percentPerHour * fraction * hoursToFull, 100)
            points.append(ForecastPoint(date: date, value: value))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        return ForecastResult(
            points: points,
            summary: "AMP: reaches 100% \(formatter.string(from: fullDate))"
        )
    }

    func parseUsage(from output: String) -> UsageResult? {
        let pattern = #"Amp Free: \$([\d.]+)/\$([\d.]+) remaining"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges == 3,
              let currentRange = Range(match.range(at: 1), in: output),
              let limitRange = Range(match.range(at: 2), in: output) else {
            return nil
        }

        guard let remaining = Double(output[currentRange]),
              let limit = Double(output[limitRange]) else {
            return nil
        }

        return UsageResult(remaining: remaining, limit: limit)
    }
}