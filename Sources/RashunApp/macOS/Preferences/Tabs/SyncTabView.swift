import AppKit
import CoreImage.CIFilterBuiltins
import RashunCore
import RashunSync
import SwiftUI

@MainActor
final class SyncPreferencesViewModel: ObservableObject {
    struct PeerRow: Identifiable, Sendable {
        let peer: SyncRepository.PeerRecord
        let addresses: [SyncRepository.PeerAddress]
        var id: UUID { peer.credentialID }
        var isMobile: Bool { peer.scopes.contains(.mobileRead) }
        var isWidget: Bool { peer.scopes.contains(.widgetRead) }
        var lastActivityAt: Date? {
            ([peer.lastSeenAt] + addresses.map(\.lastSuccessAt)).compactMap { $0 }.max()
        }
        var isOnline: Bool {
            guard let lastActivityAt else { return false }
            if !isMobile && !isWidget { return peer.lastSyncError == nil }
            return Date().timeIntervalSince(lastActivityAt) < (isMobile || isWidget ? 90 : 35)
        }
        var presenceText: String {
            guard let lastActivityAt else { return "Never online" }
            let elapsed = max(0, Date().timeIntervalSince(lastActivityAt))
            let prefix = isOnline ? "Connected" : "Last online"
            if elapsed < 10 { return "\(prefix) just now" }
            if elapsed < 60 { return "\(prefix) less than a minute ago" }
            if elapsed < 3_600 {
                let minutes = Int(elapsed / 60)
                return "\(prefix) \(minutes) minute\(minutes == 1 ? "" : "s") ago"
            }
            if elapsed < 86_400 {
                let hours = Int(elapsed / 3_600)
                return "\(prefix) \(hours) hour\(hours == 1 ? "" : "s") ago"
            }
            if elapsed < 604_800 {
                let days = Int(elapsed / 86_400)
                return "\(prefix) \(days) day\(days == 1 ? "" : "s") ago"
            }
            return "\(prefix) \(lastActivityAt.formatted(date: .abbreviated, time: .shortened))"
        }
        var secondaryStatus: String {
            if isMobile {
                return peer.hasPushSubscription ? "Notifications enabled" : "Notifications off"
            }
            if isWidget { return "Read-only widget" }
            return syncStatus
        }
        var syncStatus: String {
            if let started = peer.syncStartedAt, Date().timeIntervalSince(started) < 90 {
                return "Syncing history…"
            }
            if let error = peer.lastSyncError {
                if error.contains("authorization") { return "Reconnect required" }
                if error.contains("Update both devices") { return "Version mismatch" }
                return "History sync failed"
            }
            if let imported = peer.lastSyncImported, imported > 0 {
                return "Merged \(imported) records"
            }
            if peer.lastSyncAt != nil { return "History up to date" }
            return "Waiting to sync"
        }
    }

    @Published var peers: [PeerRow] = []
    @Published var status = ""
    @Published var mobileAccess: SimplePairingAccess?
    @Published var desktopAccess: SimplePairingAccess?
    @Published var joinAddress = ""
    @Published var joinPassword = ""
    @Published var isJoining = false
    @Published var serverOnline = false
    @Published var isLoading = true
    @Published var lanAddress: String?
    @Published var tailscaleAddress: String?
    @Published var tailscaleServeState: TailscaleServeState?
    @Published var isConfiguringTailscale = false
    @Published var retryingPeerID: UUID?
    @Published var testingNotificationPeerID: UUID?
    @Published var syncMinutesText = ""
    private var repository: SyncRepository? { SyncEnvironment.shared.repository }

    init() {
        syncMinutesText = Self.formattedMinutes(SettingsStore.shared.syncInterval())
    }

    func applySyncInterval() {
        guard let minutes = Double(syncMinutesText), minutes > 0 else {
            syncMinutesText = Self.formattedMinutes(SettingsStore.shared.syncInterval())
            return
        }
        SettingsStore.shared.setSyncIntervalSeconds(minutes * 60)
        syncMinutesText = Self.formattedMinutes(SettingsStore.shared.syncInterval())
    }

    private static func formattedMinutes(_ seconds: TimeInterval) -> String {
        String(format: "%.0f", seconds / 60)
    }

