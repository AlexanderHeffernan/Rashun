import Foundation

public struct HelloDTO: Codable, Sendable { public let deviceID: UUID; public let epoch: UUID; public let protocolMinimum: Int; public let protocolMaximum: Int; public let serverTime: Date; public let maximumBatch: Int; public let appVersion:String?; public init(deviceID:UUID,epoch:UUID,protocolMinimum:Int,protocolMaximum:Int,serverTime:Date,maximumBatch:Int,appVersion:String?=nil){self.deviceID=deviceID;self.epoch=epoch;self.protocolMinimum=protocolMinimum;self.protocolMaximum=protocolMaximum;self.serverTime=serverTime;self.maximumBatch=maximumBatch;self.appVersion=appVersion} }
public struct ObservationQuery: Codable, Sendable { public let protocolVersion: Int; public let requests: [OriginRangeRequest]; public let limit: Int; public let pageToken: String?; public init(protocolVersion:Int,requests:[OriginRangeRequest],limit:Int,pageToken:String?){self.protocolVersion=protocolVersion;self.requests=requests;self.limit=limit;self.pageToken=pageToken} }
public struct OriginRangeRequest: Codable, Sendable, Equatable { public let origin: OriginID; public let range: SequenceRange; public init(origin:OriginID,range:SequenceRange){self.origin=origin;self.range=range} }
public struct ObservationPage: Codable, Sendable { public let observations: [UsageObservation]; public let nextPageToken: String?; public init(observations:[UsageObservation],nextPageToken:String?){self.observations=observations;self.nextPageToken=nextPageToken} }
public struct IngestAcknowledgement: Codable, Sendable { public let accepted: [UUID]; public let duplicates: [UUID]; public let rejected: [RejectedObservation]; public let origins: [OriginSummary]; public init(accepted:[UUID],duplicates:[UUID],rejected:[RejectedObservation],origins:[OriginSummary]){self.accepted=accepted;self.duplicates=duplicates;self.rejected=rejected;self.origins=origins} }
public struct RejectedObservation: Codable, Sendable { public let id: UUID; public let code: String }

public enum RangePlanner {
    public static func missing(local: [OriginSummary], remote: [OriginSummary]) -> [OriginRangeRequest] {
        let localByOrigin = Dictionary(uniqueKeysWithValues: local.map { ($0.origin, $0) })
        return remote.flatMap { remoteOrigin -> [OriginRangeRequest] in
            let have = localByOrigin[remoteOrigin.origin]
            var requests: [OriginRangeRequest] = []
            let start = (have?.contiguousThrough ?? 0) + 1
            if start <= remoteOrigin.maximum { requests.append(.init(origin: remoteOrigin.origin, range: .init(from: start, through: remoteOrigin.maximum))) }
            if let have { requests.append(contentsOf: have.gaps.compactMap { gap in
                let upper = min(gap.through, remoteOrigin.maximum); return gap.from <= upper ? .init(origin: remoteOrigin.origin, range: .init(from: gap.from, through: upper)) : nil
            }) }
            return requests
        }
    }
}

public protocol SyncPeerTransport: Sendable {
    func hello() async throws -> HelloDTO
    func origins() async throws -> [OriginSummary]
    func query(_ request: ObservationQuery) async throws -> ObservationPage
    func ingest(_ observations:[UsageObservation]) async throws -> IngestAcknowledgement
}

public struct SyncResult: Sendable { public let accepted: Int; public let duplicates: Int; public let pages: Int }
public struct SyncCoordinator: Sendable {
    private let repository: SyncRepository
    private let requiredAppVersion:String?
    public init(repository: SyncRepository, requiredAppVersion:String?=nil) { self.repository = repository;self.requiredAppVersion=requiredAppVersion }
    public func pull(from peer: any SyncPeerTransport) async throws -> SyncResult {
        let hello = try await compatibleHello(from: peer)
        return try await pullMissing(from: peer, hello: hello, remote: try await peer.origins())
    }

    /// Reconcile in both directions over one authenticated channel. This keeps peers converged even
    /// when only one device can initiate connections (firewall, DHCP, or a stale return route).
    public func reconcile(with peer:any SyncPeerTransport) async throws -> SyncResult {
        let hello=try await compatibleHello(from:peer),remoteBefore=try await peer.origins()
        let pulled=try await pullMissing(from:peer,hello:hello,remote:remoteBefore)
        let local=try repository.originSummaries()
        for request in RangePlanner.missing(local:remoteBefore,remote:local) {
            var next=request.range.from
            while next <= request.range.through {
                let end=min(request.range.through,next+499)
                let values=try repository.observations(origin:request.origin,range:.init(from:next,through:end),limit:500)
                if !values.isEmpty {_ = try await peer.ingest(values)}
                if end == UInt64.max { break };next=end+1
            }
        }
        return pulled
    }

    private func compatibleHello(from peer:any SyncPeerTransport)async throws->HelloDTO {
        let hello = try await peer.hello(); guard hello.protocolMinimum <= 1, hello.protocolMaximum >= 1 else { throw SyncValidationError.incompatibleProtocol }
        if let requiredAppVersion, hello.appVersion != requiredAppVersion { throw DesktopSyncCompatibilityError.versionMismatch(local:requiredAppVersion,remote:hello.appVersion) }
        return hello
    }
    private func pullMissing(from peer:any SyncPeerTransport,hello:HelloDTO,remote:[OriginSummary])async throws->SyncResult {
        var accepted = 0, duplicates = 0, pages = 0
        for request in RangePlanner.missing(local: try repository.originSummaries(), remote: remote) {
            var token: String?
            repeat {
                let page = try await peer.query(.init(protocolVersion: 1, requests: [request], limit: min(500, hello.maximumBatch), pageToken: token))
                let result = try repository.ingest(page.observations); accepted += result.accepted; duplicates += result.duplicates; pages += 1; token = page.nextPageToken
            } while token != nil
        }
        return .init(accepted: accepted, duplicates: duplicates, pages: pages)
    }
}

public enum DesktopSyncCompatibilityError:Error,Equatable,Sendable {case versionMismatch(local:String,remote:String?)}
