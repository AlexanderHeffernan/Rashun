import Foundation
import GRDB
import Crypto
import RashunCore

public final class SyncRepository: @unchecked Sendable {
    private let db: DatabasePool
    private let secrets:SecretProtector
    public let identity: DeviceIdentity

    public init(path: String, displayName: String = Host.current().localizedName ?? "Rashun device") throws {
        let secretProtector=try SecretProtector(storageDirectory:URL(fileURLWithPath:path).deletingLastPathComponent());secrets=secretProtector
        var config = Configuration(); config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000") }
        db = try DatabasePool(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("sync-v1") { db in
            try db.execute(sql: """
            CREATE TABLE device_identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), device_id TEXT NOT NULL, epoch TEXT NOT NULL, display_name TEXT NOT NULL, public_key BLOB NOT NULL, next_sequence INTEGER NOT NULL CHECK(next_sequence>0));
            CREATE TABLE observations (id TEXT PRIMARY KEY, origin_device_id TEXT NOT NULL, origin_epoch TEXT NOT NULL, origin_sequence INTEGER NOT NULL CHECK(origin_sequence>0), provider_id TEXT NOT NULL, metric_id TEXT NOT NULL, observed_at REAL NOT NULL, remaining REAL NOT NULL CHECK(remaining>=0), usage_limit REAL NOT NULL CHECK(usage_limit>0), reset_at REAL, cycle_started_at REAL, status TEXT NOT NULL, payload_hash BLOB NOT NULL, UNIQUE(origin_device_id,origin_epoch,origin_sequence));
            CREATE INDEX observations_series_time ON observations(provider_id,metric_id,observed_at);
            CREATE TABLE peers (credential_id TEXT PRIMARY KEY, peer_device_id TEXT NOT NULL, peer_epoch TEXT NOT NULL, display_name TEXT NOT NULL, secret BLOB NOT NULL, scopes TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL, revoked_at REAL);
            CREATE TABLE nonces (credential_id TEXT NOT NULL, nonce TEXT NOT NULL, expires_at REAL NOT NULL, PRIMARY KEY(credential_id,nonce));
            CREATE TABLE pairing_challenges (id TEXT PRIMARY KEY, secret_hash BLOB NOT NULL, expires_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, consumed_at REAL);
            CREATE TABLE migration_journal (fingerprint TEXT PRIMARY KEY, state TEXT NOT NULL, backup_path TEXT, started_at REAL NOT NULL, committed_at REAL, quarantined_count INTEGER NOT NULL DEFAULT 0);
            """)
        }
        migrator.registerMigration("pairing-v2") { db in try db.execute(sql:"""
            CREATE TABLE pairing_sessions (id TEXT PRIMARY KEY, secret_hash BLOB NOT NULL, scope TEXT NOT NULL, expires_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, consumed_at REAL, requester_device_id TEXT, requester_epoch TEXT, requester_name TEXT, approved_at REAL, credential_id TEXT, issued_secret BLOB);
        """) }
        migrator.registerMigration("peer-addresses-v3") { db in try db.execute(sql:"""
            CREATE TABLE peer_addresses (credential_id TEXT NOT NULL REFERENCES peers(credential_id) ON DELETE CASCADE, url TEXT NOT NULL, kind TEXT NOT NULL, priority INTEGER NOT NULL, last_success_at REAL, last_failure_at REAL, PRIMARY KEY(credential_id,url));
            """) }
        migrator.registerMigration("peer-presence-v4") { db in
            try db.alter(table: "peers") { $0.add(column: "last_seen_at", .double) }
        }
        migrator.registerMigration("web-push-v5") { db in
            try db.execute(sql: """
            CREATE TABLE web_push_configuration (singleton INTEGER PRIMARY KEY CHECK(singleton=1), signing_private_key BLOB NOT NULL);
            CREATE TABLE web_push_subscriptions (
                credential_id TEXT PRIMARY KEY REFERENCES peers(credential_id) ON DELETE CASCADE,
                endpoint TEXT NOT NULL,
                client_public_key BLOB NOT NULL,
                auth_secret BLOB NOT NULL,
                created_at REAL NOT NULL
            );
            """)
        }
        migrator.registerMigration("peer-sync-status-v6") { db in
            try db.alter(table: "peers") {
                $0.add(column: "sync_started_at", .double)
                $0.add(column: "last_sync_at", .double)
                $0.add(column: "last_sync_imported", .integer)
                $0.add(column: "last_sync_error", .text)
            }
        }
        try migrator.migrate(db)
        let integrity=try db.read{try String.fetchOne($0,sql:"PRAGMA quick_check")};guard integrity=="ok" else{throw SyncRepositoryError.corruptDatabase(integrity ?? "unknown quick_check result")}
        try db.write { db in
            for row in try Row.fetchAll(db,sql:"SELECT credential_id,secret FROM peers") {let value:Data=row["secret"];if !secretProtector.isProtected(value){try db.execute(sql:"UPDATE peers SET secret=? WHERE credential_id=?",arguments:[try secretProtector.seal(value),row["credential_id"] as String])}}
            for row in try Row.fetchAll(db,sql:"SELECT id,issued_secret FROM pairing_sessions WHERE issued_secret IS NOT NULL") {let value:Data=row["issued_secret"];if !secretProtector.isProtected(value){try db.execute(sql:"UPDATE pairing_sessions SET issued_secret=? WHERE id=?",arguments:[try secretProtector.seal(value),row["id"] as String])}}
            for row in try Row.fetchAll(db, sql: "SELECT credential_id,client_public_key,auth_secret FROM web_push_subscriptions") {
                let publicKey: Data = row["client_public_key"], auth: Data = row["auth_secret"]
                if !secretProtector.isProtected(publicKey) || !secretProtector.isProtected(auth) {
                    try db.execute(sql: "UPDATE web_push_subscriptions SET client_public_key=?,auth_secret=? WHERE credential_id=?", arguments: [try secretProtector.seal(publicKey), try secretProtector.seal(auth), row["credential_id"] as String])
                }
            }
        }
        identity = try db.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM device_identity WHERE singleton=1") { return Self.identity(row) }
            let value = DeviceIdentity(displayName: displayName, signingPublicKey: Data())
            try db.execute(sql: "INSERT INTO device_identity VALUES (1,?,?,?,?,1)", arguments: [value.deviceID.uuidString, value.epoch.uuidString, value.displayName, value.signingPublicKey])
            return value
        }
    }

