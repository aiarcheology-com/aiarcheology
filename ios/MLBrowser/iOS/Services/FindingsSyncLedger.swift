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
    /// Findings this account created on this device, and findings it has explicitly agreed to back
    /// up. Positive provenance, per finding.
    ///
    /// This used to be one "already answered" flag for the account. That was a hole on a shared
    /// device: B answers yes, signs out, A creates findings into the same local store, B signs back
    /// in -- and A's fieldwork uploads to B's account without anyone being asked. An answer applies
    /// only to the findings it was given for.
    var owned: Set<String> = []
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

    /// Whether this account backs findings up at all (AIA-744).
    ///
    /// Stored optional on purpose. A ledger written before this existed has no such key, and
    /// synthesised decoding of a non-optional would throw -- which `loadLedger` answers by resetting
    /// the whole ledger. That would discard `excluded`, and every finding the user had chosen to
    /// keep local would upload on the next cycle. An absent flag therefore means on.
    ///
    /// Not `private`: a synthesised memberwise initialiser takes the *minimum* access of its stored
    /// properties, so marking this private makes `FindingsSyncLedger(...)` private and every call
    /// site outside this file stops compiling. Read and written through ``backUpEnabled``.
    var backUpEnabledFlag: Bool?

    /// Off means nothing is uploaded, including findings created while signed in. Findings already
    /// in the cloud stay there: turning a back-up off must not delete the copy protecting the work.
    /// Pulling continues, so a reinstall still restores.
    var backUpEnabled: Bool {
        get { backUpEnabledFlag ?? true }
        set { backUpEnabledFlag = newValue }
    }

    /// Whether this account may upload the finding at all.
    ///
    /// A finding the account did not create here, has not agreed to back up, and has never sent is
    /// somebody else's until the user says otherwise.
    func mayUpload(id: UUID) -> Bool {
        let key = id.uuidString
        if excluded.contains(key) { return false }
        return owned.contains(key) || uploaded[key] != nil
    }

    func needsUpload(id: UUID, localModifiedAt: Int64) -> Bool {
        guard mayUpload(id: id) else { return false }
        let key = id.uuidString
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
        // Already a filename key when it came from `accountsHolding`, which addresses ledgers it
        // found on disk rather than accounts it can name.
        let isFileKey = accountIdentifier.count == 16
            && accountIdentifier.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        self.accountKey = isFileKey ? accountIdentifier : Self.fingerprint(of: accountIdentifier)
    }

    /// A stable, non-reversible name for an account: the first 8 bytes of SHA-256, in hex.
    ///
    /// This is the ledger's filename key, and since AIA-0816 it is also what the deletion log calls
    /// the account. Both uses want the same property -- identifying a person's data without
    /// spelling out who they are -- and support can recompute it from a Clerk id to match a log
    /// against Clerk and D1. Written into logs **without** an `account id:` style prefix on
    /// purpose: `LoggingPolicy` redacts any value that follows one, at export as well as at the
    /// call site, so an id written that way never reaches the support attachment it exists for.
    static func fingerprint(of accountIdentifier: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(accountIdentifier.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static var defaultDirectory: URL? {
        FileManager.default.documentDirectory?.appendingPathComponent("FindingsSync")
    }

    /// Every account whose ledger says it holds this finding.
    ///
    /// A user can delete a finding while signed out, or while signed in as somebody else. The
    /// account that actually has the cloud copy still needs the tombstone, or the finding comes
    /// back the next time that account syncs -- and the user was told it was deleted.
    nonisolated static func accountsHolding(_ entityId: UUID, in directory: URL?) -> Set<String> {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }

        var accounts: Set<String> = []
        let key = entityId.uuidString
        for file in files where file.hasPrefix("ledger-") && file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
                  let ledger = try? JSONDecoder().decode(FindingsSyncLedger.self, from: data),
                  ledger.uploaded[key] != nil
            else { continue }
            // The ledger filename carries the account's hash, not the account -- which is the
            // point -- so what comes back addresses a ledger rather than naming a person.
            accounts.insert(String(file.dropFirst("ledger-".count).dropLast(".json".count)))
        }
        return accounts
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

    /// Returns whether the ledger reached the disk. Callers that claimed the user's queued intents
    /// must put them back when it did not.
    @discardableResult
    func save(_ ledger: FindingsSyncLedger) -> Bool {
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

    func savePendingDeletes(_ deletes: [PendingDelete]) throws { try tombstones.save(deletes) }

    func enqueueDelete(_ delete: PendingDelete) throws { try tombstones.enqueue(delete) }

    func removePendingDelete(_ id: UUID) { tombstones.remove(id) }

    /// Removes this account's sync bookkeeping. Used after the cloud data is gone, when the ledger
    /// describes storage that no longer exists.
    func removeEverything() {
        for url in [ledgerURL, tombstonesURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Returns whether the write actually landed.
    ///
    /// The result is not decoration. A cycle folds the user's queued intents into its copy of the
    /// ledger and puts them back if it never saved; a write that failed but reported nothing left
    /// those intents claimed and discarded — a disk-full device could quietly turn backing up on
    /// again after the user had switched it off.
    @discardableResult
    private func write<T: Encodable>(_ value: T, to url: URL?, describing what: String) -> Bool {
        guard let url, let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(value)
            try encoded.write(to: url, options: .atomic)
            return true
        } catch {
            LoggingPolicy.error("Findings sync could not persist \(what): \(error.localizedDescription)", logger: .storage)
            return false
        }
    }
}

/// The unsent-tombstone file, read and written synchronously.
///
/// Synchronous on purpose. Recording a delete has to happen before the Core Data delete commits,
/// and any suspension point between the two is a window where a crash loses the delete for ever --
/// the one piece of sync state that cannot be reconstructed by syncing again.
enum FindingsTombstoneError: Error {
    case noStorageLocation
}

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

    /// Throws rather than logging. The caller is about to delete the finding, and a delete that
    /// could not be recorded must not happen at all: the cloud copy would survive on every other
    /// device, and the user was told the finding was gone.
    func save(_ deletes: [PendingDelete]) throws {
        guard let url else { throw FindingsTombstoneError.noStorageLocation }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(deletes).write(to: url, options: .atomic)
    }

    func enqueue(_ delete: PendingDelete) throws {
        try save(load().filter { $0.id != delete.id } + [delete])
    }

    /// Removing an already-sent tombstone is best effort: the worst case is that it is sent again,
    /// and the Worker treats a repeated delete as the same delete.
    func remove(_ id: UUID) {
        try? save(load().filter { $0.id != id })
    }
}
