import ArgumentParser
import Foundation
import RashunCore
import RashunSync
import RashunSyncServer

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync", abstract: "Manage local multi-device synchronization",
        subcommands: [
            Address.self, Approve.self, Diagnostics.self, Invite.self, Join.self, Peers.self,
            Probe.self,
            Pull.self, Revoke.self, Rotate.self, Serve.self,
        ])
    struct Peers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "peers", abstract: "List paired peers and candidate addresses")
        @MainActor func run() async throws {
            guard let repo = SyncEnvironment.shared.repository else {
                throw ValidationError("Repository unavailable")
            }
            for peer in try repo.peers(includeRevoked: true) {
                print(
                    "\(peer.credentialID)  \(peer.displayName)  \(peer.scopes.map(\.rawValue).sorted().joined(separator:","))\(peer.revokedAt == nil ? "" : "  REVOKED")"
                )
                for address in try repo.addresses(credentialID: peer.credentialID) {
                    print("  \(address.kind.rawValue): \(address.url.absoluteString)")
                }
            }
        }
    }
    struct Probe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "probe", abstract: "Test each stage of an existing desktop connection")
        @MainActor func run() async throws {
            guard let repo = SyncEnvironment.shared.repository else {
                throw ValidationError("Repository unavailable")
            }
            for peer in try repo.peers() where peer.scopes.contains(.desktopSync) {
                guard let credential = try repo.peerCredential(id: peer.credentialID) else {
                    continue
                }
                for address in try repo.addresses(credentialID: peer.credentialID) {
                    let transport = try HTTPPeerTransport(
                        baseURL: address.url, credential: credential)
                    do {
                        let hello = try await transport.hello()
                        print(
                            "\(peer.displayName): hello OK (Rashun \(hello.appVersion ?? "unknown"))"
                        )
                        let origins = try await transport.origins()
                        print("\(peer.displayName): origins OK (\(origins.count))")
                        _ = try await SyncCoordinator(
                            repository: repo, requiredAppVersion: Versioning.versionString()
                        ).reconcile(with: transport)
                        print("\(peer.displayName): reconcile OK")
                    } catch { print("\(peer.displayName): FAILED \(String(reflecting:error))") }
                }
            }
        }
    }
    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke", abstract: "Revoke a paired credential")
        @Argument var credentialID: String
        @MainActor func run() async throws {
            guard let id = UUID(uuidString: credentialID),
                let repo = SyncEnvironment.shared.repository
            else { throw ValidationError("Invalid credential") }
            try repo.revokePeer(credentialID: id)
            print("Revoked \(id)")
        }
    }
    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Rotate a paired desktop credential over its authenticated connection")
        @Argument var credentialID: String
        @MainActor func run() async throws {
            guard let id = UUID(uuidString: credentialID),
                let repo = SyncEnvironment.shared.repository,
                let old = try repo.peerCredential(id: id),
                let address = try repo.addresses(credentialID: id).first?.url
            else { throw ValidationError("Active credential with an address is required") }
            let fresh = try await HTTPPeerTransport(baseURL: address, credential: old).rotate()
            try repo.replacePeerCredential(oldID: id, with: fresh)
            print("Rotated \(id) to \(fresh.id)")
        }
    }
    struct Address: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "address", abstract: "Add a peer address")
        @Argument var credentialID: String
        @Argument var address: String
        @MainActor func run() async throws {
            guard let id = UUID(uuidString: credentialID),
                let repo = SyncEnvironment.shared.repository
            else { throw ValidationError("Invalid credential") }
            let url = try ManualPeerAddress.validate(address, allowLoopbackHTTP: true)
            try repo.saveAddress(credentialID: id, url: url, kind: .manual)
            print("Saved address \(url)")
        }
    }
    struct Invite: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "invite", abstract: "Create a secure two-minute pairing invitation")
        @Option(help: "desktopSync or mobileRead") var scope = "desktopSync"
        @MainActor func run() async throws {
            guard let value = PeerCredential.Scope(rawValue: scope),
                let repo = SyncEnvironment.shared.repository
            else { throw ValidationError("Invalid scope or unavailable repository") }
            let invite = try PairingCoordinator.invite(repository: repo, scope: value)
            let data = try JSONEncoder().encode(invite)
            print(data.base64EncodedString())
        }
    }
    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "approve", abstract: "Explicitly approve a pending pairing request")
        @Argument var sessionID: String
        @MainActor func run() async throws {
            guard let id = UUID(uuidString: sessionID), let repo = SyncEnvironment.shared.repository
            else { throw ValidationError("Invalid session") }
            let credential = try repo.approvePairingSession(id: id)
            print("Approved \(credential.id). The requester may now complete pairing.")
        }
    }
    struct Join: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "join", abstract: "Join a desktop using its invitation")
        @Argument var address: String
        @Argument var invitation: String
        @Flag var complete = false
        @MainActor func run() async throws {
            guard let url = URL(string: address), let data = Data(base64Encoded: invitation),
                let repo = SyncEnvironment.shared.repository
            else { throw ValidationError("Invalid address or invitation") }
            let decoder = JSONDecoder()
            let invite = try decoder.decode(PairingInvitation.self, from: data)
            if !complete {
                _ = try await PairingHTTPClient.exchange(
                    invitation: invite, with: url, requester: repo.identity)
                print(
                    "Pairing awaits explicit approval on \(address). Re-run with --complete after approval."
                )
                return
            }
            let status = try await PairingHTTPClient.complete(invitation: invite, with: url)
            guard let credential = status.credential else {
                throw ValidationError("Pairing has not been approved or has expired")
            }
            let hello = try await HTTPPeerTransport(baseURL: url, credential: credential).hello()
            try repo.savePeer(
                credential, deviceID: hello.deviceID, epoch: hello.epoch,
                displayName: url.host ?? "Paired desktop")
            print(
                "Paired with \(hello.deviceID) using \(credential.scopes.map(\.rawValue).joined(separator:",")) scope"
            )
        }
    }
    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Pull all missing canonical observations from a paired desktop"
        )
        @Argument(help: "Peer URL") var address: String
        @Option(help: "Credential UUID") var credentialID: String
        @MainActor func run() async throws {
            guard let id = UUID(uuidString: credentialID),
                let secretText = ProcessInfo.processInfo.environment["RASHUN_SYNC_SECRET"],
                let secret = Data(base64Encoded: secretText), let url = URL(string: address),
                let repository = SyncEnvironment.shared.repository
            else {
                throw ValidationError("Set a valid --credential-id and base64 RASHUN_SYNC_SECRET")
            }
            let transport = try HTTPPeerTransport(
                baseURL: url, credential: .init(id: id, secret: secret, scopes: [.desktopSync]))
            let result = try await SyncCoordinator(repository: repository).pull(from: transport)
            try SyncEnvironment.shared.refreshCompatibilityView()
            print(
                "Sync complete: \(result.accepted) accepted, \(result.duplicates) duplicates across \(result.pages) pages"
            )
        }
    }
    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve", abstract: "Run the authenticated sync API")
        @Option(help: "Private interface address to bind") var host = "127.0.0.1"
        @Option(help: "TCP port") var port = 8787
        @Option(help: "Directory containing the mobile PWA shell") var webRoot: String?
        @Option(help: "Exact browser origin allowed to call the read-only API") var allowedOrigin:
            String?
        @Option(help: "PEM certificate chain required for non-loopback binding") var tlsCertificate:
            String?
        @Option(help: "PEM private key required for non-loopback binding") var tlsPrivateKey:
            String?
        @Flag(
            help:
                "Acknowledge that non-loopback binding requires a private interface and firewall rule"
        )
        var allowPrivateInterface = false
        @MainActor func run() async throws {
            guard host == "127.0.0.1" || host == "::1" || allowPrivateInterface else {
                throw ValidationError("Non-loopback binding requires --allow-private-interface")
            }
            let loopback = host == "127.0.0.1" || host == "::1"
            guard loopback || (tlsCertificate != nil && tlsPrivateKey != nil) else {
                throw ValidationError(
                    "Non-loopback binding requires --tls-certificate and --tls-private-key")
            }
            guard (tlsCertificate == nil) == (tlsPrivateKey == nil) else {
                throw ValidationError("TLS certificate and private key must be supplied together")
            }
            guard let repository = SyncEnvironment.shared.repository else {
                throw SyncEnvironment.shared.startupError ?? CocoaError(.fileReadUnknown)
            }
            print("Rashun authenticated sync API listening on \(host):\(port)")
            let advertiser = BonjourAdvertiser()
            advertiser.start(name: repository.identity.displayName, port: port)
            let root = webRoot ?? FileManager.default.currentDirectoryPath + "/Web/RashunMobile"
            if let allowedOrigin {
                guard let origin = URL(string: allowedOrigin), origin.scheme == "https",
                    origin.path.isEmpty || origin.path == "/"
                else {
                    throw ValidationError(
                        "--allowed-origin must be an exact HTTPS origin without a path")
                }
            }
            let tls = tlsCertificate.map {
                RashunSyncServer.TLSFiles(certificateChain: $0, privateKey: tlsPrivateKey!)
            }
            try await RashunSyncServer(
                repository: repository, host: host, port: port,
                webRoot: FileManager.default.fileExists(atPath: root) ? root : nil,
                allowedBrowserOrigin: allowedOrigin, tlsFiles: tls
            ).run()
        }
    }
    struct Diagnostics: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "diagnostics", abstract: "Show canonical storage and origin state")
        @OptionGroup var global: GlobalOptions
        @MainActor func run() async throws {
            guard let repository = SyncEnvironment.shared.repository else {
                throw SyncEnvironment.shared.startupError ?? CocoaError(.fileReadUnknown)
            }
            let observations = try repository.allObservations()
            let origins = try repository.originSummaries()
            if global.json {
                try JSONOutput.print(
                    Output(
                        deviceID: repository.identity.deviceID, epoch: repository.identity.epoch,
                        observations: observations.count, origins: origins))
                return
            }
            print("Device: \(repository.identity.displayName) (\(repository.identity.deviceID))")
            print("Canonical observations: \(observations.count)")
            for origin in origins {
                print(
                    "  \(origin.origin.deviceID)/\(origin.origin.epoch): \(origin.minimum)...\(origin.maximum), contiguous \(origin.contiguousThrough), gaps \(origin.gaps.count)"
                )
            }
        }
        private struct Output: Encodable {
            let deviceID: UUID
            let epoch: UUID
            let observations: Int
            let origins: [OriginSummary]
        }
    }
}