    public func record(series: UsageSeriesID, usage: UsageResult, at date: Date = Date()) throws -> UsageObservation {
        try db.write { db in
            let sequence = try UInt64.fetchOne(db, sql: "SELECT next_sequence FROM device_identity WHERE singleton=1")!
            let observation = try UsageObservation(origin: OriginID(deviceID: identity.deviceID, epoch: identity.epoch), originSequence: sequence,
                                                   series: series, observedAt: date, remaining: usage.remaining, limit: usage.limit,
                                                   resetAt: usage.resetDate, cycleStartedAt: usage.cycleStartDate)
            try Self.insert(observation, db: db)
            try db.execute(sql: "UPDATE device_identity SET next_sequence=next_sequence+1 WHERE singleton=1")
            return observation
        }
    }

    @discardableResult public func ingest(_ observations: [UsageObservation]) throws -> (accepted: Int, duplicates: Int) {
        guard observations.count <= 500 else { throw SyncValidationError.payloadTooLarge }
        return try db.write { db in
            var accepted = 0, duplicates = 0
            for item in observations {
                _ = try UsageObservation(id: item.id, origin: item.origin, originSequence: item.originSequence, series: item.series,
                                         observedAt: item.observedAt, remaining: item.remaining, limit: item.limit, resetAt: item.resetAt,
                                         cycleStartedAt: item.cycleStartedAt, status: item.status, payloadHash: item.payloadHash)
                if try String.fetchOne(db, sql: "SELECT id FROM observations WHERE id=?", arguments: [item.id.uuidString]) != nil { duplicates += 1; continue }
                if try String.fetchOne(db, sql: "SELECT id FROM observations WHERE origin_device_id=? AND origin_epoch=? AND origin_sequence=?", arguments: [item.origin.deviceID.uuidString, item.origin.epoch.uuidString, item.originSequence]) != nil { throw SyncValidationError.originSequenceConflict }
                try Self.insert(item, db: db); accepted += 1
            }
            return (accepted, duplicates)
        }
    }

