import ArgumentParser
import Foundation
import RashunCore
import RashunSync
import RashunSyncServer

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Connect and manage Rashun devices",
        discussion: """
            On the device that will accept a connection, run `rashun sync serve`.
            On the other device, run the connect command printed by the server.
            Keep `rashun sync serve` running on CLI-only devices for automatic syncing.
            """,
        subcommands: [
            Serve.self, Connect.self, Devices.self, Remove.self, SyncNow.self, Pair.self,
        ])

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve", abstract: "Keep this device available for syncing")

        @Option(help: "Interface to listen on") var host = "0.0.0.0"
        @Option(help: "Port to listen on") var port = 8787
        @Option(
            name: .customLong("address"),
            help: "Address other devices should use, if automatic detection is incorrect")
        var advertisedAddress: String?
        @Option(help: "Directory containing the mobile web app") var webRoot: String?
        @Option(help: "PEM certificate chain") var tlsCertificate: String?
        @Option(help: "PEM private key") var tlsPrivateKey: String?
        @Flag(help: "Start without creating a new pairing code") var noPairingCode = false

        @MainActor
        func run() async throws {
            guard (1...65_535).contains(port) else {
                throw ValidationError("Port must be between 1 and 65535.")
            }
            guard (tlsCertificate == nil) == (tlsPrivateKey == nil) else {
                throw ValidationError(
                    "--tls-certificate and --tls-private-key must be supplied together.")
            }
            let repository = try syncRepository()
            let secure = tlsCertificate != nil
            let endpoint =
                try advertisedAddress.map(PeerConnectionService.normalizedURL)
                ?? LocalNetworkEndpoint.preferredURL(port: port, secure: secure)
            let access =
                noPairingCode
                ? nil
                : try PairingCoordinator.simpleAccess(
                    repository: repository, scope: .desktopSync)

            print("Rashun sync is running on this device.")
            if let endpoint {
                print("Address: \(endpoint.absoluteString)")
                if let access {
                    print("Pairing code: \(access.password)")
                    print("")
                    print("On the other device, run:")
                    print("  rashun sync connect \(endpoint.absoluteString) \(access.password)")
                }
            } else {
                print("Rashun could not detect a LAN address.")
                print("Restart with --address http://<this-device-ip>:\(port)")
                if let access { print("Pairing code: \(access.password)") }
            }
            if !secure && host != "127.0.0.1" && host != "::1" {
                print("")
                print("Use this only on a trusted private network. Press Ctrl-C to stop.")
            } else {
                print("Press Ctrl-C to stop.")
            }

            let syncTask = Task {
                await PeerSyncService(
                    repository: repository,
                    historyChanged: { @MainActor in
                        try? SyncEnvironment.shared.refreshCompatibilityView()
                    }, appVersion: Versioning.versionString(), trackedUsage: .live
                ).runForeground()
            }
            defer { syncTask.cancel() }
            let root = webRoot ?? FileManager.default.currentDirectoryPath + "/Web/RashunMobile"
            let tls = tlsCertificate.map {
                RashunSyncServer.TLSFiles(certificateChain: $0, privateKey: tlsPrivateKey!)
            }
            let advertiser = BonjourAdvertiser()
            advertiser.start(name: repository.identity.displayName, port: port)
            defer { advertiser.stop() }
            try await RashunSyncServer(
                repository: repository, host: host, port: port,
                webRoot: FileManager.default.fileExists(atPath: root) ? root : nil,
                tlsFiles: tls, appVersion: Versioning.versionString()
            ).run()
        }
    }

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "connect", abstract: "Connect this device using a pairing code")

        @Argument(help: "Address shown by `rashun sync serve`") var address: String
        @Argument(help: "Eight-character pairing code") var code: String
        @Option(
            name: .customLong("this-device"),
            help: "Address of this device, if automatic detection is incorrect")
        var thisDeviceAddress: String?
        @Option(help: "Port used by `rashun sync serve` on this device") var port = 8787

        @MainActor
        func run() async throws {
            let repository = try syncRepository()
            let endpoint = try PeerConnectionService.normalizedURL(address)
            let ownEndpoint =
                try thisDeviceAddress.map(PeerConnectionService.normalizedURL)
                ?? LocalNetworkEndpoint.preferredURL(port: port)
            print("Connecting to \(endpoint.absoluteString)…")
            do {
                let result = try await PeerConnectionService.connect(
                    repository: repository, endpoint: endpoint, password: code,
                    requesterAddress: ownEndpoint, appVersion: Versioning.versionString(),
                    trackedUsage: .live)
                if result.sync.accepted > 0 {
                    try SyncEnvironment.shared.refreshCompatibilityView()
                }
                print("Connected to \(result.peer.displayName). Histories are up to date.")
                if ownEndpoint == nil {
                    print(
                        "Run `rashun sync serve --address http://<this-device-ip>:\(port)` so the other device can sync back."
                    )
                } else {
                    print("Run `rashun sync serve` to keep automatic syncing available.")
                }
            } catch PeerConnectionError.versionMismatch {
                throw ValidationError(
                    "Both devices must run the same Rashun version. Update them and try again.")
            } catch PeerConnectionError.pairingRejected {
                throw ValidationError("The pairing code is invalid, expired, or already used.")
            }
        }
    }

    struct Devices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "devices", abstract: "List connected devices", aliases: ["peers"])

        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            let repository = try syncRepository()
            let peers = try repository.peers()
            if global.json {
                try JSONOutput.print(
                    peers.map {
                        DeviceOutput(
                            id: $0.credentialID, name: $0.displayName,
                            scopes: $0.scopes.map(\.rawValue).sorted(), lastSeenAt: $0.lastSeenAt,
                            lastSyncAt: $0.lastSyncAt, lastSyncError: $0.lastSyncError)
                    })
                return
            }
            guard !peers.isEmpty else {
                print("No connected devices.")
                print("Run `rashun sync serve` on one device to get started.")
                return
            }
            for peer in peers {
                let kind = peer.scopes.contains(.mobileRead) ? "mobile" : "desktop"
                print("\(peer.displayName)  [\(kind)]")
                print("  ID: \(peer.credentialID)")
                if let date = peer.lastSyncAt {
                    print("  Last sync: \(date.formatted())")
                } else {
                    print("  Last sync: not yet")
                }
                if let error = peer.lastSyncError { print("  Status: \(error)") }
            }
        }

        private struct DeviceOutput: Encodable {
            let id: UUID
            let name: String
            let scopes: [String]
            let lastSeenAt: Date?
            let lastSyncAt: Date?
            let lastSyncError: String?
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Disconnect a device")

        @Argument(help: "Device name or ID from `rashun sync devices`") var device: String

        @MainActor
        func run() async throws {
            let repository = try syncRepository()
            let peer = try resolvePeer(device, repository: repository)
            try repository.revokePeer(credentialID: peer.credentialID)
            print("Removed \(peer.displayName).")
        }
    }

    struct SyncNow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync-now", abstract: "Sync all connected devices now", aliases: ["now"])

        @MainActor
        func run() async throws {
            let repository = try syncRepository()
            let attempts = await PeerSyncService(
                repository: repository,
                historyChanged: { @MainActor in
                    try? SyncEnvironment.shared.refreshCompatibilityView()
                }, appVersion: Versioning.versionString(), trackedUsage: .live
            ).syncAllOnce()
            guard !attempts.isEmpty else {
                print("No desktop devices are connected.")
                return
            }
            var failed = false
            for attempt in attempts {
                let name =
                    (try? repository.peers().first { $0.credentialID == attempt.credentialID }?
                        .displayName) ?? attempt.credentialID.uuidString
                if let result = attempt.result {
                    print("\(name): up to date (\(result.accepted) new records)")
                } else {
                    failed = true
                    print("\(name): \(attempt.errorDescription ?? "sync failed")")
                }
            }
            if failed { throw ExitCode.failure }
        }
    }

    struct Pair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pair", abstract: "Create another pairing code")

        @MainActor
        func run() async throws {
            let access = try PairingCoordinator.simpleAccess(
                repository: syncRepository(), scope: .desktopSync)
            print("Pairing code: \(access.password)")
            print("Expires in 15 minutes and can be used once.")
        }
    }

    @MainActor
    private static func syncRepository() throws -> SyncRepository {
        guard let repository = SyncEnvironment.shared.repository else {
            throw SyncEnvironment.shared.startupError ?? CocoaError(.fileReadUnknown)
        }
        return repository
    }

    @MainActor
    private static func resolvePeer(_ value: String, repository: SyncRepository) throws
        -> SyncRepository.PeerRecord
    {
        let peers = try repository.peers()
        if let id = UUID(uuidString: value),
            let peer = peers.first(where: { $0.credentialID == id })
        {
            return peer
        }
        let matches = peers.filter {
            $0.displayName.localizedCaseInsensitiveCompare(value) == .orderedSame
        }
        guard matches.count == 1, let peer = matches.first else {
            let message =
                matches.isEmpty
                ? "No connected device named '\(value)'."
                : "More than one device has that name; use the ID from `rashun sync devices`."
            throw ValidationError(message)
        }
        return peer
    }
}
