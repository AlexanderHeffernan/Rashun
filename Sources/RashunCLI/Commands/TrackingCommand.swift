import ArgumentParser
import Foundation
import RashunCore

@MainActor
enum TrackingCommandStore {
    static var provider: () -> TrackedUsageStore = { TrackedUsageStore.shared }
}

struct TrackingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tracking",
        abstract: "Manage shared app tracking sessions",
        subcommands: [Start.self, Stop.self, Status.self, Sessions.self, Labels.self]
    )

    func run() async throws {}

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start", abstract: "Start tracking with an existing label")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Existing label name or UUID") var label: String

        @MainActor
        func run() async throws {
            do {
                let session = try TrackingCommandStore.provider().startExistingLabel(label)
                try TrackingOutput.emit(session: session, action: "started", global: global)
            } catch let error as TrackedUsageCommandError {
                try TrackingOutput.emit(error: error, global: global)
            } catch {
                try TrackingOutput.emitPersistence(error: error, global: global)
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop", abstract: "Stop the active tracking session")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            do {
                let session = try TrackingCommandStore.provider().stopActiveSession()
                try TrackingOutput.emit(session: session, action: "stopped", global: global)
            } catch let error as TrackedUsageCommandError {
                try TrackingOutput.emit(error: error, global: global)
            } catch {
                try TrackingOutput.emitPersistence(error: error, global: global)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "Show the active tracking session")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            do {
                let session = try TrackingCommandStore.provider().readActiveSession()
                if global.json {
                    try JSONOutput.print(
                        TrackingStatusResponse(active: session != nil, session: session))
                } else if let session {
                    print(
                        "Tracking '\(session.labelNameSnapshot)' since \(session.startedAt.formatted())."
                    )
                } else {
                    print("No tracking session is active.")
                }
            } catch {
                try TrackingOutput.emitPersistence(error: error, global: global)
            }
        }
    }

    struct Sessions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sessions", abstract: "List completed tracking sessions")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            do {
                let sessions = try TrackingCommandStore.provider().readSessions()
                if global.json {
                    try JSONOutput.print(TrackingSessionsResponse(sessions: sessions))
                } else if sessions.isEmpty {
                    print("No completed tracking sessions.")
                } else {
                    for session in sessions {
                        print(
                            "\(session.id.uuidString)  \(session.labelNameSnapshot)  \(session.startedAt.formatted())  \(session.completionState.rawValue)"
                        )
                    }
                }
            } catch {
                try TrackingOutput.emitPersistence(error: error, global: global)
            }
        }
    }

    struct Labels: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "labels", abstract: "List app tracking labels")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            do {
                let labels = try TrackingCommandStore.provider().readLabels()
                if global.json {
                    try JSONOutput.print(TrackingLabelsResponse(labels: labels))
                } else if labels.isEmpty {
                    print("No tracking labels. Create one in Rashun Settings > Tracking.")
                } else {
                    for label in labels {
                        let status = label.archivedAt == nil ? "active" : "archived"
                        print("\(label.id.uuidString)  \(label.name)  \(status)")
                    }
                }
            } catch {
                try TrackingOutput.emitPersistence(error: error, global: global)
            }
        }
    }
}

enum TrackingOutput {
    @MainActor
    static func emit(session: TrackedSession, action: String, global: GlobalOptions) throws {
        if global.json {
            try JSONOutput.print(TrackingActionResponse(action: action, session: session))
        } else {
            print("Tracking \(action) for '\(session.labelNameSnapshot)'.")
        }
    }

    static func emit(error: TrackedUsageCommandError, global: GlobalOptions) throws -> Never {
        let detail = error.localizedDescription
        let code: String
        switch error {
        case .labelNotFound: code = "label_not_found"
        case .ambiguousLabel: code = "ambiguous_label"
        case .sessionAlreadyActive: code = "session_already_active"
        case .noActiveSession: code = "no_active_session"
        }
        if global.json {
            try JSONOutput.print(TrackingErrorResponse(error: .init(code: code, detail: detail)))
        } else {
            print("Error: \(detail)")
        }
        throw ExitCode(2)
    }

    static func emitPersistence(error: Error, global: GlobalOptions) throws -> Never {
        if global.json {
            try JSONOutput.print(persistenceResponse(error: error))
        } else {
            print("Error: \(error.localizedDescription)")
        }
        throw ExitCode(1)
    }

    static func persistenceResponse(error: Error) -> TrackingErrorResponse {
        TrackingErrorResponse(
            error: .init(
                code: "tracking_data_unavailable", detail: error.localizedDescription))
    }
}

private struct TrackingActionResponse: Encodable {
    let action: String
    let session: TrackedSession
}
private struct TrackingStatusResponse: Encodable {
    let active: Bool
    let session: TrackedSession?
}
private struct TrackingSessionsResponse: Encodable { let sessions: [TrackedSession] }
private struct TrackingLabelsResponse: Encodable { let labels: [TrackingLabel] }
struct TrackingErrorResponse: Encodable {
    struct Detail: Encodable {
        let code: String
        let detail: String
    }
    let error: Detail
}
