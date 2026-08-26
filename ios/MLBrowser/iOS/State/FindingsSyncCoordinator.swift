//
//  FindingsSyncCoordinator.swift
//  AI Archeology
//
//  Findings to the cloud and back (AIA-727). Backend contract in AIA-726.
//

import CoreData
import Foundation
import Network
import OSLog
import UIKit

/// Drives findings to the cloud and back, and publishes what the user needs to see about it.
///
/// **Signing in is the opt-in.** A user who never signs in gets exactly today's behaviour: nothing
/// here runs, nothing leaves the device. There is no separate switch because there is nothing a
/// switch would express that signing in does not.
///
/// `@MainActor` because it reads and writes `Finding` objects on the view context. The network work
/// it does is in ``FindingsCloudTransport``, which is an actor and does not run here.
@MainActor
final class FindingsSyncCoordinator: ObservableObject {

    /// How many findings this device is still holding for the cloud. The "N not yet backed up"
    /// count the user sees.
    @Published private(set) var pendingUploadCount = 0

    /// The account's storage, as the server last reported it. `nil` until a sync has run.
    @Published private(set) var usage: CloudUsage?

    @Published private(set) var isSyncing = false

    /// Findings that were on this device before this account signed in, waiting for the user to say
    /// whether they should be backed up. `nil` when there is nothing to ask.
    ///
    /// They are never uploaded on a guess: on a shared device the store may hold work belonging to
    /// whoever used the app last, and quietly copying it into the account signing in now would put
    /// one person's dig sites in another person's cloud.
    @Published private(set) var findingsAwaitingBackupConsent: Int?

    /// Findings the cloud refused for a reason retrying cannot fix, so the user can be told rather
    /// than left watching a counter that never moves.
    @Published private(set) var parkedCount = 0

    private let authProvider: AuthProviding
    private let analytics: AnalyticsState?
    private let findingRepository: FindingRepository
    private let context: NSManagedObjectContext
    private let transportFactory: (@MainActor (URL) -> FindingsCloudTransport)?
    /// Overridden by tests so a cycle cannot read or write the real device's ledger.
    private let ledgerDirectory: URL?
    private let now: () -> Date

    /// Serialises cycles. Two overlapping syncs would race each other's ledger writes and upload
    /// the same finding twice.
    private var runningCycle: Task<Void, Never>?

    /// Counted per cycle, for the one log line it emits.
    private var uploaded = 0
    private var applied = 0

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.aiarcheology.findings-sync.path")

    init(
        authProvider: AuthProviding,
        analytics: AnalyticsState? = nil,
        findingRepository: FindingRepository,
        context: NSManagedObjectContext,
        transportFactory: (@MainActor (URL) -> FindingsCloudTransport)? = nil,
        ledgerDirectory: URL? = FindingsSyncLedgerStore.defaultDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.authProvider = authProvider
        self.analytics = analytics
        self.findingRepository = findingRepository
        self.context = context
        self.now = now
        self.transportFactory = transportFactory
        self.ledgerDirectory = ledgerDirectory
        findingRepository.willDeleteFinding = { [weak self] entityId in
            self?.recordDelete(entityId)
        }
    }

    private func ledgerStore(for account: String) -> FindingsSyncLedgerStore {
        FindingsSyncLedgerStore(accountIdentifier: account, directory: ledgerDirectory)
    }

    /// Built per cycle rather than held, so the token closure can capture `self` — a `@MainActor`
    /// class, which is `Sendable` — instead of the auth provider, which is not.
    private func transport(for baseURL: URL) -> FindingsCloudTransport {
        if let transportFactory { return transportFactory(baseURL) }
        return FindingsCloudTransport(baseURL: baseURL) { [weak self] in
            try await self?.currentSessionToken()
        }
    }

    /// Asked for per request. Session tokens live about a minute, and the SDK caches and refreshes
    /// behind this, so holding one is a bug that only shows up on a slow upload.
    private func currentSessionToken() async throws -> String? {
        try await authProvider.sessionToken()
    }

    // MARK: - Triggers

