import Foundation

struct CopilotSource: AISource {
    let name = "Copilot"
    let requirements = "Requires GitHub CLI 'gh' configured and authenticated (used to fetch auth token)."
    let supportsPacingAlert = true
    func pacingLookbackStart(current: UsageResult, history: [UsageSnapshot], now: Date) -> Date? {
        current.cycleStartDate
    }

    func fetchUsage() async throws -> UsageResult {
        let token = try getGhAuthToken()

        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "GitHubAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad status code"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let quotaSnapshots = json?["quota_snapshots"] as? [String: Any],
              let premium = quotaSnapshots["premium_interactions"] as? [String: Any],
              let remaining = premium["remaining"] as? Int,
              let entitlement = premium["entitlement"] as? Int else {
            throw NSError(domain: "GitHubAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing/invalid fields"])
        }

        guard let resetDate = monthlyResetDate(),
              let cycleStartDate = monthlyCycleStartDate() else {
            throw NSError(domain: "GitHubAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to compute Copilot cycle dates"])
        }

        return UsageResult(
            remaining: Double(remaining),
            limit: Double(entitlement),
            resetDate: resetDate,
            cycleStartDate: cycleStartDate
        )
    }

    func forecast(current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        let now = Date()
        guard let resetDate = current.resetDate ?? monthlyResetDate(reference: now) else {
            return nil
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let yearMonth = calendar.dateComponents([.year, .month], from: now)
        guard let cycleStart = calendar.date(from: DateComponents(
            timeZone: utc,
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0
        )) else { return nil }

        let currentPercent = min(max(current.percentRemaining, 0), 100)
        let usedPercentSoFar = 100 - currentPercent
        let elapsedSinceCycleStart = max(now.timeIntervalSince(cycleStart), 1)
        let burnRatePerSecond = usedPercentSoFar > 0 ? (usedPercentSoFar / elapsedSinceCycleStart) : 0

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d, h:mm a"

        let preReset = resetDate.addingTimeInterval(-1)
        var points: [ForecastPoint] = [ForecastPoint(date: now, value: currentPercent)]

        let projectedPreReset: Double
        if burnRatePerSecond > 0 {
            let secondsToPreReset = max(0, preReset.timeIntervalSince(now))
            let secondsToZero = currentPercent / burnRatePerSecond
            let projectionHorizon = min(secondsToPreReset, secondsToZero)
            let steps = max(12, min(80, Int(projectionHorizon / 3600)))

            for index in 1...steps {
                let fraction = Double(index) / Double(steps)
                let date = now.addingTimeInterval(projectionHorizon * fraction)
                let value = max(currentPercent - burnRatePerSecond * date.timeIntervalSince(now), 0)
                points.append(ForecastPoint(date: date, value: value))
            }

            if secondsToZero < secondsToPreReset {
                points.append(ForecastPoint(date: preReset, value: 0))
            }

            projectedPreReset = max(currentPercent - burnRatePerSecond * secondsToPreReset, 0)
        } else {
            projectedPreReset = currentPercent
            if preReset > now {
                points.append(ForecastPoint(date: preReset, value: currentPercent))
            }
        }

        points.append(ForecastPoint(date: resetDate, value: projectedPreReset))
        points.append(ForecastPoint(date: resetDate, value: 100))

        let summary: String
        if burnRatePerSecond > 0 {
            let secondsToZero = currentPercent / burnRatePerSecond
            let zeroDate = now.addingTimeInterval(secondsToZero)
            if secondsToZero.isFinite, zeroDate > now, zeroDate < resetDate {
                summary = "Copilot: projected 0% by \(displayFormatter.string(from: zeroDate)); resets \(displayFormatter.string(from: resetDate))"
            } else {
                summary = "Copilot: projected \(String(format: "%.0f", projectedPreReset))% at reset (\(displayFormatter.string(from: resetDate)))"
            }
        } else {
            summary = "Copilot: resets \(displayFormatter.string(from: resetDate))"
        }

        return ForecastResult(points: points, summary: summary)
    }

    private func getGhAuthToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
        process.arguments = ["auth", "token"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw NSError(domain: "GitHubAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "No token from gh"])
        }

        return token
    }

    private func monthlyCycleStartDate(reference: Date = Date()) -> Date? {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let yearMonth = calendar.dateComponents([.year, .month], from: reference)
        return calendar.date(from: DateComponents(
            timeZone: utc,
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0
        ))
    }

    private func monthlyResetDate(reference: Date = Date()) -> Date? {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let cycleStart = monthlyCycleStartDate(reference: reference) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: cycleStart)
    }
}