    public func observations(origin: OriginID? = nil, range: SequenceRange? = nil, limit: Int = 500) throws -> [UsageObservation] {
        try db.read { db in
            var sql = "SELECT * FROM observations", args: StatementArguments = []
            if let origin { sql += " WHERE origin_device_id=? AND origin_epoch=?"; args += [origin.deviceID.uuidString, origin.epoch.uuidString]; if let range { sql += " AND origin_sequence BETWEEN ? AND ?"; args += [range.from, range.through] } }
            sql += " ORDER BY origin_device_id,origin_epoch,origin_sequence LIMIT ?"; args += [min(max(1, limit), 500)]
            return try Row.fetchAll(db, sql: sql, arguments: args).map(Self.observation)
        }
    }

    public func allObservations() throws -> [UsageObservation] { try db.read { try Row.fetchAll($0, sql: "SELECT * FROM observations").map(Self.observation) } }
    public func projectedHistory() throws -> [String: [UsageSnapshot]] { HistoryProjector.project(try allObservations()) }

    public func originSummaries() throws -> [OriginSummary] {
        let groups = Dictionary(grouping: try allObservations(), by: \.origin)
        return groups.map { origin, items in
            let sequences = Set(items.map(\.originSequence)); let min = sequences.min() ?? 0, max = sequences.max() ?? 0
            var contiguous: UInt64 = 0; while sequences.contains(contiguous + 1) { contiguous += 1 }
            var gaps: [SequenceRange] = []; var start: UInt64?
            if max > contiguous { for n in (contiguous + 1)...max { if !sequences.contains(n) { start = start ?? n } else if let s = start { gaps.append(.init(from: s, through: n - 1)); start = nil } }; if let s = start { gaps.append(.init(from: s, through: max)) } }
            return OriginSummary(origin: origin, minimum: min, maximum: max, contiguousThrough: contiguous, gaps: gaps)
        }.sorted { $0.origin.deviceID.uuidString < $1.origin.deviceID.uuidString }
    }

    @discardableResult public func importMigration(_ observations:[UsageObservation],fingerprint:String,backupPath:String,quarantinedCount:Int,now:Date=Date())throws->Int{
        try db.write{db in
            if let state=try String.fetchOne(db,sql:"SELECT state FROM migration_journal WHERE fingerprint=?",arguments:[fingerprint]),state=="committed"{return 0}
            try db.execute(sql:"INSERT OR REPLACE INTO migration_journal(fingerprint,state,backup_path,started_at,committed_at,quarantined_count) VALUES (?,?,?,?,NULL,?)",arguments:[fingerprint,"started",backupPath,now.timeIntervalSince1970,quarantinedCount])
            var accepted=0
            for item in observations {_ = try UsageObservation(id:item.id,origin:item.origin,originSequence:item.originSequence,series:item.series,observedAt:item.observedAt,remaining:item.remaining,limit:item.limit,resetAt:item.resetAt,cycleStartedAt:item.cycleStartedAt,status:item.status,payloadHash:item.payloadHash);if try String.fetchOne(db,sql:"SELECT id FROM observations WHERE id=?",arguments:[item.id.uuidString]) != nil{continue};if try String.fetchOne(db,sql:"SELECT id FROM observations WHERE origin_device_id=? AND origin_epoch=? AND origin_sequence=?",arguments:[item.origin.deviceID.uuidString,item.origin.epoch.uuidString,item.originSequence]) != nil{throw SyncValidationError.originSequenceConflict};try Self.insert(item,db:db);accepted+=1}
            try db.execute(sql:"UPDATE migration_journal SET state='committed',committed_at=? WHERE fingerprint=?",arguments:[now.timeIntervalSince1970,fingerprint]);return accepted
        }
    }