    var baseURL: URL? {
        if tailscaleServeState?.isEnabled == true { return tailscaleServeState?.httpsURL }
        return lanAddress.flatMap { URL(string: "http://\($0):8787") }
    }
    var mobileURL: URL? {
        guard let baseURL, let password = mobileAccess?.password else { return nil }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts?.fragment = "pair=\(password)"
        return parts?.url
    }

    func load(syncEnabled: Bool) {
        let syncRepository = syncEnabled ? SyncEnvironment.shared.repository : nil
        isLoading = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let addresses = Host.current().addresses.filter {
                        $0.contains(".") && $0 != "127.0.0.1" && !$0.hasPrefix("169.254.")
                    }
                    let tailscaleInstalled =
                        FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
                        || FileManager.default.fileExists(
                            atPath: "/Applications/Tailscale (App Store).app")
                        || [
                            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                            "/usr/bin/tailscale",
                        ]
                        .contains { FileManager.default.fileExists(atPath: $0) }
                    let tailscale =
                        tailscaleInstalled ? addresses.first(where: Self.isTailscaleIPv4) : nil
                    let lan = addresses.first { !Self.isTailscaleIPv4($0) }
                    let rows: [PeerRow]
                    if let repository = syncRepository {
                        rows = try repository.peers().map {
                            PeerRow(
                                peer: $0,
                                addresses: try repository.addresses(credentialID: $0.credentialID))
                        }
                    } else {
                        rows = []
                    }
                    return (lan, tailscale, rows)
                }.value
                lanAddress = result.0
                tailscaleAddress = result.1
                peers = result.2
                tailscaleServeState = await TailscaleServeController.probe()
            } catch { status = error.localizedDescription }
            isLoading = false
            if mobileAccess != nil { checkServer() }
        }
    }

    func refresh() { load(syncEnabled: SettingsStore.shared.syncServerEnabled) }

    func setTailscaleHTTPS(_ enabled: Bool) {
        guard let current = tailscaleServeState, !isConfiguringTailscale else { return }
        isConfiguringTailscale = true
        status = enabled ? "Enabling secure mobile access…" : "Disabling secure mobile access…"
        Task {
            defer { isConfiguringTailscale = false }
            do {
                tailscaleServeState = try await TailscaleServeController.setEnabled(
                    enabled, state: current)
                status = enabled ? "Secure mobile access is ready." : "Secure mobile access is off."
                createMobileLink()
            } catch let error as TailscaleServeCommandError {
                status = error.message
                if let url = error.consentURL {
                    NSWorkspace.shared.open(url)
                    await waitForTailscaleHTTPS(expected: enabled)
                } else {
                    tailscaleServeState = await TailscaleServeController.probe()
                }
            } catch {
                status = error.localizedDescription
                tailscaleServeState = await TailscaleServeController.probe()
            }
        }
    }

    private func waitForTailscaleHTTPS(expected: Bool) async {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let latest = await TailscaleServeController.probe() else { continue }
            tailscaleServeState = latest
            if latest.isEnabled == expected {
                status =
                    expected ? "Secure mobile access is ready." : "Secure mobile access is off."
                createMobileLink()
                return
            }
        }
        status = "Complete the Tailscale approval, then try the switch again."
    }

    func refreshPeers() async {
        guard let repository else { return }
        do {
            peers = try await Task.detached(priority: .utility) {
                try repository.peers().map {
                    PeerRow(
                        peer: $0, addresses: try repository.addresses(credentialID: $0.credentialID)
                    )
                }
            }.value
        } catch { status = error.localizedDescription }
    }

    func createMobileLink() {
        guard let repository else { return }
        mobileAccess = nil
        Task {
            do {
                mobileAccess = try await Task.detached(priority: .userInitiated) {
                    try PairingCoordinator.simpleAccess(repository: repository, scope: .mobileRead)
                }.value
                checkServer()
            } catch { status = error.localizedDescription }
        }
    }

    func createDesktopPassword() {
        guard let repository else {
            status = "Sync storage is unavailable on this Mac."
            return
        }
        desktopAccess = nil
        Task {
            do {
                desktopAccess = try await Task.detached(priority: .userInitiated) {
                    try PairingCoordinator.simpleAccess(repository: repository, scope: .desktopSync)
                }.value
            } catch { status = "Could not prepare a pairing code: \(error.localizedDescription)" }
        }
    }

    func checkServer() {
        guard let baseURL else {
            serverOnline = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let (_, response) = try await URLSession.shared.data(from: baseURL)
                    self.serverOnline = (response as? HTTPURLResponse)?.statusCode == 200
                } catch { self.serverOnline = false }
            }
        }
    }

    func copyMobileLink() {
        guard let value = mobileURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status = "Mobile link copied."
    }

    func copyConnectionValue(_ value: String, label: String) {
        guard !value.hasPrefix("Preparing") else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status = "\(label) copied."
    }

    func pasteConnectionValue(into value: inout String, label: String) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        value = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        status = "\(label) pasted."
    }

    func joinDesktop() {
        guard !isJoining else { return }
        isJoining = true
        status = "Connecting…"
        Task {
            defer { isJoining = false }
            do {
                guard let repository else { throw URLError(.badURL) }
                let endpoint = try PeerConnectionService.normalizedURL(joinAddress)
                guard let ownAddress = baseURL else { throw URLError(.cannotFindHost) }
                let version = Versioning.versionString(bundle: .main)
                let result = try await PeerConnectionService.connect(
                    repository: repository, endpoint: endpoint, password: joinPassword,
                    requesterAddress: ownAddress, appVersion: version, trackedUsage: .live)
                joinAddress = ""
                joinPassword = ""
                refresh()
                status =
                    "Connected to \(result.peer.displayName). Usage and tracked sessions are up to date."
            } catch PeerConnectionError.versionMismatch {
                status =
                    "Both devices must be running the same Rashun version. Update Rashun on both devices, then try again."
            } catch {
                status =
                    "Could not connect. Check the address, pairing code, and that Rashun is running on the other device."
            }
        }
    }

    func retry(_ id: UUID) {
        guard let repository, retryingPeerID == nil else { return }
        retryingPeerID = id
        status = "Retrying sync…"
        Task {
            let attempts = await PeerSyncService(
                repository: repository,
                historyChanged: { @MainActor in
                    NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
                }, appVersion: Versioning.versionString(bundle: .main), trackedUsage: .live
            ).syncAllOnce()
            await refreshPeers()
            retryingPeerID = nil
            status =
                attempts.first(where: { $0.credentialID == id })?.result != nil
                ? "Usage and tracked sessions are up to date."
                : "Sync failed. Check that Rashun is running and both devices are on the same version."
        }
    }

    func sendTestNotification(to row: PeerRow) {
        guard let repository, testingNotificationPeerID == nil else { return }
        testingNotificationPeerID = row.id
        status = "Sending test notification…"
        Task {
            defer { testingNotificationPeerID = nil }
            do {
                try await WebPushSender.sendTest(
                    credentialID: row.peer.credentialID, repository: repository)
                status = "Test notification sent to \(row.peer.displayName)."
            } catch {
                status = error.localizedDescription
                await refreshPeers()
            }
        }
    }

    func copyDiagnostics(_ row: PeerRow) {
        let text = [
            "Device: \(row.peer.displayName)", "Presence: \(row.presenceText)",
            "Status: \(row.secondaryStatus)", "Error: \(row.peer.lastSyncError ?? "None")",
            "Addresses: \(row.addresses.map(\.url.absoluteString).joined(separator:", "))",
            "Last sync: \(row.peer.lastSyncAt?.description ?? "Never")",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Sync diagnostics copied."
    }

    func remove(_ id: UUID) {
        do {
            try repository?.revokePeer(credentialID: id)
            refresh()
        } catch { status = error.localizedDescription }
    }

    nonisolated private static func isTailscaleIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}