    /// Starts syncing and keeps it going.
    ///
    /// Three triggers, because the user this app is for works without signal: the app coming to the
    /// front, connectivity coming back, and a local save. There is no timer — a sync that fires
    /// while nothing has changed and nothing has reconnected has nothing to do.
    func start() {
        findingRepository.didChangeFindings = { [weak self] in self?.syncNow() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }

        // The one that matters in the field: a finding saved in a valley with no signal uploads
        // itself when the phone finds a network again, without the user doing anything.
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.syncNow() }
        }
        monitor.start(queue: monitorQueue)

        syncNow()
    }

    /// Runs a cycle unless one is already running. Safe to call from a foreground notification, a
    /// connectivity change, or straight after a save.
    /// Returns the running cycle so a test can await it. Production callers ignore it: a sync is
    /// something the app starts, not something it waits on.
    @discardableResult
    func syncNow() -> Task<Void, Never>? {
        guard runningCycle == nil else { return runningCycle }
        let task = Task { [weak self] in
            await self?.cycle()
            self?.runningCycle = nil
        }
        runningCycle = task
        return task
    }

    /// The user answered the back-up question. Accepting uploads what was waiting; declining
    /// records that decision so the outbox stops re-deriving those findings and asking again.
    @discardableResult
    func answerBackupConsent(accepted: Bool) -> Task<Void, Never>? {
        guard let account = authProvider.accountIdentifier else { return nil }
        return Task { [weak self] in
            guard let self else { return }
            let store = self.ledgerStore(for: account)
            var ledger = await store.loadLedger()
            ledger.hasAnsweredBackupPrompt = true
            if accepted == false {
                // Only what was actually waiting. Excluding every id would also cover findings the
                // cloud already holds, and a later edit to one of those would then never upload.
                ledger.excluded.formUnion(self.uploadCandidates(ledger: ledger).map(\.entityId.uuidString))
            }
            await store.save(ledger)
            self.findingsAwaitingBackupConsent = nil
            await self.syncNow()?.value
        }
    }

    // MARK: - The cycle

    private func cycle() async {
        guard let account = authProvider.accountIdentifier else {
            // Signed out: leave local data and the ledger exactly as they are.
            pendingUploadCount = 0
            findingsAwaitingBackupConsent = nil
            return
        }
        guard let baseURL = FindingsCloudEndpoint.baseURL(for: ClerkAuthProvider.selectedEnvironment) else {
            // No Worker for this build. Sync is off rather than pointed somewhere wrong.
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        let started = Date()
        uploaded = 0
        applied = 0

        let store = ledgerStore(for: account)
        let cloud = transport(for: baseURL)
        var ledger = await store.loadLedger()

        do {
            try await push(account: account, store: store, transport: cloud, ledger: &ledger)
            try await pull(account: account, store: store, transport: cloud, ledger: &ledger)
        } catch is CancellationError {
            return
        } catch let error as FindingsCloudError {
            // A cycle that could not finish is not a failure to report at the finding level: the
            // next trigger picks up exactly where the ledger says this one stopped.
            LoggingPolicy.warning("Findings sync stopped: \(String(describing: error.code ?? "transport"))", logger: .networking)
        } catch {
            LoggingPolicy.warning("Findings sync stopped: \(error.localizedDescription)", logger: .networking)
        }

        guard stillSignedIn(as: account) else { return }

        // One line per cycle, with counts and a duration -- enough to answer "is it syncing?" from
        // a support question. Deliberately no ids, titles or coordinates: a log that named
        // findings would put site locations in a device log.
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        LoggingPolicy.info(
            "Findings sync finished in \(elapsed)ms: uploaded \(uploaded), applied \(applied), "
                + "pending \(uploadCandidates(ledger: ledger).count), parked \(ledger.parked.count)",
            logger: .networking
        )

        if uploaded > 0 || applied > 0, ledger.hasReportedSyncEnabled == false {
            ledger.hasReportedSyncEnabled = true
            analytics?.track(.cloudSyncEnabled)
        }
        // Reported on the way INTO the storage-full state and not again while it lasts, so the
        // number counts users who hit the cap rather than uploads they attempted afterwards.
        let blocked = ledger.parked.values.contains { $0.code == "quota_exceeded" }
        if blocked != ledger.isReportedQuotaBlocked {
            ledger.isReportedQuotaBlocked = blocked
            if blocked { analytics?.track(.cloudSyncQuotaBlocked) }
        }

        await store.save(ledger)
        refreshCounts(from: ledger)
    }

    /// Every ledger write and every Core Data apply is fenced on the account that started the
    /// cycle.
    ///
    /// Without it, a sign-out mid-cycle would file one account's acknowledgements in another's
    /// ledger and apply one account's cloud rows into the session that replaced it.
    private func stillSignedIn(as account: String) -> Bool {
        authProvider.accountIdentifier == account
    }

    // MARK: - Push

    private func push(
        account: String,
        store: FindingsSyncLedgerStore,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async throws {
        let tombstones = store.tombstones
        for pending in tombstones.load() {
            guard stillSignedIn(as: account) else { throw CancellationError() }
            do {
                _ = try await transport.delete(id: pending.id, modifiedAt: pending.modifiedAt)
                tombstones.remove(pending.id)
                ledger.uploaded[pending.id.uuidString] = nil
            } catch let error as FindingsCloudError where error.code == "stale" {
                // Something newer than this delete is already stored, so the delete lost. Dropping
                // the tombstone is the whole of the fix: the winner arrives on the next pull, and
                // last-write-wins is what the epic pinned for delete-versus-edit.
                tombstones.remove(pending.id)
            } catch let error as FindingsCloudError where error.isRetryable == false {
                tombstones.remove(pending.id)
                LoggingPolicy.warning("A findings delete was refused permanently and dropped", logger: .networking)
            }
        }

        let candidates = uploadCandidates(ledger: ledger)
        if ledger.hasAnsweredBackupPrompt == false {
            if candidates.isEmpty == false {
                // Every finding here predates this account's first sync on this device, so the user
                // is asked once before any of it leaves the device.
                findingsAwaitingBackupConsent = candidates.count
                return
            }
            // Nothing pre-existing to ask about, so there is nothing to consent to.
            ledger.hasAnsweredBackupPrompt = true
        }

        for finding in candidates {
            guard stillSignedIn(as: account) else { throw CancellationError() }
            try await upload(finding, transport: transport, ledger: &ledger)
        }
    }

    private func upload(
        _ finding: Finding,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async throws {
        let entityId = finding.entityId
        let key = entityId.uuidString
        let sent = Self.milliseconds(finding.modifiedAt ?? finding.creationDate_ ?? now())
        let snapshot = FindingSnapshot(finding)

        do {
            var imageNames: [UUID: String] = [:]
            if let filename = finding.screenshotFilename,
               let url = FindingScreenshotStore.url(forFilename: filename),
               let data = try? Data(contentsOf: url) {
                imageNames[entityId] = filename
                _ = try await transport.uploadImage(id: entityId, modifiedAt: sent, data: data)
            }
            // The image goes first and the metadata commits: the Worker writes its index row here
            // and nowhere else, so this call is what makes the finding visible to another device.
            let meta = try FindingExporter.encodeJSON([snapshot], copiedImageNames: imageNames)
            let commit = try await transport.commitMeta(id: entityId, modifiedAt: sent, data: meta)

            ledger.uploaded[key] = commit.finding.modifiedAt
            ledger.parked[key] = nil
            uploaded += 1
            adopt(commit.finding.modifiedAt, sent: sent, on: finding)
            usage = commit.usage
        } catch let error as FindingsCloudError where error.isRetryable {
            // Backoff is the trigger cadence itself: foreground, connectivity, and the next save.
            // Nothing is recorded, so the next cycle finds this finding still owed.
            throw error
        } catch let error as FindingsCloudError {
            if error.code == "stale" {
                // The cloud already holds something newer. Recording it as uploaded stops this
                // device pushing a copy it has already lost; the winner arrives on the pull.
                ledger.uploaded[key] = error.winner?.modifiedAt ?? sent
            } else {
                ledger.parked[key] = ParkedUpload(code: error.code ?? "unknown", modifiedAt: sent)
            }
        }
    }

    /// Takes the timestamp the server actually stored.
    ///
    /// The server clamps a future-dated client clock to receipt time, so what it stored can be
    /// older than what was sent. A device that kept its own value would see the row as perpetually
    /// newer than the cloud's and re-upload it on every single sync. The local value is only
    /// rewritten when it still holds exactly what was sent — otherwise the user has edited the
    /// finding since, and their edit must not be reverted.
    private func adopt(_ stored: Int64, sent: Int64, on finding: Finding) {
        guard stored != sent else { return }
        guard let current = finding.modifiedAt, Self.milliseconds(current) == sent else { return }
        finding.preservesModifiedAt = true
        defer { finding.preservesModifiedAt = false }
        finding.modifiedAt = Date(timeIntervalSince1970: Double(stored) / 1000)
        try? Finding.save(in: context)
    }

    // MARK: - Pull

    private func pull(
        account: String,
        store: FindingsSyncLedgerStore,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async throws {
        var cursor = ledger.cursor
        var guardRail = 0
        repeat {
            guard stillSignedIn(as: account) else { throw CancellationError() }
            let page = try await transport.list(cursor: cursor)
            for row in page.findings {
                guard stillSignedIn(as: account) else { throw CancellationError() }
                await apply(row, transport: transport, ledger: &ledger)
            }
            usage = page.usage
            cursor = page.nextCursor
            // The cursor moves only after a page has been applied, so an interrupted pull resumes
            // rather than skipping what it did not get to.
            ledger.cursor = cursor
            await store.save(ledger)
            guardRail += 1
            if page.hasMore == false { break }
        } while guardRail < 200
    }

    private func apply(
        _ row: CloudFindingRow,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async {
        let key = row.id.uuidString
        let local = Finding.select(row.id, in: context)
        let localModifiedAt = local.map { Self.milliseconds($0.modifiedAt ?? $0.creationDate_ ?? Date(timeIntervalSince1970: 0)) }

        if row.deleted {
            // A tombstone loses to a local edit that is newer than it, exactly like any other
            // conflict. `uploaded` is cleared either way: if the local copy won, this device now
            // owes the cloud that newer version.
            if let localModifiedAt, localModifiedAt > row.modifiedAt {
                ledger.uploaded[key] = nil
                return
            }
            try? findingRepository.deleteReceivedFromCloud(row.id)
            ledger.uploaded[key] = nil
            return
        }

        if let localModifiedAt, localModifiedAt >= row.modifiedAt {
            // This device is already at least as new. Recording the row as uploaded matters when
            // the timestamps are equal: it is this device's own write coming back, and without it
            // the finding would look permanently owed and be pushed again on every cycle.
            if localModifiedAt == row.modifiedAt { ledger.uploaded[key] = row.modifiedAt }
            return
        }

        // Awaited, not spawned. A detached download would let the cursor advance past this row
        // while it was still in flight, and a download that then failed would never be retried --
        // the finding would be missing from this device for ever.
        guard await download(row, transport: transport) else { return }
        applied += 1
        // Recording what was just applied is what stops a fresh install downloading N findings and
        // immediately pushing all N back, each with a new receipt, which every other device would
        // then pull again.
        ledger.uploaded[key] = row.modifiedAt
    }

    /// Returns whether the finding was actually applied, so the caller only records what landed.
    private func download(_ row: CloudFindingRow, transport: FindingsCloudTransport) async -> Bool {
        do {
            let meta = try await transport.downloadMeta(id: row.id)
            let rows = try FindingArchiveImport.decodeRows(meta)
            guard let decoded = rows.first(where: { $0.id == row.id }) else { return false }

            var images: [UUID: Data] = [:]
            if row.hasImage {
                images[row.id] = try await transport.downloadImage(id: row.id)
            }
            // Applied through the repository's own import machinery: it is the only writer allowed
            // to put a screenshot on disk, and it is where `preservesModifiedAt` is handled, so a
            // downloaded copy keeps the timestamp that made it the winner instead of being stamped
            // "now" and handed a false win over the edit it just received.
            _ = try findingRepository.importFindings(
                FindingArchiveContents(rows: [decoded], images: images),
                duplicates: .replace
            )
            return true
        } catch let error as FindingsCloudError where error.code == "not_found" {
            // The row was deleted between the listing and the download, or it has no image after
            // all. Skipping keeps the cursor moving; halting here would block every later finding
            // behind this one for ever.
            LoggingPolicy.warning("A synced finding vanished before it could be downloaded", logger: .networking)
            // Skipped rather than fatal: the row was deleted between the listing and the download.
            // Halting here would block every later finding behind this one for ever.
            return true
        } catch {
            LoggingPolicy.warning("Could not apply a synced finding: \(error.localizedDescription)", logger: .networking)
            return false
        }
    }

    // MARK: - Local state

    /// Records a tombstone synchronously, because the caller is about to commit the delete.
    ///
    /// This used to hop onto a `Task`, which put a suspension point between recording the delete
    /// and performing it. A crash in that window lost the tombstone, and the finding came back from
    /// another device on the next sync -- coordinates reappearing after the user removed them.
    private func recordDelete(_ entityId: UUID) {
        guard let account = authProvider.accountIdentifier else { return }
        ledgerStore(for: account).tombstones.enqueue(
            PendingDelete(id: entityId, modifiedAt: Self.milliseconds(now()))
        )
    }

    private func uploadCandidates(ledger: FindingsSyncLedger) -> [Finding] {
        Finding.selectAll(in: context).filter { finding in
            let stamp = Self.milliseconds(finding.modifiedAt ?? finding.creationDate_ ?? Date(timeIntervalSince1970: 0))
            return ledger.needsUpload(id: finding.entityId, localModifiedAt: stamp)
        }
    }

    private func refreshCounts(from ledger: FindingsSyncLedger) {
        pendingUploadCount = uploadCandidates(ledger: ledger).count
        parkedCount = ledger.parked.count
    }

    /// Milliseconds since epoch, truncated.
    ///
    /// The truncation is the point. `Date` carries sub-millisecond precision and the wire carries
    /// integers, so a local 1000.7 compared against a stored 1000 is a difference that never
    /// closes: the finding would re-upload on every trigger, for ever.
    nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