    public func migrationState(fingerprint:String)throws->String?{try db.read{try String.fetchOne($0,sql:"SELECT state FROM migration_journal WHERE fingerprint=?",arguments:[fingerprint])}}

    public func savePeer(_ credential: PeerCredential, deviceID: UUID, epoch: UUID, displayName: String) throws {
        let scopes = credential.scopes.map(\.rawValue).sorted().joined(separator: ",")
        let protected=try secrets.seal(credential.secret);try db.write { db in try db.execute(sql: "INSERT OR REPLACE INTO peers(credential_id,peer_device_id,peer_epoch,display_name,secret,scopes,created_at,expires_at,revoked_at) VALUES (?,?,?,?,?,?,?,?,NULL)", arguments: [credential.id.uuidString, deviceID.uuidString, epoch.uuidString, displayName, protected, scopes, Date().timeIntervalSince1970, credential.expiresAt?.timeIntervalSince1970]) }
    }

    public func peerCredential(id: UUID) throws -> PeerCredential? {
        try db.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM peers WHERE credential_id=? AND revoked_at IS NULL", arguments: [id.uuidString]) else { return nil }
            let scopes = Set((row["scopes"] as String).split(separator: ",").compactMap { PeerCredential.Scope(rawValue: String($0)) })
            return PeerCredential(id: id, secret: try secrets.open(row["secret"]), scopes: scopes, expiresAt: (row["expires_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func revokePeer(credentialID: UUID, at date: Date = Date()) throws { try db.write { try $0.execute(sql: "UPDATE peers SET revoked_at=? WHERE credential_id=?", arguments: [date.timeIntervalSince1970, credentialID.uuidString]) } }
    public func rotatePeer(credentialID:UUID,at date:Date=Date())throws->PeerCredential{try db.write{db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM peers WHERE credential_id=? AND revoked_at IS NULL",arguments:[credentialID.uuidString])else{throw SyncRepositoryError.peerNotFound};var rng=SystemRandomNumberGenerator();let plain=Data((0..<32).map{_ in UInt8.random(in:.min ... .max,using:&rng)}),new=PeerCredential(secret:plain,scopes:Set((row["scopes"] as String).split(separator:",").compactMap{PeerCredential.Scope(rawValue:String($0))}),expiresAt:(row["expires_at"] as Double?).map(Date.init(timeIntervalSince1970:))),protected=try secrets.seal(plain);try db.execute(sql:"UPDATE peers SET revoked_at=? WHERE credential_id=?",arguments:[date.timeIntervalSince1970,credentialID.uuidString]);try db.execute(sql:"INSERT INTO peers(credential_id,peer_device_id,peer_epoch,display_name,secret,scopes,created_at,expires_at,revoked_at) VALUES (?,?,?,?,?,?,?,?,NULL)",arguments:[new.id.uuidString,row["peer_device_id"],row["peer_epoch"],row["display_name"],protected,row["scopes"],date.timeIntervalSince1970,row["expires_at"] as Double?]);try db.execute(sql:"UPDATE peer_addresses SET credential_id=? WHERE credential_id=?",arguments:[new.id.uuidString,credentialID.uuidString]);return new}}
    public func replacePeerCredential(oldID:UUID,with new:PeerCredential,at date:Date=Date())throws{try db.write{db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM peers WHERE credential_id=? AND revoked_at IS NULL",arguments:[oldID.uuidString])else{throw SyncRepositoryError.peerNotFound};let protected=try secrets.seal(new.secret),scopes=new.scopes.map(\.rawValue).sorted().joined(separator:",");try db.execute(sql:"UPDATE peers SET revoked_at=? WHERE credential_id=?",arguments:[date.timeIntervalSince1970,oldID.uuidString]);try db.execute(sql:"INSERT INTO peers(credential_id,peer_device_id,peer_epoch,display_name,secret,scopes,created_at,expires_at,revoked_at) VALUES (?,?,?,?,?,?,?,?,NULL)",arguments:[new.id.uuidString,row["peer_device_id"],row["peer_epoch"],row["display_name"],protected,scopes,date.timeIntervalSince1970,new.expiresAt?.timeIntervalSince1970]);try db.execute(sql:"UPDATE peer_addresses SET credential_id=? WHERE credential_id=?",arguments:[new.id.uuidString,oldID.uuidString])}}

    public struct PeerRecord:Sendable {public let credentialID:UUID;public let deviceID:UUID;public let epoch:UUID;public let displayName:String;public let scopes:Set<PeerCredential.Scope>;public let revokedAt:Date?;public let lastSeenAt:Date?;public let syncStartedAt:Date?;public let lastSyncAt:Date?;public let lastSyncImported:Int?;public let lastSyncError:String?;public let hasPushSubscription:Bool}
    public func peers(includeRevoked:Bool=false)throws->[PeerRecord]{try db.read{db in var sql="SELECT p.*, EXISTS(SELECT 1 FROM web_push_subscriptions s WHERE s.credential_id=p.credential_id) AS has_push_subscription FROM peers p";if !includeRevoked{sql+=" WHERE p.revoked_at IS NULL"};return try Row.fetchAll(db,sql:sql).map{row in .init(credentialID:UUID(uuidString:row["credential_id"])!,deviceID:UUID(uuidString:row["peer_device_id"])!,epoch:UUID(uuidString:row["peer_epoch"])!,displayName:row["display_name"],scopes:Set((row["scopes"] as String).split(separator:",").compactMap{PeerCredential.Scope(rawValue:String($0))}),revokedAt:(row["revoked_at"] as Double?).map(Date.init(timeIntervalSince1970:)),lastSeenAt:(row["last_seen_at"] as Double?).map(Date.init(timeIntervalSince1970:)),syncStartedAt:(row["sync_started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),lastSyncAt:(row["last_sync_at"] as Double?).map(Date.init(timeIntervalSince1970:)),lastSyncImported:row["last_sync_imported"],lastSyncError:row["last_sync_error"],hasPushSubscription:(row["has_push_subscription"] as Int) != 0)}}}
    public func markPeerSeen(credentialID:UUID,at date:Date=Date())throws{try db.write{try $0.execute(sql:"UPDATE peers SET last_seen_at=? WHERE credential_id=?",arguments:[date.timeIntervalSince1970,credentialID.uuidString])}}
    public func beginPeerSync(credentialID: UUID, at date: Date = Date()) throws { try db.write { try $0.execute(sql: "UPDATE peers SET sync_started_at=?,last_sync_error=NULL WHERE credential_id=?", arguments: [date.timeIntervalSince1970, credentialID.uuidString]) } }
    public func finishPeerSync(credentialID: UUID, imported: Int, error: String? = nil, at date: Date = Date()) throws { try db.write { try $0.execute(sql: "UPDATE peers SET sync_started_at=NULL,last_sync_at=?,last_sync_imported=?,last_sync_error=? WHERE credential_id=?", arguments: [date.timeIntervalSince1970, imported, error, credentialID.uuidString]) } }

    public func webPushSigningPrivateKey() throws -> Data {
        try db.write { db in
            if let protected: Data = try Data.fetchOne(db, sql: "SELECT signing_private_key FROM web_push_configuration WHERE singleton=1") {
                return try secrets.open(protected)
            }
            let key = P256.Signing.PrivateKey().rawRepresentation
            try db.execute(sql: "INSERT INTO web_push_configuration(singleton,signing_private_key) VALUES (1,?)", arguments: [try secrets.seal(key)])
            return key
        }
    }

    public func saveWebPushSubscription(_ subscription: WebPushSubscription, credentialID: UUID) throws {
        guard subscription.endpoint.scheme == "https", subscription.clientPublicKey.count == 65, subscription.authSecret.count >= 16 else {
            throw SyncValidationError.invalidObservation
        }
        try db.write { db in
            guard try String.fetchOne(db, sql: "SELECT credential_id FROM peers WHERE credential_id=? AND revoked_at IS NULL", arguments: [credentialID.uuidString]) != nil else { throw SyncRepositoryError.peerNotFound }
            try db.execute(sql: "INSERT OR REPLACE INTO web_push_subscriptions(credential_id,endpoint,client_public_key,auth_secret,created_at) VALUES (?,?,?,?,?)", arguments: [credentialID.uuidString, subscription.endpoint.absoluteString, try secrets.seal(subscription.clientPublicKey), try secrets.seal(subscription.authSecret), Date().timeIntervalSince1970])
        }
    }

    public func removeWebPushSubscription(credentialID: UUID) throws {
        try db.write { try $0.execute(sql: "DELETE FROM web_push_subscriptions WHERE credential_id=?", arguments: [credentialID.uuidString]) }
    }

    public func webPushSubscriptions() throws -> [WebPushSubscriptionRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.* FROM web_push_subscriptions s
                JOIN peers p ON p.credential_id=s.credential_id
                WHERE p.revoked_at IS NULL
                """).compactMap { row in
                    guard let id = UUID(uuidString: row["credential_id"]), let endpoint = URL(string: row["endpoint"]) else { return nil }
                    return WebPushSubscriptionRecord(credentialID: id, subscription: .init(endpoint: endpoint, clientPublicKey: try secrets.open(row["client_public_key"]), authSecret: try secrets.open(row["auth_secret"])))
                }
        }
    }
    public enum AddressKind:String,Sendable,Hashable,CaseIterable{case manual,bonjour}
    public struct PeerAddress:Sendable{public let credentialID:UUID;public let url:URL;public let kind:AddressKind;public let priority:Int;public let lastSuccessAt:Date?;public let lastFailureAt:Date?}
    public func saveAddress(credentialID:UUID,url:URL,kind:AddressKind)throws{let priority=kind == .manual ? 0 : 1;try db.write{try $0.execute(sql:"INSERT OR REPLACE INTO peer_addresses(credential_id,url,kind,priority) VALUES (?,?,?,?)",arguments:[credentialID.uuidString,url.absoluteString,kind.rawValue,priority])}}
    public func addresses(credentialID:UUID)throws->[PeerAddress]{try db.read{db in try Row.fetchAll(db,sql:"SELECT * FROM peer_addresses WHERE credential_id=? ORDER BY priority,last_failure_at IS NOT NULL,last_success_at DESC",arguments:[credentialID.uuidString]).compactMap{row in guard let url=URL(string:row["url"]),let kind=AddressKind(rawValue:row["kind"]) else{return nil};return .init(credentialID:credentialID,url:url,kind:kind,priority:row["priority"],lastSuccessAt:(row["last_success_at"] as Double?).map(Date.init(timeIntervalSince1970:)),lastFailureAt:(row["last_failure_at"] as Double?).map(Date.init(timeIntervalSince1970:)))}}}
    public func recordAddressResult(credentialID:UUID,url:URL,succeeded:Bool,at date:Date=Date())throws{let column=succeeded ? "last_success_at":"last_failure_at";try db.write{try $0.execute(sql:"UPDATE peer_addresses SET \(column)=? WHERE credential_id=? AND url=?",arguments:[date.timeIntervalSince1970,credentialID.uuidString,url.absoluteString])}}

    public func consumeNonce(credentialID: UUID, nonce: String, expiresAt: Date, now: Date = Date()) throws -> Bool {
        try db.write { db in
            try db.execute(sql: "DELETE FROM nonces WHERE expires_at<?", arguments: [now.timeIntervalSince1970])
            do { try db.execute(sql: "INSERT INTO nonces VALUES (?,?,?)", arguments: [credentialID.uuidString, nonce, expiresAt.timeIntervalSince1970]); return true }
            catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT { return false }
        }
    }

    public func createPairingSession(scope: PeerCredential.Scope, secret: Data, expiresAt: Date) throws -> UUID {
        let id=UUID(), hash=Data(SHA256.hash(data:secret));try db.write{try $0.execute(sql:"INSERT INTO pairing_sessions(id,secret_hash,scope,expires_at) VALUES (?,?,?,?)",arguments:[id.uuidString,hash,scope.rawValue,expiresAt.timeIntervalSince1970])};return id
    }

    public func exchangePairingSession(id:UUID,secret:Data,requester:DeviceIdentity,now:Date=Date()) throws -> Bool {
        try db.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM pairing_sessions WHERE id=?",arguments:[id.uuidString]),(row["expires_at"] as Double)>now.timeIntervalSince1970,(row["attempts"] as Int)<5,(row["consumed_at"] as Double?) == nil else{return false}
            let matches=(row["secret_hash"] as Data)==Data(SHA256.hash(data:secret));if matches{try db.execute(sql:"UPDATE pairing_sessions SET attempts=attempts+1, requester_device_id=?,requester_epoch=?,requester_name=? WHERE id=?",arguments:[requester.deviceID.uuidString,requester.epoch.uuidString,requester.displayName,id.uuidString])}else{try db.execute(sql:"UPDATE pairing_sessions SET attempts=attempts+1 WHERE id=?",arguments:[id.uuidString])};return matches
        }
    }

    public func approvePairingSession(id:UUID,now:Date=Date()) throws -> PeerCredential {
        try db.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM pairing_sessions WHERE id=?",arguments:[id.uuidString]),(row["expires_at"] as Double)>now.timeIntervalSince1970,(row["requester_device_id"] as String?) != nil,(row["approved_at"] as Double?) == nil else{throw SyncValidationError.invalidObservation}
            var rng=SystemRandomNumberGenerator();let secret=Data((0..<32).map{_ in UInt8.random(in:.min ... .max,using:&rng)}),credential=PeerCredential(secret:secret,scopes:[PeerCredential.Scope(rawValue:row["scope"])!])
            let protected=try secrets.seal(secret);try db.execute(sql:"UPDATE pairing_sessions SET approved_at=?,credential_id=?,issued_secret=? WHERE id=?",arguments:[now.timeIntervalSince1970,credential.id.uuidString,protected,id.uuidString])
            try db.execute(sql:"INSERT INTO peers(credential_id,peer_device_id,peer_epoch,display_name,secret,scopes,created_at,expires_at,revoked_at) VALUES (?,?,?,?,?,?,?,?,NULL)",arguments:[credential.id.uuidString,row["requester_device_id"],row["requester_epoch"],row["requester_name"],protected,row["scope"],now.timeIntervalSince1970,nil])
            return credential
        }
    }
    public struct PendingPairing:Sendable,Identifiable{public let id:UUID;public let scope:PeerCredential.Scope;public let expiresAt:Date;public let requesterDeviceID:UUID;public let requesterEpoch:UUID;public let requesterName:String}
    public func pendingPairings(now:Date=Date())throws->[PendingPairing]{try db.read{db in try Row.fetchAll(db,sql:"SELECT * FROM pairing_sessions WHERE requester_device_id IS NOT NULL AND approved_at IS NULL AND consumed_at IS NULL AND expires_at>? ORDER BY expires_at",arguments:[now.timeIntervalSince1970]).compactMap{row in guard let id=UUID(uuidString:row["id"]),let scope=PeerCredential.Scope(rawValue:row["scope"]),let device=UUID(uuidString:row["requester_device_id"]),let epoch=UUID(uuidString:row["requester_epoch"])else{return nil};return .init(id:id,scope:scope,expiresAt:Date(timeIntervalSince1970:row["expires_at"]),requesterDeviceID:device,requesterEpoch:epoch,requesterName:row["requester_name"])}}}

    public func completePairingSession(id:UUID,secret:Data,now:Date=Date()) throws -> PeerCredential? {
        try db.write { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM pairing_sessions WHERE id=?",arguments:[id.uuidString]),(row["expires_at"] as Double)>now.timeIntervalSince1970,(row["secret_hash"] as Data)==Data(SHA256.hash(data:secret)),let credentialID=UUID(uuidString:row["credential_id"] as String),let issued=row["issued_secret"] as Data? else{return nil};try db.execute(sql:"UPDATE pairing_sessions SET consumed_at=? WHERE id=? AND consumed_at IS NULL",arguments:[now.timeIntervalSince1970,id.uuidString]);guard db.changesCount==1 else{return nil};return PeerCredential(id:credentialID,secret:try secrets.open(issued),scopes:[PeerCredential.Scope(rawValue:row["scope"])!]) }
    }

    public func connectPairingSession(password: String, requesterName: String, requesterDeviceID: UUID, requesterEpoch: UUID, scope: PeerCredential.Scope, now: Date = Date()) throws -> PeerCredential? {
        let normalized = password.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = Data(SHA256.hash(data: Data(normalized.utf8)))
        return try db.write { db in
            let consumptionClause = scope == .mobileRead ? "" : " AND consumed_at IS NULL"
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pairing_sessions WHERE secret_hash=? AND scope=? AND expires_at>? AND attempts<5\(consumptionClause) ORDER BY expires_at DESC LIMIT 1", arguments: [hash, scope.rawValue, now.timeIntervalSince1970]) else { return nil }
            var rng = SystemRandomNumberGenerator()
            let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
            let credential = PeerCredential(secret: secret, scopes: [scope])
            let protected = try secrets.seal(secret)
            let consumedAt: Double? = scope == .mobileRead ? nil : now.timeIntervalSince1970
            try db.execute(sql: "UPDATE pairing_sessions SET consumed_at=?,requester_device_id=?,requester_epoch=?,requester_name=?,approved_at=?,credential_id=?,issued_secret=? WHERE id=?", arguments: [consumedAt, requesterDeviceID.uuidString, requesterEpoch.uuidString, requesterName, now.timeIntervalSince1970, credential.id.uuidString, protected, row["id"] as String])
            guard db.changesCount == 1 else { return nil }
            try db.execute(sql: "INSERT INTO peers(credential_id,peer_device_id,peer_epoch,display_name,secret,scopes,created_at,expires_at,revoked_at) VALUES (?,?,?,?,?,?,?,?,NULL)", arguments: [credential.id.uuidString, requesterDeviceID.uuidString, requesterEpoch.uuidString, requesterName, protected, scope.rawValue, now.timeIntervalSince1970, nil])
            return credential
        }
    }

    private static func insert(_ o: UsageObservation, db: Database) throws { try db.execute(sql: "INSERT INTO observations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", arguments: [o.id.uuidString,o.origin.deviceID.uuidString,o.origin.epoch.uuidString,o.originSequence,o.series.providerID,o.series.metricID,o.observedAt.timeIntervalSince1970,o.remaining,o.limit,o.resetAt?.timeIntervalSince1970,o.cycleStartedAt?.timeIntervalSince1970,o.status.rawValue,o.payloadHash]) }
    private static func identity(_ r: Row) -> DeviceIdentity { DeviceIdentity(deviceID: UUID(uuidString:r["device_id"])!,epoch:UUID(uuidString:r["epoch"])!,displayName:r["display_name"],signingPublicKey:r["public_key"]) }
    private static func observation(_ r: Row) throws -> UsageObservation { try UsageObservation(id:UUID(uuidString:r["id"])!,origin:.init(deviceID:UUID(uuidString:r["origin_device_id"])!,epoch:UUID(uuidString:r["origin_epoch"])!),originSequence:r["origin_sequence"],series:.init(providerID:r["provider_id"],metricID:r["metric_id"]),observedAt:Date(timeIntervalSince1970:r["observed_at"]),remaining:r["remaining"],limit:r["usage_limit"],resetAt:(r["reset_at"] as Double?).map(Date.init(timeIntervalSince1970:)),cycleStartedAt:(r["cycle_started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),status:ObservationStatus(rawValue:r["status"])!,payloadHash:r["payload_hash"]) }
}
public enum SyncRepositoryError:Error,Equatable{case corruptDatabase(String),peerNotFound}
