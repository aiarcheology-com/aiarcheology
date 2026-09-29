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

    /// Findings that were on this device before this account signed in, waiting for the user to say
    /// whether they should be backed up. `nil` when there is nothing to ask.
    ///
    /// They are never uploaded on a guess: on a shared device the store may hold work belonging to
    /// whoever used the app last, and quietly copying it into the account signing in now would put
    /// one person's dig sites in another person's cloud.
    @Published private(set) var backupConsentRequest: BackupConsentRequest?

    /// A question about specific findings, for a specific account.
    ///
    /// It carries the ids and the account rather than a count, because the answer is acted on later
    /// and the world can change in between: an answer given for account A's prompt must not upload
    /// anything once B is signed in.
    struct BackupConsentRequest: Equatable {
        let account: String
        let ids: [UUID]
        var count: Int { ids.count }
    }

    /// Findings the cloud refused for a reason retrying cannot fix, so the user can be told rather
    /// than left watching a counter that never moves.
    @Published private(set) var parkedCount = 0

    /// Where one finding stands with the cloud, for the icon on its row (AIA-0735).
    enum FindingBackupState: Equatable {
        /// In the cloud, and the cloud's copy is current.
        case backedUp
        /// Not in the cloud yet: created, edited since it was sent, offline, or never claimed.
        case owed
        /// The user answered the back-up question with "Keep on This Device" for this finding.
        ///
        /// Distinct from ``owed`` on purpose. Both mean "not in the cloud", but only one of them is
        /// going to change on its own, and showing a deliberate choice as though it were a queue
        /// would be the same misdirection the button's old label was (AIA-0758).
        case keptOnDevice
    }

    /// One entry per finding this account has an opinion about. **Empty while signed out**, which is
    /// what makes the rows render no icon at all: somebody who never signs in should not get a
    /// slashed cloud on every row advertising a feature they did not ask for.
    ///
    /// Rebuilt from the ledger at the end of each cycle and cleared on an account change, for the
    /// same reason the outcome lines are: these are claims about one person's data, and the ledger
    /// is per account.
    @Published private(set) var backupStates: [UUID: FindingBackupState] = [:]

    /// What a user-initiated back-up did.
    ///
    /// Only ever set by ``backUpNow()``. The automatic triggers stay silent on purpose -- a cycle
    /// nobody asked for should not announce itself -- but a button the user pressed has to answer.
    enum ManualBackupOutcome: Equatable {
        case succeeded
        case offline
        /// The account has no room left. Pressing the button again cannot fix it, so the button says
        /// what will: remove findings, or export them.
        case quotaFull
        case failed
    }

    /// Whether the signed-in account backs findings up (AIA-744).
    ///
    /// Optimistic: set the moment the user flips the switch, then confirmed when a cycle writes it
    /// to the ledger. A switch that waited for a network round trip to move would feel broken.
    @Published private(set) var isBackUpEnabled = true

    /// True while a user-initiated back-up is running, so the button can say so.
    @Published private(set) var isBackingUp = false

    /// Whether this build has a Worker to talk to at all.
    ///
    /// `false` on production until AIA-741 lands, and the back-up button is hidden when it is:
    /// a button that reports "your findings are backed up" without making a request is a lie about
    /// the user's data, which is worse than having no button.
    /// The account the coordinator is actually syncing, which is not always the one the UI shows.
    ///
    /// `AuthState` reports nil while a persisted session is still being validated -- so on a cold
    /// offline launch the app looks signed out while sync is armed under the cached account.
    var syncingAccount: String? {
        authProvider.accountIdentifier
    }

    var isCloudConfigured: Bool {
        FindingsCloudEndpoint.baseURL(for: BackendEnvironment.current) != nil
    }

    /// The account is out of room: at least one finding was refused with `quota_exceeded`.
    ///
    /// Read from the same value the analytics event keys off, rather than re-derived from
    /// ``usage`` -- a fraction at 0.999 is not the same claim as "the server refused this".
    @Published private(set) var isQuotaBlocked = false

    /// The result of the last user-initiated back-up, or `nil` if none has run this session.
    @Published private(set) var lastManualBackup: ManualBackupOutcome?

    /// The result of the last user-pressed **Synchronize**, or `nil` if none has run this session.
    ///
    /// Held apart from ``lastManualBackup`` rather than sharing it, because the two actions make
    /// different promises and their wording must not be interchangeable: a back-up may say "your
    /// findings are backed up", and a synchronize may not -- with back-up switched off it pushes
    /// nothing at all (AIA-0758). Starting either action clears the other, so exactly one outcome
    /// is ever on screen and the newer one is always the one shown.
    @Published private(set) var lastSynchronize: ManualBackupOutcome?

    /// Why the last cycle stopped, or `nil` if it finished. Recorded so ``backUpNow()`` can tell
    /// the user what happened: the automatic path deliberately swallows these, because the next
    /// trigger resumes from the ledger, but a person who pressed a button is owed an answer.
    private var lastCycleFailure: Error?

    private let authProvider: AuthProviding
    private let analytics: AnalyticsState?
    private let findingRepository: FindingRepository
    private let dataController: DataController

    /// Read from the controller every time, never captured.
    ///
    /// `DataController.container` is REPLACED when a migration fails and the store is rebuilt, and
    /// that happens on a later main-queue turn -- after this object exists. A captured context then
    /// points at a store that is gone: every fetch returns nothing, sync sees an empty device, and
    /// it uploads nothing while the app shows the user their findings. `FindingRepository` computes
    /// its context for exactly this reason; this used to be the one place that did not.
    private var context: NSManagedObjectContext { dataController.container.viewContext }
    private let transportFactory: (@MainActor (URL) -> FindingsCloudTransport)?
    /// Overridden by tests so a cycle cannot read or write the real device's ledger.
    private let ledgerDirectory: URL?
    private let now: () -> Date

    /// Serialises cycles. Two overlapping syncs would race each other's ledger writes and upload
    /// the same finding twice.
    private var runningCycle: Task<Void, Never>?
    /// Set when a trigger arrives mid-cycle, so the work it was about is not simply lost.
    private var wantsAnotherCycle = false

    /// The account the previous cycle ran as, so a switch straight from one account to another can
    /// be noticed. Signing out is already handled by the nil-account branch of ``cycle()``; signing
    /// in as somebody else is not, and it is the case that matters on a shared device.
    private var lastSyncedAccount: String?

    /// Counted per cycle, for the one log line it emits.
    private var uploaded = 0
    private var applied = 0

    /// Findings created on this device while an account was signed in, per account, waiting to be
    /// folded into that account's ledger at the start of the next cycle.
    ///
    /// Held in memory rather than written on the spot, so it cannot race the cycle's own copy of
    /// the ledger. Losing it costs an extra question -- the finding becomes unclaimed and the user
    /// is asked -- which is the safe direction: being asked is harmless, uploading unasked is not.
    private var createdWhileSignedIn: [String: Set<String>] = [:]

    /// Findings the user explicitly asked to back up, waiting for a cycle to claim them.
    ///
    /// Handed to the cycle rather than written straight to the ledger, for the same reason
    /// ``createdWhileSignedIn`` is: a cycle already in flight loaded the ledger before this request
    /// existed and will save its own copy afterwards, silently restoring the exclusions the user
    /// just cleared -- putting back the very one-way door AIA-740 removes.
    private var pendingManualBackup: [String: Set<String>] = [:]

    /// A back-up on/off decision waiting for a cycle to persist it, for the same reason
    /// ``pendingManualBackup`` is queued rather than written: a cycle already in flight holds an
    /// older copy of the ledger and would save it back over any direct write.
    ///
    /// This one is ALSO written straight through, unlike the other three. Losing the other intents
    /// costs an extra question; losing this one silently turns backing up back on after the user
    /// said stop. The queued copy re-asserts the value over an in-flight cycle's stale save, and
    /// the write-through survives a force-quit before any cycle finishes -- neither alone covers
    /// both, and they cannot disagree because it is one idempotent boolean.
    private var pendingBackUpPreference: [String: Bool] = [:]

    /// An answer to the back-up question waiting for a cycle to fold in.
    ///
    /// Queued for exactly the reason the three above are. This one used to load, mutate and save
    /// the ledger directly, so an in-flight cycle's own save put the exclusions back and the card
    /// returned asking the same question again -- and an accepted answer uploaded nothing.
    private var pendingConsentAnswer: [String: (accepted: Bool, keys: Set<String>)] = [:]

    /// Set while the account's cloud data is being erased.
    ///
    /// A purge and a cycle are the only two writers of an account's cloud data, and they were not
    /// serialised: an upload that resumed after the purge had listed the bucket left a screenshot
    /// behind a deletion that reported success, with the credential that could name it already
    /// destroyed. While this is set, no cycle starts.
    private var isPurging = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.aiarcheology.findings-sync.path")

    init(
        authProvider: AuthProviding,
        analytics: AnalyticsState? = nil,
        findingRepository: FindingRepository,
        dataController: DataController,
        transportFactory: (@MainActor (URL) -> FindingsCloudTransport)? = nil,
        ledgerDirectory: URL? = FindingsSyncLedgerStore.defaultDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.authProvider = authProvider
        self.analytics = analytics
        self.findingRepository = findingRepository
        self.dataController = dataController
        self.now = now
        self.transportFactory = transportFactory
        self.ledgerDirectory = ledgerDirectory
        findingRepository.willDeleteFinding = { [weak self] entityId in
            try self?.recordDelete(entityId)
        }
        findingRepository.willDeleteAllFindings = { [weak self] ids in
            try self?.recordBulkDelete(ids)
        }
        findingRepository.didCreateFinding = { [weak self] entityId in
            guard let self, let account = self.authProvider.accountIdentifier else { return }
            self.createdWhileSignedIn[account, default: []].insert(entityId.uuidString)
        }
    }

    private func ledgerStore(for account: String) -> FindingsSyncLedgerStore {
        FindingsSyncLedgerStore(accountIdentifier: account, directory: ledgerDirectory)
    }

    /// Built per cycle rather than held, so the token closure can capture `self` — a `@MainActor`
    /// class, which is `Sendable` — instead of the auth provider, which is not.
    private func transport(for baseURL: URL, account: String) -> FindingsCloudTransport {
        if let transportFactory { return transportFactory(baseURL) }
        return FindingsCloudTransport(baseURL: baseURL, session: Self.session) { [weak self] in
            try await self?.currentSessionToken(for: account)
        }
    }

    /// A session that keeps nothing.
    ///
    /// `URLSession.shared` writes to a shared on-disk cache, and the `Authorization` header is not
    /// part of a cache lookup once an entry exists -- so a finding's coordinates could outlive the
    /// sign-out, the account deletion, or the user who fetched them.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Asked for per request, and refused if the signed-in account has changed since the cycle
    /// started.
    ///
    /// Fetching "the current token" was a cross-account leak: a sign-out between a finding's image
    /// and its metadata would send the second half under the new account's credential, filing one
    /// person's coordinates in another person's storage. The guards around awaits cannot undo a
    /// remote write, so the credential itself has to carry the fence.
    private func currentSessionToken(for account: String) async throws -> String? {
        guard stillSignedIn(as: account) else { throw FindingsCloudError.notSignedIn }
        let token = try await authProvider.sessionToken()
        guard stillSignedIn(as: account) else { throw FindingsCloudError.notSignedIn }
        return token
    }

    // MARK: - Triggers

    /// Starts syncing and keeps it going.
    ///
    /// Three triggers, because the user this app is for works without signal: the app coming to the
    /// front, connectivity coming back, and a local save. There is no timer — a sync that fires
    /// while nothing has changed and nothing has reconnected has nothing to do.
    func start() {
        findingRepository.didChangeFindings = { [weak self] in _ = self?.syncNow() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The result is discarded explicitly. `syncNow()` returns the running cycle so a test
            // can await it, and letting that value be the closure's result makes the generic
            // parameter ambiguous on the Xcode the app ships with.
            MainActor.assumeIsolated { _ = self?.syncNow() }
        }

        // The one that matters in the field: a finding saved in a valley with no signal uploads
        // itself when the phone finds a network again, without the user doing anything.
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in _ = self?.syncNow() }
        }
        monitor.start(queue: monitorQueue)

        syncNow()
    }

    /// What opening the findings list does, shared by the list's `onAppear` and headless
    /// `open-findings` (AIA-1003). First self-heal write-time leftovers (image written, entity insert
    /// failed) and failed file deletes; this runs on the viewContext/MainActor, and the save sheet is
    /// dismissed before the list can open, so it never races a save. Then ask the server: opening the
    /// list is the moment the user asks "what have I got?", and none of the other triggers fires when
    /// the change was made on another device while the app stayed open (AIA-0758). The bare cycle, not
    /// `synchronizeNow`: nobody pressed anything, so no spinner and no outcome line. `syncNow`
    /// coalesces, so re-presenting the list cannot stack cycles.
    ///
    /// - Parameter directory: the screenshot directory to sweep; headless passes the one its parts name.
    @discardableResult
    func activateFindings(directory: URL? = FindingScreenshotStore.directory) -> Task<Void, Never>? {
        FindingScreenshotStore.sweepOrphans(in: context, directory: directory)
        return syncNow()
    }

    /// Runs a cycle unless one is already running. Safe to call from a foreground notification, a
    /// connectivity change, or straight after a save.
    /// Returns the running cycle so a test can await it. Production callers ignore it: a sync is
    /// something the app starts, not something it waits on.
    @discardableResult
    func syncNow() -> Task<Void, Never>? {
        // Nothing may write this account's cloud data while it is being erased.
        guard isPurging == false else { return nil }
        guard runningCycle == nil else {
            // Something changed while a cycle was already running, and that cycle may have read the
            // store before it did. Dropping the trigger is how a saved finding sits unsynced until
            // some unrelated event happens to fire.
            wantsAnotherCycle = true
            return runningCycle
        }
        let task = Task { [weak self] in
            // A loop, not a chain of tasks awaiting tasks. The queued follow-up must be part of
            // this task, because a caller that awaits it is asking "is my change synced?" and the
            // cycle that answers is the follow-up -- the one this task ran first may have read the
            // store before the trigger existed. Discarding it let pull-to-refresh stop spinning,
            // and a user-pressed button report success, on work that predated the request
            // (AIA-0758).
            //
            // Iterative rather than recursive so sustained churn cannot grow a task graph: two
            // devices editing at once means every cycle applies something and queues another, and
            // a chain of tasks each awaiting its child would retain every ancestor for as long as
            // that lasted. Here the depth is one whatever happens.
            while true {
                await self?.cycle()
                guard self?.wantsAnotherCycle == true, self?.isPurging == false else { break }
                self?.wantsAnotherCycle = false
            }
            self?.runningCycle = nil
            self?.wantsAnotherCycle = false
        }
        runningCycle = task
        return task
    }

    /// Turns backing up on or off for the signed-in account (AIA-744).
    ///
    /// Declining the one-time prompt was never a general "stop": it answered only the findings it
    /// named, and anything created afterwards while signed in uploaded regardless. That is defensible
    /// -- those findings are the account's by construction -- but it left no way to say stop at all,
    /// short of signing out or deleting the account. This is that way.
    ///
    /// Turning it back on resumes uploads. It deliberately does **not** lift per-finding exclusions:
    /// keeping a particular finding local was a separate decision, and a switch labelled "back up my
    /// findings" should not quietly reverse it. ``backUpNow(expectedAccount:)`` is the explicit yes.
    @discardableResult
    func setBackUpEnabled(_ enabled: Bool, expectedAccount: String) -> Task<Void, Never>? {
        guard authProvider.accountIdentifier == expectedAccount else { return nil }
        pendingBackUpPreference[expectedAccount] = enabled
        isBackUpEnabled = enabled
        // Written through as well as queued: see `pendingBackUpPreference`. A cycle in flight may
        // save its stale copy over this, and the queued entry is what puts it back.
        let store = ledgerStore(for: expectedAccount)
        Task {
            var ledger = await store.loadLedger()
            ledger.backUpEnabled = enabled
            await store.save(ledger)
        }
        // Run a cycle either way: turning it on should start uploading now rather than at the next
        // unrelated trigger, and turning it off still needs the decision written to the ledger.
        return syncNow()
    }

    /// The user pressed "Back up my findings".
    ///
    /// This is an explicit yes for everything currently on the device, so it **lifts the account's
    /// exclusions**. Without it, declining the back-up prompt was a one-way door: the excluded set
    /// was only ever cleared by accepting a prompt, and a prompt is only raised for findings that
    /// are not already excluded, so nothing could ever ask again (AIA-740). A button labelled
    /// "Not Now" that meant "never" was the sharpest part of that.
    ///
    /// - Parameter expectedAccount: the account the *user* was looking at when they pressed. It is
    ///   checked against the provider rather than trusted: `AuthState` lags the provider while a new
    ///   account is being validated, so a press during a switch could otherwise file one person's
    ///   findings into the account that just replaced theirs -- the shared-device leak the consent
    ///   prompt exists to prevent, arriving through the back door.
    @discardableResult
    func backUpNow(expectedAccount: String) -> Task<Void, Never>? {
        guard authProvider.accountIdentifier == expectedAccount else { return nil }
        guard isCloudConfigured else { return nil }
        // Pressing the button is an explicit yes, so it turns back-up on if the user had it off --
        // uploading while the switch reads off would be the worse surprise of the two.
        if isBackUpEnabled == false { pendingBackUpPreference[expectedAccount] = true }
        isBackUpEnabled = true

        isBackingUp = true
        lastManualBackup = nil
        lastSynchronize = nil

        // Queued for the cycle to apply, never written here: see `pendingManualBackup`.
        let ids = Set(syncableFindings().map(\.entityId.uuidString))
        pendingManualBackup[expectedAccount, default: []].formUnion(ids)

        return Task { [weak self] in
            guard let self else { return }
            defer { self.isBackingUp = false }

            self.backupConsentRequest = nil

            // `syncNow()` hands back the cycle already running, which may have read its ledger
            // before this request existed. Wait until a cycle has actually claimed the request, so
            // the outcome describes the back-up the user asked for rather than one that preceded it.
            var attempts = 0
            repeat {
                attempts += 1
                await self.syncNow()?.value
            } while self.pendingManualBackup[expectedAccount] != nil && attempts < 3
                && self.stillSignedIn(as: expectedAccount)

            guard self.stillSignedIn(as: expectedAccount) else { return }
            self.lastManualBackup = self.outcomeOfManualBackup()
        }
    }

    /// The user pressed **Synchronize**.
    ///
    /// Deliberately *not* "back up everything on this device". It runs a cycle and reports what
    /// happened; it changes no decision the user has previously recorded. Specifically it does not
    /// lift per-finding "Keep on This Device" exclusions, does not claim findings the account has
    /// never agreed to back up, and does not switch back-up on. Under the old label those were
    /// defensible as an explicit yes (AIA-740); under a neutral one they are not, and
    /// ``backUpNow(expectedAccount:)`` remains the explicit yes for anyone who wants it.
    ///
    /// The account fence is the same one ``backUpNow(expectedAccount:)`` carries and for the same
    /// reason: `AuthState` lags the provider while an account is being validated, so the account
    /// the *user* was looking at travels with the request rather than being read when it lands.
    ///
    /// - Parameter expectedAccount: the account the user was looking at when they pressed.
    @discardableResult
    func synchronizeNow(expectedAccount: String) -> Task<Void, Never>? {
        guard authProvider.accountIdentifier == expectedAccount else { return nil }
        guard isCloudConfigured else { return nil }

        isBackingUp = true
        lastManualBackup = nil
        lastSynchronize = nil

        return Task { [weak self] in
            guard let self else { return }
            defer { self.isBackingUp = false }

            // `backupConsentRequest` is deliberately NOT cleared. It is an unanswered question about
            // whose findings these are, and a neutral action must not answer it by dismissing it.
            // `backUpNow` clears it because pressing that button *is* the answer.

            // `syncNow()` runs its queued follow-up inside the returned task (AIA-0758), so
            // awaiting it awaits the cycle that actually saw this request -- not one that read the
            // store before the user pressed.
            //
            // A nil task means no cycle ran at all: the account's cloud data is being erased.
            // Reporting an outcome then would invent one -- `outcomeOfSynchronize` reads the
            // *previous* cycle's state, so it would cheerfully say "Up to date." over an account
            // mid-purge.
            guard let cycle = self.syncNow() else { return }
            await cycle.value

            guard self.stillSignedIn(as: expectedAccount) else { return }
            self.lastSynchronize = self.outcomeOfSynchronize()
        }
    }

    /// Turns the cycle Synchronize just ran into something the button can say.
    ///
    /// Distinct from ``outcomeOfManualBackup()`` on two points that matter:
    ///
    /// 1. **Standing parked uploads are not this cycle's failure.** A `payload_too_large` park never
    ///    clears until the finding is edited, so reporting it here would send the same permanent
    ///    condition to Sentry on every press. The user is still told about it -- the parked count
    ///    sits above the list -- but it is status, not the result of what they just asked for.
    /// 2. **Success claims nothing about backing up.** A cycle with back-up switched off pushes
    ///    nothing at all, so "your findings are backed up" would be false. Success here means the
    ///    cycle finished, and the pending count says what is still owed.
    private func outcomeOfSynchronize() -> ManualBackupOutcome {
        // Running out of room is not a failed cycle, but it is the one state the user must act on,
        // and the wording names the way out.
        if isQuotaBlocked { return .quotaFull }
        guard let failure = lastCycleFailure else { return .succeeded }
        // Offline is a property of the network, never of the error -- same reasoning as the
        // back-up path, and the same reason it is checked before anything is reported.
        if monitor.currentPath.status != .satisfied { return .offline }
        Observability.captureError("Findings synchronize failed", error: failure)
        return .failed
    }

    /// Turns the last cycle into something the button can say.
    ///
    /// Offline is checked before the error is inspected, and separately from it: a request that
    /// failed because there is no network is not a fault, and reporting one to Sentry every time
    /// somebody presses the button in a valley would spend the error quota on the feature working
    /// as designed.
    private func outcomeOfManualBackup() -> ManualBackupOutcome {
        // Checked before the failure, because running out of room is not a failed cycle: the upload
        // is refused permanently and parked, and the cycle itself completes.
        if isQuotaBlocked { return .quotaFull }
        // Anything else parked was refused permanently too -- `payload_too_large`, `bad_request`.
        // The cycle completed, but a finding the user asked to back up is not backed up, and saying
        // "your findings are backed up" would be false.
        if parkedCount > 0, lastCycleFailure == nil {
            Observability.captureError("Findings back-up left findings parked")
            return .failed
        }
        guard let failure = lastCycleFailure else { return .succeeded }
        // Offline is a property of the network, never of the error. Deciding it from the error
        // instead once reported "no connection" for a malformed response on a working connection --
        // and, worse, sent nothing to Sentry, so the bug was invisible.
        if monitor.currentPath.status != .satisfied { return .offline }
        Observability.captureError("Findings back-up failed", error: failure)
        return .failed
    }

    /// The user answered the back-up question. Accepting uploads what was waiting; declining
    /// records that decision so the outbox stops re-deriving those findings and asking again.
    @discardableResult
    func answerBackupConsent(accepted: Bool) -> Task<Void, Never>? {
        // Answers exactly one outstanding request, for the account it was asked about. Clearing it
        // first makes a second call a no-op, which is what stops the alert's own dismissal from
        // racing the button the user actually pressed.
        guard let request = backupConsentRequest else { return nil }
        backupConsentRequest = nil
        guard authProvider.accountIdentifier == request.account else { return nil }

        // Queued for the cycle to apply, never written here. The card is raised from inside a
        // running cycle, so by the time the user answers that cycle is usually still uploading --
        // and it holds a copy of the ledger that predates the answer.
        //
        // Only what was actually asked about is recorded. A blanket exclusion would also cover
        // findings the cloud already holds, and a later edit to one of those would never upload.
        let keys = Set(request.ids.map(\.uuidString))
        if var queued = pendingConsentAnswer[request.account], queued.accepted == accepted {
            queued.keys.formUnion(keys)
            pendingConsentAnswer[request.account] = queued
        } else {
            pendingConsentAnswer[request.account] = (accepted: accepted, keys: keys)
        }

        return Task { [weak self] in
            await self?.syncNow()?.value
        }
    }

    // MARK: - The cycle

    private func cycle() async {
        guard let account = authProvider.accountIdentifier else {
            // Signed out: leave local data and the ledger exactly as they are, but stop showing one
            // account's storage state to whoever is looking at the app now. On a shared device the
            // next person would otherwise see the last one's "backed up" label and full-quota band.
            pendingUploadCount = 0
            parkedCount = 0
            isQuotaBlocked = false
            usage = nil
            lastManualBackup = nil
            lastSynchronize = nil
            backupConsentRequest = nil
            // Every row loses its icon. A signed-out person is not owed a report on somebody's
            // cloud, and on a shared device the last account's ticks would be exactly that.
            backupStates = [:]
            lastSyncedAccount = nil
            return
        }
        // A different account than the last cycle saw. The signed-out branch above clears this
        // state, but signing straight from one account into another never passes through it -- and
        // the outcome line is a claim about somebody's data ("Up to date.", "Your findings are
        // backed up"). Left standing it makes that claim to the wrong person, which on a shared
        // device is exactly the confusion the consent card exists to prevent.
        if lastSyncedAccount != account {
            lastSyncedAccount = account
            lastManualBackup = nil
            lastSynchronize = nil
            backupConsentRequest = nil
            parkedCount = 0
            isQuotaBlocked = false
            usage = nil
            // Cleared here and not only on sign-out: A -> B directly never passes through the
            // nil-account branch above, and stale ticks would then mark B's findings with A's
            // ledger -- one account's rows claiming another account's cloud.
            backupStates = [:]
        }

        guard let baseURL = FindingsCloudEndpoint.baseURL(for: BackendEnvironment.current) else {
            // No Worker for this build. Sync is off rather than pointed somewhere wrong.
            return
        }

        let started = Date()
        uploaded = 0
        applied = 0

        let store = ledgerStore(for: account)
        let cloud = transport(for: baseURL, account: account)
        var ledger = await store.loadLedger()

        // The queued intents are taken off their queues here and live only in this cycle's copy of
        // the ledger until the save at the end. Any path that leaves before that save puts them
        // back, so a sign-out mid-cycle cannot quietly discard a stop the user asked for or an
        // answer they gave the card.
        let claims = Claims(
            created: createdWhileSignedIn.removeValue(forKey: account),
            manual: pendingManualBackup.removeValue(forKey: account),
            preference: pendingBackUpPreference.removeValue(forKey: account),
            consent: pendingConsentAnswer.removeValue(forKey: account)
        )
        var claimsAreSaved = false
        defer { if claimsAreSaved == false { requeue(claims, for: account) } }

        claims.apply(to: &ledger)
        isBackUpEnabled = ledger.backUpEnabled

        lastCycleFailure = nil
        do {
            // Off means nothing leaves the device -- including findings created while signed in,
            // which is the case that made the absence of this switch confusing (AIA-744). The pull
            // still runs: what is already in the cloud is the user's, and a reinstall must still
            // restore it. Turning back-up off is not a request to forget what was backed up.
            // Tombstones flush whichever way the switch is set. Deleting a finding is not backing
            // one up: with back-up off, a delete that never reached the Worker would leave the
            // coordinates in the cloud indefinitely, while "Remove all findings" promises the
            // opposite (AIA-744).
            try await flushTombstones(account: account, transport: cloud, ledger: &ledger)
            if ledger.backUpEnabled {
                try await push(account: account, store: store, transport: cloud, ledger: &ledger)
            }
            try await pull(account: account, store: store, transport: cloud, ledger: &ledger)
        } catch is CancellationError {
            return
        } catch let error as FindingsCloudError {
            // A cycle that could not finish is not a failure to report at the finding level: the
            // next trigger picks up exactly where the ledger says this one stopped.
            lastCycleFailure = error
            LoggingPolicy.warning("Findings sync stopped: \(String(describing: error.code ?? "transport"))", logger: .networking)
        } catch {
            lastCycleFailure = error
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
        isQuotaBlocked = blocked
        if blocked != ledger.isReportedQuotaBlocked {
            ledger.isReportedQuotaBlocked = blocked
            if blocked { analytics?.track(.cloudSyncQuotaBlocked) }
        }

        // Only a write that landed clears the claims. A failed one (a full disk) used to look
        // exactly like a successful one, and the intents this cycle had taken off the queue went
        // with it -- backing up could switch itself back on after the user had stopped it.
        claimsAreSaved = await store.save(ledger)
        refreshCounts(from: ledger)
    }

    /// What one cycle took off the intent queues, so it can be put back if the cycle never saved.
    private struct Claims {
        var created: Set<String>?
        var manual: Set<String>?
        var preference: Bool?
        var consent: (accepted: Bool, keys: Set<String>)?

        func apply(to ledger: inout FindingsSyncLedger) {
            if let created {
                ledger.owned.formUnion(created)
            }
            // An explicit "back up my findings" is a yes for everything it named, so it also lifts
            // any earlier exclusion on those ids -- that lifting is the whole of AIA-740.
            if let manual {
                ledger.owned.formUnion(manual)
                ledger.excluded.subtract(manual)
            }
            if let preference {
                ledger.backUpEnabled = preference
            }
            guard let consent else { return }
            if consent.accepted {
                ledger.owned.formUnion(consent.keys)
                ledger.excluded.subtract(consent.keys)
            } else {
                ledger.excluded.formUnion(consent.keys)
            }
        }
    }

    /// Puts back everything a cycle claimed but never persisted.
    ///
    /// Merged rather than assigned: a trigger that arrived while the cycle ran may already have
    /// queued more, and that is not this cycle's to discard. A newer preference or answer wins,
    /// because it is the more recent thing the user said.
    private func requeue(_ claims: Claims, for account: String) {
        if let created = claims.created {
            createdWhileSignedIn[account, default: []].formUnion(created)
        }
        if let manual = claims.manual {
            pendingManualBackup[account, default: []].formUnion(manual)
        }
        if let preference = claims.preference, pendingBackUpPreference[account] == nil {
            pendingBackUpPreference[account] = preference
        }
        if let consent = claims.consent {
            guard var queued = pendingConsentAnswer[account] else {
                pendingConsentAnswer[account] = consent
                return
            }
            if queued.accepted == consent.accepted {
                // Same answer, different findings: merging is exactly right.
                queued.keys.formUnion(consent.keys)
                pendingConsentAnswer[account] = queued
            }
            // Opposite answers cannot share one entry -- it carries a single `accepted` -- and
            // merging the older keys into the newer one stamps the newer ANSWER on them. A "Keep on
            // This Device" would have become a yes and uploaded a name, coordinates and a
            // photograph the user had declined. So the older claim is dropped and those findings go
            // back to unclaimed, which raises the card again. Being asked twice is harmless; the
            // other outcome is not, and asking again is the safe direction this file already takes
            // for every other lost intent.
        }
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

    /// Sends every recorded delete, whether or not backing up is switched on.
    ///
    /// Deleting is not backing up. Gating this behind the switch left a user who had turned back-up
    /// off unable to remove anything from the cloud at all -- including through "Remove all
    /// findings", which promises permanent deletion in as many words.
    private func flushTombstones(
        account: String,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async throws {
        let tombstones = ledgerStore(for: account).tombstones
        var freedRoom = false
        for pending in tombstones.load() {
            guard stillSignedIn(as: account) else { throw CancellationError() }
            let key = pending.id.uuidString
            do {
                let result = try await transport.delete(id: pending.id, modifiedAt: pending.modifiedAt)
                tombstones.remove(pending.id)
                ledger.uploaded[key] = nil
                // The finding is gone, so a park recorded against it is a ghost: it would keep
                // `parkedCount` and the storage-full band alive for something that no longer exists.
                ledger.parked[key] = nil
                usage = result.usage
                freedRoom = true
            } catch let error as FindingsCloudError where error.code == "stale" {
                // Something newer than this delete is already stored, so the delete lost. Dropping
                // the tombstone is the whole of the fix: the winner arrives on the next pull, and
                // last-write-wins is what the epic pinned for delete-versus-edit.
                tombstones.remove(pending.id)
            } catch let error as FindingsCloudError where error.isRetryable == false {
                tombstones.remove(pending.id)
                ledger.parked[key] = nil
                LoggingPolicy.warning("A findings delete was refused permanently and dropped", logger: .networking)
            }
        }

        // Running out of room is an account-level condition and a curable one: the app tells the
        // user to remove or export findings, so the parks it caused have to lift when they do.
        // Without this they never lifted at all, the button answered "storage full" for ever, and
        // the advice the app gives did not work.
        let hasRoom = usage.map { $0.used < $0.limit } ?? false
        if freedRoom || hasRoom {
            for (key, parked) in ledger.parked where parked.code == "quota_exceeded" {
                ledger.parked[key] = nil
            }
        }
    }

    private func push(
        account: String,
        store: FindingsSyncLedgerStore,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async throws {
        // Anything this account did not create here, has not agreed to back up, and has never sent
        // is somebody else's until the user says otherwise. On a shared device the store may hold
        // work belonging to whoever used the app last.
        let unclaimed = syncableFindings()
            .map(\.entityId)
            .filter { ledger.mayUpload(id: $0) == false && ledger.excluded.contains($0.uuidString) == false }
        if unclaimed.isEmpty == false {
            backupConsentRequest = BackupConsentRequest(account: account, ids: unclaimed)
        }

        for finding in uploadCandidates(ledger: ledger) {
            guard stillSignedIn(as: account) else { throw CancellationError() }
            // Re-read the switch between findings. This cycle loaded the ledger before the user
            // reached for it, and without this check flipping back-up off went on uploading every
            // remaining candidate while the control already read off.
            guard pendingBackUpPreference[account] != false else {
                LoggingPolicy.info("Findings back-up stopped mid-cycle at the user's request", logger: .networking)
                return
            }
            try await upload(finding, account: account, transport: transport, ledger: &ledger)
            // Persisted per finding, not once at the end of the cycle. The acknowledgement is what
            // routes a later delete to the right account, so a crash between the Worker committing
            // a finding and this device writing that down leaves a cloud copy nothing can reach --
            // and signing out then deleting it locally would enqueue no tombstone at all.
            await store.save(ledger)
        }
    }

    private func upload(
        _ finding: Finding,
        account: String,
        transport: FindingsCloudTransport,
        ledger: inout FindingsSyncLedger
    ) async throws {
        let entityId = finding.entityId
        let key = entityId.uuidString
        let sent = effectiveMilliseconds(of: finding)
        // The snapshot's own `modifiedAt` is the local `Date`, which is neither truncated to whole
        // milliseconds nor clamped by the server. Sending it would mean a downloaded copy restored
        // a timestamp the index disagrees with, and the finding would look permanently unsettled.
        let snapshot = FindingSnapshot(finding, modifiedAt: Date(timeIntervalSince1970: Double(sent) / 1000))

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
            if let winner = error.winner, error.code == "stale" {
                // The winner is fetched now rather than waited for. A rejected write creates no new
                // receipt, so if this device's cursor is already past the winner it would never
                // come round on a pull -- the losing copy would simply stay wrong for ever.
                //
                // Acknowledged only if it actually landed. Recording the winner's timestamp after a
                // download that failed left this device holding the losing copy with nothing left
                // to make it upload or re-list: permanently, silently wrong.
                if case .applied = await download(winner, account: account, transport: transport) {
                    ledger.uploaded[key] = winner.modifiedAt
                }
            } else if Self.isTerminalForOneFinding(error.code) {
                ledger.parked[key] = ParkedUpload(code: error.code ?? "unknown", modifiedAt: sent)
            } else {
                // Anything else -- an unrecognised code, a malformed body, a stale response with no
                // winner -- is treated as worth retrying. Parking is what strands a finding, so it
                // is reserved for failures that are verifiably about this finding and cannot be
                // cured by trying again.
                throw error
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
            var pageApplied = true
            for row in page.findings {
                guard stillSignedIn(as: account) else { throw CancellationError() }
                if await apply(row, account: account, transport: transport, store: store, ledger: &ledger) == .halted {
                    // One row that did not land stops the page. Advancing over it would move the
                    // cursor past a finding this device never received, and no later cycle would
                    // ever look at it again.
                    pageApplied = false
                    break
                }
            }
            usage = page.usage
            guard pageApplied else { break }
            cursor = page.nextCursor
            // The cursor moves only after a page has been applied, so an interrupted pull resumes
            // rather than skipping what it did not get to.
            ledger.cursor = cursor
            // The end of the index, with every page applied, is the moment `uploaded` has been
            // rebuilt from the account's own records -- so a ledger that was reset after corruption
            // stops being treated as holding unknown copies (AIA-0755). Cleared BEFORE the save so
            // it lands in the same write: clearing after it would be lost whenever the cycle stops
            // for a sign-out, and the account would keep writing conservative tombstones until some
            // later pull happened to finish.
            // Every row the index listed has been recorded by now -- `apply` records even the rows
            // it could not use while the flag is set -- so the ledger is authoritative again.
            if page.hasMore == false { ledger.holdsUnknownCloudCopies = false }
            await store.save(ledger)
            guardRail += 1
            if page.hasMore == false { break }
        } while guardRail < 200
    }

    /// What a pull did with one row of the index.
    private enum RowDisposition {
        /// Dealt with, and the ledger now records what the account holds for it.
        case accounted
        /// Not dealt with. Stops the page, so the cursor does not step past it.
        case halted
    }

    /// What became of one downloaded row.
    private enum DownloadOutcome {
        case applied
        /// A newer local edit or delete appeared while the download was in flight, so the cloud
        /// copy lost after all and this device now owes the cloud its own version.
        case supersededLocally
        /// The row is not there to fetch, or the session it belonged to is over. Move past it.
        case skipped
        /// Worth another go. The cursor stays where it is.
        case failed
    }

    /// What became of one row. `.halted` stops the page.
    private func apply(
        _ row: CloudFindingRow,
        account: String,
        transport: FindingsCloudTransport,
        store: FindingsSyncLedgerStore,
        ledger: inout FindingsSyncLedger
    ) async -> RowDisposition {
        let key = row.id.uuidString

        // A delete the user has made but this device has not yet sent outranks a live cloud row it
        // has not seen: applying the row would put the finding back on this device, and the next
        // push would then be deleting something it had just re-downloaded.
        if row.deleted == false,
           let pending = store.tombstones.load().first(where: { $0.id == row.id }),
           pending.modifiedAt >= row.modifiedAt {
            return .accounted
        }
        let local = Finding.select(row.id, in: context)
        let localModifiedAt = local.map { effectiveMilliseconds(of: $0) }

        if row.deleted {
            // A tombstone loses to a local edit that is newer than it, exactly like any other
            // conflict. `uploaded` is cleared either way: if the local copy won, this device now
            // owes the cloud that newer version.
            if let localModifiedAt, localModifiedAt > row.modifiedAt {
                ledger.uploaded[key] = nil
                return .accounted
            }
            do {
                try findingRepository.deleteReceivedFromCloud(row.id)
            } catch {
                LoggingPolicy.warning("Could not apply a synced delete: \(error.localizedDescription)", logger: .storage)
                return .halted
            }
            ledger.uploaded[key] = nil
            return .accounted
        }

        if let localModifiedAt, localModifiedAt >= row.modifiedAt {
            // This device is already at least as new, and either way the row is recorded as held.
            //
            // On an EQUAL timestamp it is this device's own write coming back, and without the
            // record the finding would look permanently owed and be pushed again on every cycle.
            //
            // On a NEWER local copy this used to record nothing, which was safe only because the
            // push that follows would record it. A ledger rebuilt after corruption has back-up
            // switched off, so no push runs -- and `accountsHolding` would then fail to name this
            // account for every finding edited since it was uploaded, which is precisely the
            // deleted-finding-comes-back bug AIA-0755 exists to close. The index has just said the
            // account holds this row, so saying so locally is a statement of fact, not a new
            // permission: `mayUpload` still refuses anything the user excluded, and `needsUpload`
            // still returns true because the local copy is newer than what is confirmed.
            //
            // It does change one visible thing. A finding this account holds but did not create
            // here used to sit on the consent card until a push recorded it; now it leaves the
            // card at the pull. That is the right way round: the card asks whether the account may
            // have a finding, and the account's own index has just answered that it already does.
            // Asking a question whose premise the server has disproved is not consent, it is
            // noise -- and `excluded` still wins, so a "no" the user has already given stands.
            ledger.uploaded[key] = row.modifiedAt
            return .accounted
        }

        // Awaited, not spawned. A detached download would let the cursor advance past this row
        // while it was still in flight, and a download that then failed would never be retried --
        // the finding would be missing from this device for ever.
        switch await download(row, account: account, transport: transport) {
        case .applied:
            applied += 1
            // Recording what was just applied is what stops a fresh install downloading N findings
            // and immediately pushing all N back, each with a new receipt, which every other device
            // would then pull again.
            ledger.uploaded[key] = row.modifiedAt
            return .accounted
        case .supersededLocally:
            // The local copy moved on while this was in flight and is now the newer one -- the
            // same state as the local-newer branch above, one suspension later, and recorded the
            // same way: the index lists the row, so the account holds it. The next push still
            // sends the local copy, because `needsUpload` compares the local timestamp against
            // this one and local is newer. Clearing the entry instead used to be how that push was
            // triggered, and while a ledger is rebuilding it left a held finding unnamed
            // (AIA-0755): the walk ended, the flag cleared, and a signed-out delete of that
            // finding wrote no tombstone for the account.
            ledger.uploaded[key] = row.modifiedAt
            return .accounted
        case .skipped:
            // Moved past without a copy landing. Ordinarily nothing is recorded: what the cloud
            // holds for this id is a blob this build could not use, and claiming it as uploaded
            // would be a guess. While the ledger is being REBUILT after corruption the rule is the
            // opposite (AIA-0755): the index listed the row, and "rebuilt from the index" has to
            // mean every row the index listed -- otherwise the walk ends, the flag clears, the
            // cursor never comes back this way, and a signed-out delete writes no tombstone for a
            // finding the account still holds. `mayUpload` still refuses anything excluded.
            if ledger.holdsUnknownCloudCopies { ledger.uploaded[key] = row.modifiedAt }
            return .accounted
        case .failed:
            return .halted
        }
    }

    /// Fetches one finding and writes it in, or explains why it did not.
    ///
    /// Every network call here is a suspension, and two things can change across one: which account
    /// is signed in, and what the local copy of this finding says. Both are re-checked immediately
    /// before the import, because that is the only point at which either can do damage -- one would
    /// write somebody else's fieldwork into the session that replaced theirs, the other would
    /// overwrite an edit the user made while the download was in the air.
    private func download(
        _ row: CloudFindingRow,
        account: String,
        transport: FindingsCloudTransport
    ) async -> DownloadOutcome {
        do {
            let meta = try await transport.downloadMeta(id: row.id)
            let rows = try FindingArchiveImport.decodeRows(meta)
            // The blob does not describe the finding the index said it would. Retrying re-fetches
            // the same bytes, so halting here would strand every finding behind it.
            guard let stored = rows.first(where: { $0.id == row.id }) else {
                Observability.captureError("A synced finding's metadata named a different finding")
                return .skipped
            }
            // The index is authoritative about ordering, so a metadata blob that disagrees -- an
            // older client's rounding, or a value the server clamped after it was written -- does
            // not get to set the local timestamp.
            let decoded = stored.replacingModifiedAt(Date(timeIntervalSince1970: Double(row.modifiedAt) / 1000))

            // One image, already in memory: cloud sync downloads exactly one, so the `.data` case
            // is the right payload. The archive path stages to files instead, because holding all
            // of them was what stopped a self-export from being re-importable (AIA-0755).
            var images: [UUID: ImportedImage] = [:]
            if row.hasImage {
                do {
                    let bytes = try await transport.downloadImage(id: row.id)
                    // Downloaded bytes get the same bounds an archive's would. Sync bypasses the
                    // archive reader, so without this a small file declaring an enormous canvas
                    // would be stored unchecked and allocate wherever the list first draws it.
                    try FindingArchiveImport.validateDownloadedImage(bytes, id: row.id)
                    images[row.id] = .data(bytes)
                } catch let error as FindingsCloudError where error.code == "not_found" {
                    // The picture is gone but the finding is not. Importing it without the image
                    // keeps the title, the note and the coordinates; returning early here used to
                    // throw all of that away and move the cursor past it for ever.
                    LoggingPolicy.warning("A synced finding arrived without its image", logger: .networking)
                }
            }
            // Not `.skipped`: that advances the cursor, and this row was never applied. The
            // account moved on mid-flight, so the page stops here and A's cursor stays put --
            // otherwise A's own device would step permanently past a finding it never received.
            guard stillSignedIn(as: account) else { return .failed }
            // The decision to replace was taken before the downloads; re-take it against what the
            // store says now. A delete or an edit made in the meantime is newer than this row and
            // must not be overwritten by it.
            if let pending = ledgerStore(for: account).tombstones.load().first(where: { $0.id == row.id }),
               pending.modifiedAt >= row.modifiedAt {
                return .supersededLocally
            }
            // `>=`, matching the pre-download rule. Reaching here with an equal timestamp means
            // the local copy was edited DURING the download to the same millisecond -- different
            // content, same instant -- and the coordinator's own rule is that local ties win.
            if let local = Finding.select(row.id, in: context),
               effectiveMilliseconds(of: local) >= row.modifiedAt {
                return .supersededLocally
            }

            // Applied through the repository's own import machinery: it is the only writer allowed
            // to put a screenshot on disk, and it is where `preservesModifiedAt` is handled, so a
            // downloaded copy keeps the timestamp that made it the winner instead of being stamped
            // "now" and handed a false win over the edit it just received.
            let summary = try findingRepository.importFindings(
                FindingArchiveContents(rows: [decoded], images: images),
                duplicates: .replace
            )
            // The import reports per-row failures rather than throwing them -- a screenshot that
            // could not be written because the disk is full, say. Treating that as applied moved
            // the cursor past a finding this device never received, and freeing space later would
            // not bring it back.
            // The import reports per-row outcomes rather than throwing them, and the two kinds
            // have to be told apart. A rejected row is invalid content -- an older or newer build
            // wrote something this one will not accept -- and retrying reproduces it exactly, so
            // halting would strand every finding behind it for ever. A failed row is this device:
            // no disk space, a store error, and that clears.
            if summary.rejected > 0 {
                Observability.captureError("A synced finding was refused by the store as invalid")
                return .skipped
            }
            guard summary.failed == 0, summary.restored == 1 else {
                LoggingPolicy.warning("A synced finding could not be written to the store", logger: .storage)
                return .failed
            }
            return .applied
        } catch let error as FindingsCloudError where error.code == "not_found" {
            // The row was deleted between the listing and the download. Skipping keeps the cursor
            // moving; halting here would block every later finding behind this one for ever.
            LoggingPolicy.warning("A synced finding vanished before it could be downloaded", logger: .networking)
            return .skipped
        } catch let error as FindingsCloudError where error.isRetryable {
            // Worth another go, so the cursor stays put and the next cycle resumes here.
            LoggingPolicy.warning("Could not apply a synced finding: \(error.localizedDescription)", logger: .networking)
            return .failed
        } catch let error as FindingArchiveImportError {
            // Deterministic: metadata this build cannot decode, or an image that fails validation.
            // `decodeRows` wraps every `DecodingError` into `.malformedManifest`, so this one arm
            // covers both. Retrying reproduces it exactly, so halting would strand every finding
            // behind this one for ever. Skipped and reported instead, once, as the cursor moves.
            Observability.captureError("Could not apply a synced finding", error: error)
            return .skipped
        } catch {
            // Everything else -- a Core Data save that failed, a disk with no room left -- is about
            // this device, not this finding, and it clears. Skipping would move the cursor past a
            // finding the user never received and never look at it again.
            LoggingPolicy.warning("Could not store a synced finding: \(error.localizedDescription)", logger: .storage)
            return .failed
        }
    }

    /// Erases this account's cloud findings, and returns only when nothing is left.
    ///
    /// Throws if the purge did not finish. The caller must not delete the Clerk account on a throw:
    /// the session token is the only credential that can reach the remaining data.
    ///
    /// Local findings are deliberately untouched. The cloud copy has just been erased, so they are
    /// the only copy left, and this ticket is about deleting an account -- not somebody's fieldwork.
    /// - Parameter operation: the deletion's correlation id, minted by ``AuthState/deleteAccount()``.
    ///   Every line below carries it so a support log, a Sentry event and the Worker's own request
    ///   log can be lined up against each other afterwards (AIA-0816).
    /// - Returns: whether cloud data was actually erased. False means there was nothing to erase
    ///   -- no account signed in, or a build with no endpoint -- and the caller must not tell the
    ///   user that a back-up was removed.
    @discardableResult
    func purgeCloudData(operation: String) async throws -> Bool {
        // Both early returns are silent successes, and a deletion that made no network request at
        // all is exactly the thing a reconciliation has to be able to explain.
        guard let account = authProvider.accountIdentifier else {
            LoggingPolicy.info("Account deletion \(operation): nobody is signed in; no cloud data to erase", logger: .networking)
            return false
        }
        guard let baseURL = FindingsCloudEndpoint.baseURL(for: BackendEnvironment.current) else {
            LoggingPolicy.info("Account deletion \(operation): this build has no findings endpoint; no cloud data to erase", logger: .networking)
            return false
        }

        // A cycle and a purge are the only two writers of this account's cloud data, and they have
        // to be serialised. An upload that resumed after the purge listed the bucket would leave a
        // screenshot and its coordinates behind a deletion that reported success -- with the token
        // that could name them about to be destroyed, nothing could ever find them again.
        isPurging = true
        defer { isPurging = false }
        runningCycle?.cancel()
        await runningCycle?.value
        wantsAnotherCycle = false

        // The fingerprint, not the id: it survives redaction (which runs at export too, so an
        // `account id:` prefix would reach nobody), it is the same value that names this account's
        // ledger on disk, and support can recompute it from a Clerk id to line this deletion up
        // with Clerk and the Worker's D1 rows.
        let fingerprint = FindingsSyncLedgerStore.fingerprint(of: account)
        LoggingPolicy.info("Account deletion \(operation): purging cloud findings (account fingerprint \(fingerprint))", logger: .networking)
        let result = try await transport(for: baseURL, account: account).purgeAccountData()
        guard result.purged.complete else {
            // The throw is reported by the caller, at `.error`, with the stage named. Logging it
            // here as well would put the same failure in the trail twice.
            throw FindingsCloudError.unreachable("The cloud purge did not finish.")
        }
        LoggingPolicy.info("Account deletion \(operation): purged \(result.purged.objects) objects", logger: .networking)

        // The account's own sync bookkeeping goes with it. The findings do not.
        // Logged as the action, not the outcome: `removeEverything()` swallows a failed file
        // removal, so "cleared" would be a claim this code cannot make.
        LoggingPolicy.info("Account deletion \(operation): discarding the local sync ledger", logger: .networking)
        await ledgerStore(for: account).removeEverything()
        usage = nil
        pendingUploadCount = 0
        backupConsentRequest = nil
        // Every row loses its mark, and this is the third place that has to happen -- sign-out and
        // an account change are the other two. Purging is the one where getting it wrong is worst:
        // the cloud copies are gone, this call is made just before the account itself is deleted,
        // and the cycle that would otherwise rebuild the projection has been cancelled and told not
        // to run again. A green tick would sit there claiming those findings are safe in an account
        // that no longer exists, for as long as the app stayed open.
        backupStates = [:]
        parkedCount = 0
        isQuotaBlocked = false
        // The ledger this account's state was derived from is gone, so the next cycle -- whatever
        // account it runs as -- must rebuild rather than believe it has already seen this one.
        lastSyncedAccount = nil
        return true
    }

    // MARK: - Local state

    /// Records a tombstone synchronously, because the caller is about to commit the delete.
    ///
    /// This used to hop onto a `Task`, which put a suspension point between recording the delete
    /// and performing it. A crash in that window lost the tombstone, and the finding came back from
    /// another device on the next sync -- coordinates reappearing after the user removed them.
    private func recordDelete(_ entityId: UUID) throws {
        let delete = PendingDelete(id: entityId, modifiedAt: Self.milliseconds(now()))
        // Whichever account is signed in gets the tombstone, and so does any account whose ledger
        // says it holds this finding. A user can delete while signed out, or while signed in as
        // someone else, and the cloud copy still has to go.
        var accounts = Set<String>()
        if let account = authProvider.accountIdentifier { accounts.insert(account) }
        accounts.formUnion(FindingsSyncLedgerStore.accountsHolding(entityId, in: ledgerDirectory))
        for account in accounts {
            try ledgerStore(for: account).tombstones.enqueue(delete)
        }
    }

    /// Records tombstones for a batch about to be removed wholesale.
    ///
    /// "Remove all findings" promises permanent deletion. Without this the local rows would go and
    /// every cloud copy would stay, ready to come back on the next sync.
    func recordBulkDelete(_ entityIds: [UUID]) throws {
        for entityId in entityIds {
            try recordDelete(entityId)
        }
    }

    /// The findings sync is about: the ones the user can actually see.
    ///
    /// `selectAll` also returns rows still being assembled. Counting those made the card ask about
    /// more findings than the list shows, and backing one up would have put a half-written draft
    /// into the account.
    private func syncableFindings() -> [Finding] {
        Finding.selectAll(in: context).filter { $0.lifeCycleString == CoreDataManageableState.ready.rawValue }
    }

    private func uploadCandidates(ledger: FindingsSyncLedger) -> [Finding] {
        syncableFindings().filter { finding in
            return ledger.needsUpload(id: finding.entityId, localModifiedAt: effectiveMilliseconds(of: finding))
        }
    }

    private func refreshCounts(from ledger: FindingsSyncLedger) {
        pendingUploadCount = uploadCandidates(ledger: ledger).count
        parkedCount = ledger.parked.count
        backupStates = Self.backupStates(for: syncableFindings(), ledger: ledger) { [weak self] finding in
            self?.effectiveMilliseconds(of: finding) ?? 0
        }
    }

    /// One state per finding, derived from the ledger the cycle just saved (AIA-0735).
    ///
    /// A `static` taking its inputs rather than reading `self`, so the derivation is testable on its
    /// own and cannot accidentally consult live state that the ledger disagrees with.
    ///
    /// Order matters. `excluded` is checked first because a finding the user chose to keep here can
    /// also look "owed" -- it has never been uploaded -- and reporting it as merely waiting would be
    /// the same lie the list told before this existed.
    static func backupStates(
        for findings: [Finding],
        ledger: FindingsSyncLedger,
        modifiedAt: (Finding) -> Int64
    ) -> [UUID: FindingBackupState] {
        var states: [UUID: FindingBackupState] = [:]
        for finding in findings {
            let id = finding.entityId
            let key = id.uuidString
            let localModifiedAt = modifiedAt(finding)

            if ledger.excluded.contains(key) {
                states[id] = .keptOnDevice
                continue
            }

            // Parked BEFORE the receipt is consulted, and this order is the whole point.
            //
            // `needsUpload` answers "should the outbox try again", and for a parked finding that is
            // false -- retrying cannot cure what was refused. Reading that as "nothing owed" and
            // falling through to the receipt turned a permanent failure into a green tick: a
            // finding uploaded at t=1000, edited to t=2000, then refused for good keeps its t=1000
            // receipt, so the row went green at the exact moment the edit was lost. The cloud holds
            // the copy from before the edit, and the user is being told their work is safe.
            //
            // A park is only cleared by editing the finding again, which moves `modifiedAt` past
            // the parked stamp -- so the row recovers by itself once there is something new to send.
            if let parked = ledger.parked[key], parked.modifiedAt >= localModifiedAt {
                states[id] = .owed
                continue
            }

            if ledger.needsUpload(id: id, localModifiedAt: localModifiedAt) {
                states[id] = .owed
            } else if ledger.uploaded[key] != nil {
                states[id] = .backedUp
            } else {
                // Never sent: either nobody has answered the consent card for it, or back-up is
                // switched off. Owed is the honest answer -- it is not in the cloud, whatever the
                // reason -- and the line above the list is where the reason is spelled out.
                states[id] = .owed
            }
        }
        return states
    }

    /// Failures that are about this one finding and that retrying cannot cure.
    ///
    /// `quota_exceeded` is here because only pruning or exporting makes room; the others because
    /// the payload itself is what was refused. Everything else backs off instead: an outbox that
    /// parks on an ambiguous failure quietly stops backing a user up.
    private static func isTerminalForOneFinding(_ code: String?) -> Bool {
        ["quota_exceeded", "payload_too_large", "bad_request"].contains(code ?? "")
    }

    /// The ordering key for a finding, in whole milliseconds, and never the epoch.
    ///
    /// Rows migrated from 0.0.0/0.0.1 arrive with `modifiedAt == nil`, so the fallback is
    /// `creationDate_`. When even that is missing the finding is stamped now and the stamp is
    /// persisted, because treating nil as the epoch would lose every legacy finding to any cloud
    /// copy at all -- which is the one outcome the epic rules out by name.
    private func effectiveMilliseconds(of finding: Finding) -> Int64 {
        if let modifiedAt = finding.modifiedAt { return Self.milliseconds(modifiedAt) }
        if let created = finding.creationDate_ { return Self.milliseconds(created) }
        let stamped = now()
        finding.modifiedAt = stamped
        try? Finding.save(in: context)
        return Self.milliseconds(stamped)
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
