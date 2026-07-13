import Foundation

struct TailscaleServeState: Equatable, Sendable {
    let cliURL: URL
    let dnsName: String
    let isEnabled: Bool
    let hasConflictingRootHandler: Bool

    var httpsURL: URL? { URL(string: "https://\(dnsName)") }
}

struct TailscaleServeCommandError: LocalizedError, Sendable {
    let message: String
    let consentURL: URL?
    var errorDescription: String? { message }
}

enum TailscaleServeController {
    private static let managedKey = "ai.tailscaleServeManaged.v1"
    private static let expectedProxy = "http://127.0.0.1:8787"

    static func probe() async -> TailscaleServeState? {
        await Task.detached(priority: .utility) {
            guard
                let cliURL = cliCandidates.first(where: {
                    FileManager.default.isExecutableFile(atPath: $0.path)
                }),
                let status = try? run(cliURL, ["status", "--json"]), status.code == 0,
                let identity = parseIdentity(status.output), identity.running
            else { return nil }
            let serve = try? run(cliURL, ["serve", "status", "--json"])
            let configuration =
                serve.flatMap { parseServeStatus($0.output, dnsName: identity.dnsName) } ?? (
                    false, false
                )
            return TailscaleServeState(
                cliURL: cliURL, dnsName: identity.dnsName, isEnabled: configuration.0,
                hasConflictingRootHandler: configuration.1)
        }.value
    }

    static func setEnabled(_ enabled: Bool, state: TailscaleServeState) async throws
        -> TailscaleServeState
    {
        try await Task.detached(priority: .userInitiated) {
            if enabled && state.hasConflictingRootHandler {
                throw TailscaleServeCommandError(
                    message:
                        "Tailscale Serve is already using this device's root URL for another service.",
                    consentURL: nil)
            }
            if !enabled && !UserDefaults.standard.bool(forKey: managedKey) {
                throw TailscaleServeCommandError(
                    message:
                        "This HTTPS route was configured outside Rashun, so Rashun will not remove it.",
                    consentURL: nil)
            }
            let arguments = enabled ? ["serve", "--bg", "8787"] : ["serve", "--https=443", "off"]
            let result = try run(state.cliURL, arguments)
            guard result.code == 0 else {
                let output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                throw TailscaleServeCommandError(
                    message: output.nilIfEmpty
                        ?? "Tailscale could not update secure mobile access.",
                    consentURL: firstURL(in: result.output))
            }
            UserDefaults.standard.set(enabled, forKey: managedKey)
            guard let refreshed = awaitProbeSync(cliURL: state.cliURL) else {
                throw TailscaleServeCommandError(
                    message: "Tailscale updated, but Rashun could not verify the HTTPS address.",
                    consentURL: firstURL(in: result.output))
            }
            guard refreshed.isEnabled == enabled else {
                throw TailscaleServeCommandError(
                    message: enabled
                        ? "Finish enabling HTTPS in Tailscale, then Rashun will continue automatically."
                        : "Tailscale did not disable the HTTPS route.",
                    consentURL: firstURL(in: result.output))
            }
            return refreshed
        }.value
    }

    static func parseIdentity(_ data: Data) -> (dnsName: String, running: Bool)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let backend = json["BackendState"] as? String,
            let selfNode = json["Self"] as? [String: Any],
            var dnsName = selfNode["DNSName"] as? String
        else { return nil }
        while dnsName.hasSuffix(".") { dnsName.removeLast() }
        return dnsName.isEmpty ? nil : (dnsName, backend == "Running")
    }

    static func parseServeStatus(_ data: Data, dnsName: String) -> (enabled: Bool, conflict: Bool)?
    {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let web = json["Web"] as? [String: Any] ?? [:]
        let host =
            (web["\(dnsName):443"] as? [String: Any])
            ?? web.values.compactMap { $0 as? [String: Any] }.first
        let handlers = host?["Handlers"] as? [String: Any] ?? [:]
        guard let root = handlers["/"] as? [String: Any], let proxy = root["Proxy"] as? String
        else {
            return (false, false)
        }
        return (proxy == expectedProxy, proxy != expectedProxy)
    }

    private static var cliCandidates: [URL] {
        [
            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Applications/Tailscale (App Store).app/Contents/MacOS/Tailscale",
        ].map { URL(fileURLWithPath: $0) }
    }

    private static func awaitProbeSync(cliURL: URL) -> TailscaleServeState? {
        guard let status = try? run(cliURL, ["status", "--json"]), status.code == 0,
            let identity = parseIdentity(status.output), identity.running
        else { return nil }
        let serve = try? run(cliURL, ["serve", "status", "--json"])
        let configuration =
            serve.flatMap { parseServeStatus($0.output, dnsName: identity.dnsName) } ?? (
                false, false
            )
        return .init(
            cliURL: cliURL, dnsName: identity.dnsName, isEnabled: configuration.0,
            hasConflictingRootHandler: configuration.1)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (
        code: Int32, output: Data
    ) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, pipe.fileHandleForReading.readDataToEndOfFile())
    }

    private static func firstURL(in data: Data) -> URL? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"https://[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        return URL(
            string: String(text[range]).trimmingCharacters(
                in: CharacterSet(charactersIn: ".,)>\"'")))
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