struct SyncTabView: View {
    @StateObject private var model = SyncPreferencesViewModel()
    @State private var mobileEnabled = SettingsStore.shared.syncServerEnabled
    @State private var showingAddConnection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sync").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("View your usage on your phone and keep devices up to date.")
                        .foregroundStyle(BrandPalette.textSecondary)
                }

                mobileAccessCard

                autoSyncCard

                HStack {
                    Text("Connected devices").font(.headline)
                    Spacer()
                    Button {
                        showingAddConnection.toggle()
                        if showingAddConnection {
                            model.createDesktopPassword()
                            if !mobileEnabled {
                                Task { @MainActor in
                                    // Let SwiftUI finish presenting the panel before starting the
                                    // server/Keychain lifecycle triggered by the settings change.
                                    try? await Task.sleep(for: .milliseconds(350))
                                    guard showingAddConnection else { return }
                                    mobileEnabled = true
                                }
                            }
                        }
                    } label: {
                        Label("Add desktop", systemImage: "plus.circle")
                    }
                    .buttonStyle(OutlinedBrandButtonStyle())
                }
                if model.isLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading connections…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                if showingAddConnection {
                    addDesktopCard
                }
                if !model.isLoading && model.peers.isEmpty {
                    Text("No connected devices yet.").foregroundStyle(BrandPalette.textSecondary)
                        .padding(
                            .vertical, 12)
                } else {
                    ForEach(model.peers) { row in
                        HStack(spacing: 14) {
                            BrandIconTile(
                                systemName: row.isWidget
                                    ? "rectangle.on.rectangle"
                                    : (row.isMobile ? "iphone" : "desktopcomputer"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.peer.displayName).fontWeight(.semibold)
                                HStack(spacing: 6) {
                                    Circle().fill(
                                        row.isOnline ? Color.green : BrandPalette.textSecondary
                                    ).frame(
                                        width: 7, height: 7)
                                    Text(row.presenceText)
                                    Text("·")
                                    Text(row.secondaryStatus)
                                        .foregroundStyle(
                                            row.peer.lastSyncError == nil || row.isMobile
                                                ? BrandPalette.textSecondary : BrandPalette.warning
                                        )
                                        .help(
                                            row.isMobile
                                                ? row.secondaryStatus
                                                : (row.peer.lastSyncError ?? row.secondaryStatus))
                                }.font(.caption).foregroundStyle(BrandPalette.textSecondary)
                            }
                            Spacer()
                            if row.isMobile && !row.isWidget {
                                Button {
                                    model.sendTestNotification(to: row)
                                } label: {
                                    Image(systemName: "bell.badge")
                                        .foregroundStyle(BrandPalette.primary)
                                }
                                .buttonStyle(.plain)
                                .disabled(
                                    !row.peer.hasPushSubscription
                                        || model.testingNotificationPeerID != nil
                                )
                                .help(
                                    row.peer.hasPushSubscription
                                        ? "Send test notification"
                                        : "Notifications are not enabled on this device")
                            }
                            Menu {
                                if !row.isMobile && !row.isWidget {
                                    Button(
                                        model.retryingPeerID == row.id ? "Retrying…" : "Retry sync"
                                    ) {
                                        model.retry(row.id)
                                    }
                                    .disabled(model.retryingPeerID != nil)
                                }
                                Button("Copy sync diagnostics") { model.copyDiagnostics(row) }
                                Button("Remove", role: .destructive) { model.remove(row.id) }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(
                                    BrandPalette.textSecondary)
                            }
                            .menuStyle(.borderlessButton)
                        }
                        .padding(16)
                        .background(
                            BrandPalette.card,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13).stroke(
                                BrandPalette.primary.opacity(0.18)))
                    }
                }
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(
                .vertical, 4)
        }
        .onAppear {
            model.load(syncEnabled: mobileEnabled)
            if mobileEnabled { model.createMobileLink() }
        }
        .task(id: mobileEnabled) {
            guard mobileEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await model.refreshPeers()
            }
        }
    }

    private var autoSyncCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            BrandIconTile(systemName: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 4) {
                Text("Automatic desktop sync").font(.headline)
                Text("Sync usage history, completed tracked sessions, and labels every")
                    .font(.caption).foregroundStyle(BrandPalette.textSecondary)
            }
            Spacer()
            BrandNumericField(text: $model.syncMinutesText, width: 76) {
                model.applySyncInterval()
            }
            Text("minute(s)").fontWeight(.medium)
        }
        .padding(18)
        .background(BrandPalette.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(BrandPalette.primary.opacity(0.2)))
    }

    private var mobileAccessCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandIconTile(systemName: "iphone")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mobile access").font(.headline)
                    if mobileEnabled {
                        HStack(spacing: 6) {
                            Circle().fill(
                                model.serverOnline
                                    ? BrandPalette.accent : BrandPalette.textSecondary
                            )
                            .frame(width: 8, height: 8)
                            Text(model.serverOnline ? "Online" : "Starting…")
                        }.font(.caption).foregroundStyle(
                            model.serverOnline ? BrandPalette.accent : BrandPalette.textSecondary)
                    }
                }
                Spacer()
                Text("Enable Mobile Access").fontWeight(.semibold)
                Toggle("", isOn: $mobileEnabled).labelsHidden().toggleStyle(.switch)
                    .onChange(of: mobileEnabled) { _, enabled in
                        SettingsStore.shared.setSyncServerEnabled(enabled)
                        if enabled {
                            model.load(syncEnabled: true)
                            model.createMobileLink()
                        } else {
                            model.mobileAccess = nil
                            model.peers = []
                        }
                        DispatchQueue.main.async {
                            PreferencesWindowController.shared.bringToFront()
                        }
                    }
            }.padding(18)

            if mobileEnabled {
                Divider().opacity(0.35)
                if let access = model.mobileAccess, let link = model.mobileURL {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 14) {
                            if let tailscale = model.tailscaleServeState {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Secure mobile access").fontWeight(.semibold)
                                            Text(
                                                tailscale.isEnabled
                                                    ? "HTTPS through Tailscale"
                                                    : "Enable HTTPS for notifications"
                                            )
                                            .font(.caption).foregroundStyle(
                                                BrandPalette.textSecondary)
                                        }
                                        Spacer()
                                        if model.isConfiguringTailscale {
                                            ProgressView().controlSize(.small)
                                        }
                                        Toggle(
                                            "",
                                            isOn: Binding(
                                                get: {
                                                    model.tailscaleServeState?.isEnabled == true
                                                },
                                                set: { model.setTailscaleHTTPS($0) }
                                            )
                                        ).labelsHidden().toggleStyle(.switch).disabled(
                                            model.isConfiguringTailscale
                                                || tailscale.hasConflictingRootHandler)
                                    }
                                    if tailscale.hasConflictingRootHandler {
                                        Text(
                                            "Tailscale Serve is already being used by another service on this Mac."
                                        )
                                        .font(.caption).foregroundStyle(BrandPalette.warning)
                                    } else if tailscale.isEnabled, let url = tailscale.httpsURL {
                                        Text(url.absoluteString).font(.caption).monospaced()
                                            .foregroundStyle(
                                                BrandPalette.accent
                                            ).textSelection(.enabled)
                                    }
                                }
                            }
                            Button {
                                model.copyMobileLink()
                            } label: {
                                Label("Copy Link", systemImage: "link")
                            }
                            .buttonStyle(.bordered)
                            Label(
                                "Link expires at \(access.expiresAt.formatted(date: .omitted, time: .shortened))",
                                systemImage: "clock"
                            )
                            .font(.caption).foregroundStyle(BrandPalette.textSecondary)
                            Divider().opacity(0.3)
                            Button {
                                model.createMobileLink()
                            } label: {
                                Label("Refresh link", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.plain).foregroundStyle(BrandPalette.primary)
                            HStack(spacing: 6) {
                                Text("Pairing code").foregroundStyle(BrandPalette.textSecondary)
                                Text(access.password).monospaced().textSelection(.enabled)
                            }.font(.caption)
                        }.frame(maxWidth: 310, alignment: .leading)

                        Divider().padding(.vertical, 8)

                        HStack(spacing: 20) {
                            QRCodeView(value: link.absoluteString).frame(width: 150, height: 150)
                                .padding(8)
                                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 8) {
                                BrandIconTile(systemName: "iphone")
                                Text("Scan with your\nphone to open Rashun").font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 178)
                        .padding(14)
                        .background(
                            BrandPalette.background.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 13)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13).stroke(
                                BrandPalette.primary.opacity(0.75)))
                    }.padding(18)
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Preparing mobile access…").foregroundStyle(BrandPalette.textSecondary)
                        Spacer()
                    }.padding(30)
                }
            }
        }
        .background(BrandPalette.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(BrandPalette.primary.opacity(0.2)))
    }

    private var addDesktopCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect two desktops").font(.headline)
                Text(
                    "Choose either option below. You only need to connect once—Rashun will sync both ways automatically."
                )
                .font(.caption).foregroundStyle(BrandPalette.textSecondary)
            }

            HStack(alignment: .top, spacing: 14) {
                connectionOption(
                    number: "1", title: "Share this device’s details",
                    subtitle: "On your other device, enter this address and code."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        connectionValue(
                            label: "Address",
                            value: model.baseURL?.absoluteString ?? "Preparing address…",
                            onCopy: { value in model.copyConnectionValue(value, label: "Address") })
                        connectionValue(
                            label: "Pairing code",
                            value: model.desktopAccess?.password ?? "Preparing code…",
                            onCopy: { value in
                                model.copyConnectionValue(value, label: "Pairing code")
                            })
                        if let expiry = model.desktopAccess?.expiresAt {
                            Text(
                                "Code expires at \(expiry.formatted(date: .omitted, time: .shortened))"
                            )
                            .font(.caption2).foregroundStyle(BrandPalette.textSecondary)
                        }
                    }
                }

                connectionOption(
                    number: "2", title: "Enter another device’s details",
                    subtitle: "Use the address and code displayed on your other device."
                ) {
                    VStack(spacing: 10) {
                        styledField(
                            icon: "network", placeholder: "IP address or URL",
                            text: $model.joinAddress,
                            onPaste: {
                                model.pasteConnectionValue(
                                    into: &model.joinAddress, label: "Address")
                            })
                        styledSecureField(
                            icon: "key", placeholder: "Pairing code", text: $model.joinPassword,
                            onPaste: {
                                model.pasteConnectionValue(
                                    into: &model.joinPassword, label: "Pairing code")
                            })
                        Button(model.isJoining ? "Connecting…" : "Connect desktops") {
                            model.joinDesktop()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BrandPalette.primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(
                            model.joinAddress.isEmpty || model.joinPassword.isEmpty
                                || model.isJoining)
                    }
                }
            }
        }
        .padding(16)
        .background(BrandPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(BrandPalette.primary.opacity(0.2)))
    }

    private func connectionOption<Content: View>(
        number: String, title: String, subtitle: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Text(number).font(.caption.bold()).foregroundStyle(.white).frame(
                    width: 23, height: 23
                )
                .background(BrandPalette.primary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(BrandPalette.textSecondary)
                        .fixedSize(
                            horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(BrandPalette.background.opacity(0.38), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BrandPalette.primary.opacity(0.18)))
    }

    private func connectionValue(
        label: String, value: String, onCopy: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(
                BrandPalette.textSecondary)
            HStack(spacing: 6) {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Button {
                    onCopy(value)
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandPalette.primary)
                .disabled(value.hasPrefix("Preparing"))
                .help("Copy \(label.lowercased())")
                .accessibilityLabel("Copy \(label.lowercased())")
            }
            .padding(.leading, 11).padding(.trailing, 5).frame(
                maxWidth: .infinity, minHeight: 34, alignment: .leading
            )
            .background(BrandPalette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BrandPalette.primary.opacity(0.25)))
        }
    }

    private func styledField(
        icon: String, placeholder: String, text: Binding<String>, onPaste: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(BrandPalette.textSecondary)
            TextField(placeholder, text: text).textFieldStyle(.plain)
                .contextMenu { Button("Paste", action: onPaste) }
            pasteButton(action: onPaste, label: placeholder)
        }
        .padding(.horizontal, 11).frame(minHeight: 36).background(
            BrandPalette.card, in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BrandPalette.primary.opacity(0.25)))
    }

    private func styledSecureField(
        icon: String, placeholder: String, text: Binding<String>, onPaste: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(BrandPalette.textSecondary)
            SecureField(placeholder, text: text).textFieldStyle(.plain)
                .contextMenu { Button("Paste", action: onPaste) }
            pasteButton(action: onPaste, label: placeholder)
        }
        .padding(.horizontal, 11).frame(minHeight: 36).background(
            BrandPalette.card, in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BrandPalette.primary.opacity(0.25)))
    }

    private func pasteButton(action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.clipboard").frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(BrandPalette.primary)
        .help("Paste \(label.lowercased())")
        .accessibilityLabel("Paste \(label.lowercased())")
    }
}

private struct BrandIconTile: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 18, weight: .medium)).foregroundStyle(
            .white
        )
        .frame(width: 42, height: 42)
        .background(BrandPalette.primary.opacity(0.28), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BrandPalette.primary.opacity(0.7)))
    }
}

private struct OutlinedBrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(BrandPalette.primary)
            .background(
                BrandPalette.card.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BrandPalette.primary.opacity(0.65)))
    }
}

private struct QRCodeView: View {
    let value: String
    var body: some View {
        if let image { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() }
    }
    private var image: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: .init(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
