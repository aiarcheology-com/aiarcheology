//
//  FindingsSyncLedger.swift
//  AI Archeology
//
//  What this device already told the cloud, and what it still owes it (AIA-727).
//

import CryptoKit
import Foundation
import OSLog

/// A finding whose upload was refused for a reason retrying cannot cure.
struct ParkedUpload: Codable, Sendable, Equatable {
    let code: String
    /// The local timestamp that was refused. Editing the finding moves this on, which is what
    /// clears the park: the user has changed the thing that was rejected.
    let modifiedAt: Int64
}

/// A delete this device has made locally and the cloud has not confirmed.
///
/// Deletes cannot be derived from the store the way uploads can — a deleted finding leaves nothing
/// behind — so they are the one piece of sync state that is authoritative rather than a cache.
struct PendingDelete: Codable, Sendable, Equatable {
    let id: UUID
    let modifiedAt: Int64
}

/// What this device believes the cloud already holds for one account.
///
/// Everything here except the tombstones is a **cache**: lose it and the next sync re-uploads
/// findings the cloud already has, which the Worker accepts idempotently at an equal timestamp. The
/// cost is bandwidth, not correctness — which is the whole reason this can live in a file rather
/// than needing a Core Data model version and a hand-written migration.
struct FindingsSyncLedger: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = FindingsSyncLedger.currentSchemaVersion
    /// Where this device has read up to in the account's change stream.
    var cursor: String?
    /// Finding id → the `modifiedAt` the cloud confirmed storing.
    var uploaded: [String: Int64] = [:]
    /// Whether the user has been asked about backing up findings that were already on this device
    /// when the account signed in. Asked once, then never again for this account.
    var hasAnsweredBackupPrompt = false
    /// Findings the user declined to back up. Persisted, or the outbox would re-derive them and
    /// ask again on every launch.
    var excluded: Set<String> = []
    var parked: [String: ParkedUpload] = [:]
    var usedBytes: Int?
    var limitBytes: Int?
    /// Whether "this account syncs" has already been reported. Once per account, ever: the signal
    /// is that sync got used at all, and repeating it every launch would say nothing new.
    var hasReportedSyncEnabled = false
    /// Whether the account is currently in the storage-full state. Held so the event fires on the
    /// transition into it, not on every upload that is refused while it lasts.
    var isReportedQuotaBlocked = false

    func needsUpload(id: UUID, localModifiedAt: Int64) -> Bool {
        let key = id.uuidString
        if excluded.contains(key) { return false }
        if let parked = parked[key], parked.modifiedAt >= localModifiedAt { return false }
        guard let confirmed = uploaded[key] else { return true }
        return localModifiedAt > confirmed
    }
}

/// Reads and writes the per-account sync files.
///
/// **Per account, keyed by a hash of the account id.** On a shared device this is not tidiness: if
/// one ledger served both, B's client would believe A's findings were already backed up, and would
/// read A's cursor. The id is hashed rather than spelled into a filename because it identifies a
/// person, and filenames are the least protected thing an app writes.
///
/// Tombstones live in their own file. A corrupt ledger is discarded — which costs a re-upload — but
/// discarding unsent deletes would resurrect findings the user deleted, and for this app that means
/// site coordinates coming back after someone chose to remove them.
actor FindingsSyncLedgerStore {
    private nonisolated let directory: URL?
    private nonisolated let accountKey: String

    init(accountIdentifier: String, directory: URL? = FindingsSyncLedgerStore.defaultDirectory) {
        self.directory = directory
        var hasher = SHA256()
        hasher.update(data: Data(accountIdentifier.utf8))
        self.accountKey = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static var defaultDirectory: URL? {
        FileManager.default.documentDirectory?.appendingPathComponent("FindingsSyncCoordinator")
    }

    private var ledgerURL: URL? { directory?.appendingPathComponent("ledger-\(accountKey).json") }
    private nonisolated var tombstonesURL: URL? {
        directory?.appendingPathComponent("tombstones-\(accountKey).json")
    }

    func loadLedger() -> FindingsSyncLedger {
        guard let ledgerURL, let data = try? Data(contentsOf: ledgerURL) else { return FindingsSyncLedger() }
        guard let decoded = try? JSONDecoder().decode(FindingsSyncLedger.self, from: data),
              decoded.schemaVersion == FindingsSyncLedger.currentSchemaVersion
        else {
            // Unreadable or from a future build: start over rather than guess. Everything in here
            // is recoverable by re-uploading, and the Worker accepts a replay at an equal
            // timestamp without duplicating anything.
            LoggingPolicy.warning("Findings sync ledger was unreadable and has been reset", logger: .storage)
            return FindingsSyncLedger()
        }
        return decoded
    }

    func save(_ ledger: FindingsSyncLedger) {
        write(ledger, to: ledgerURL, describing: "ledger")
    }

    /// The tombstone file for this account, as a synchronous handle.
    ///
    /// Deliberately not behind the actor. A tombstone has to be on disk **before** the Core Data
    /// delete commits, and an `await` between the two is exactly the window where a crash loses the
    /// delete -- the finding would then come back from another device, which for this app means
    /// site coordinates reappearing after someone chose to remove them.
    nonisolated var tombstones: FindingsTombstoneFile {
        FindingsTombstoneFile(url: tombstonesURL)
    }

    func loadPendingDeletes() -> [PendingDelete] { tombstones.load() }

    func savePendingDeletes(_ deletes: [PendingDelete]) { tombstones.save(deletes) }

    func enqueueDelete(_ delete: PendingDelete) { tombstones.enqueue(delete) }

    func removePendingDelete(_ id: UUID) { tombstones.remove(id) }

    private func write<T: Encodable>(_ value: T, to url: URL?, describing what: String) {
        guard let url, let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(value)
            try encoded.write(to: url, options: .atomic)
        } catch {
            LoggingPolicy.error("Findings sync could not persist \(what): \(error.localizedDescription)", logger: .storage)
        }
    }
}

/// The unsent-tombstone file, read and written synchronously.
///
/// Synchronous on purpose. Recording a delete has to happen before the Core Data delete commits,
/// and any suspension point between the two is a window where a crash loses the delete for ever --
/// the one piece of sync state that cannot be reconstructed by syncing again.
struct FindingsTombstoneFile: Sendable {
    let url: URL?

    func load() -> [PendingDelete] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        guard let decoded = try? JSONDecoder().decode([PendingDelete].self, from: data) else {
            LoggingPolicy.error("Findings sync could not read pending deletes; they may be resent", logger: .storage)
            return []
        }
        return decoded
    }

    func save(_ deletes: [PendingDelete]) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(deletes).write(to: url, options: .atomic)
        } catch {
            LoggingPolicy.error("Findings sync could not record a delete: \(error.localizedDescription)", logger: .storage)
        }
    }

    func enqueue(_ delete: PendingDelete) {
        save(load().filter { $0.id != delete.id } + [delete])
    }

    func remove(_ id: UUID) {
        save(load().filter { $0.id != id })
    }
}
