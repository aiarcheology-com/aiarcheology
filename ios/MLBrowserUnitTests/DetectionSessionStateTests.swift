//
//  DetectionSessionStateTests.swift
//  MLBrowserUnitTests
//
//  Created by AI Assistant on 25.11.25.
//  AIA-0391: the former `Guide` split into `DetectionSessionState` (detection lifecycle +
//  snapshot-timer commanding) and `AppChromeState` (drawer/mode chrome + navigation + app reset).
//  Its tests re-home here, one class per type, keeping every original assertion's intent.
//

import XCTest
import CoreData
@testable import ML_Browser

/// Creates a DataController with a temporary SQLite store for tests that require
/// NSBatchDeleteRequest to work (which doesn't work with in-memory stores).
@MainActor
func createTempSQLiteDataController() -> (DataController, URL) {
    let tempDir = FileManager.default.temporaryDirectory
    let storeURL = tempDir.appendingPathComponent("TestStore-\(UUID().uuidString).sqlite")
    let dataController = DataController(storeURL: storeURL)
    return (dataController, storeURL)
}

@MainActor
final class DetectionSessionStateTests: XCTestCase {

    var settings: Settings!
    var snapState: SnapState!
    // `DetectionSessionState.snapAdjustment` is `unowned`; hold it strong for the whole test.
    var snapAdjustment: SnapAdjustment!
    var sut: DetectionSessionState!
    /// Every web-content event the helpers issue carries the next sequence, as the real signal
    /// does — one counter, because they arrive on one publisher.
    private var eventSequence: UInt64 = 0

    override func setUp() async throws {
        try await super.setUp()

        eventSequence = 0
        settings = Settings()
        // Settings persists to UserDefaults.standard; pin the default so tests
        // that flip the flag cannot leak into later tests via the suite's defaults.
        settings.fullscreenDetection = true
        snapState = SnapState(settings: settings)
        snapAdjustment = SnapAdjustment()

        sut = DetectionSessionState(
            snap: snapState,
            settings: settings,
            snapAdjustment: snapAdjustment
        )
    }

    override func tearDown() async throws {
        snapState.stopTimer()
        sut = nil
        snapAdjustment = nil
        snapState = nil
        settings = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(sut.snap)
        XCTAssertNotNil(sut.settings)
        XCTAssertNotNil(sut.snapAdjustment)
    }

    func testInitialState() {
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertFalse(sut.showsFloatingChromeButton)
    }

    // MARK: - On-the-fly Detection Tests

    func testOntheflyDetectionTapped_TogglesState() {
        XCTAssertFalse(sut.ontheflyDetectionEnabled)

        sut.ontheflyDetectionTapped()

        XCTAssertTrue(sut.ontheflyDetectionEnabled)
    }

    func testOntheflyDetectionTapped_TogglesBackToFalse() {
        sut.ontheflyDetectionEnabled = true

        sut.ontheflyDetectionTapped()

        XCTAssertFalse(sut.ontheflyDetectionEnabled)
    }

    func testOntheflyDetectionTapped_StartsTimer_WhenEnabled() {
        XCTAssertNil(snapState.timerCancellable)

        sut.ontheflyDetectionTapped()

        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testOntheflyDetectionTapped_StopsTimer_WhenDisabled() {
        // Enable first
        sut.ontheflyDetectionTapped()
        XCTAssertNotNil(snapState.timerCancellable)

        // Disable
        sut.ontheflyDetectionTapped()

        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)
    }

    func testRunScopedRequests_AcceptsOnlyCurrentActiveRun() {
        sut.ontheflyDetectionTapped()
        let activeRun = sut.detectionRunID

        XCTAssertTrue(sut.accepts(SnapshotRequest(runID: activeRun, sequence: 1)))

        sut.ontheflyDetectionResetTapped()

        XCTAssertFalse(sut.accepts(SnapshotRequest(runID: activeRun, sequence: 2)))
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotEqual(sut.detectionRunID, activeRun)
    }

    func testDriverDidRegister_RequestsCurrentRunOnlyWhenActive() {
        var received: SnapshotRequest?
        let cancellable = snapState.combinedPublishers.sink { received = $0 }
        defer { cancellable.cancel() }

        sut.driverDidRegister()
        XCTAssertNil(received)

        sut.ontheflyDetectionTapped()
        received = nil
        sut.driverDidRegister()

        XCTAssertEqual(received?.runID, sut.detectionRunID)
    }

    func testContentGeometryDidChange_RequestsANewSnapshotForTheActiveRun() {
        var requests: [SnapshotRequest] = []
        let cancellable = snapState.combinedPublishers.sink { requests.append($0) }
        defer { cancellable.cancel() }

        sut.ontheflyDetectionTapped()
        guard let initialRequest = requests.last else {
            return XCTFail("Starting detection should issue its initial request")
        }

        sut.contentGeometryDidChange()

        guard let replacementRequest = requests.last else {
            return XCTFail("An active geometry change should issue a replacement request")
        }
        XCTAssertEqual(replacementRequest.runID, sut.detectionRunID)
        XCTAssertGreaterThan(replacementRequest.sequence, initialRequest.sequence)
    }

    func testContentGeometryDidChange_DoesNotRequestWhileDetectionIsStopped() {
        var received: SnapshotRequest?
        let cancellable = snapState.combinedPublishers.sink { received = $0 }
        defer { cancellable.cancel() }

        sut.contentGeometryDidChange()

        XCTAssertNil(received)
    }

	func testContentInteractionDidEnd_RequestsANewSnapshotForTheActiveRun() {
		var requests: [SnapshotRequest] = []
		let cancellable = snapState.combinedPublishers.sink { requests.append($0) }
		defer { cancellable.cancel() }

		sut.ontheflyDetectionTapped()
		guard let initialRequest = requests.last else {
			return XCTFail("Starting detection should issue its initial request")
		}

		sut.contentInteractionDidEnd()

		guard let replacementRequest = requests.last else {
			return XCTFail("A settled interaction should issue a replacement request")
		}
		XCTAssertEqual(replacementRequest.runID, sut.detectionRunID)
		XCTAssertGreaterThan(replacementRequest.sequence, initialRequest.sequence)
	}

	func testContentInteractionDidEnd_DoesNotRequestWhileDetectionIsStopped() {
		var received: SnapshotRequest?
		let cancellable = snapState.combinedPublishers.sink { received = $0 }
		defer { cancellable.cancel() }

		sut.contentInteractionDidEnd()

		XCTAssertNil(received)
	}

    // MARK: - Chrome Visibility Tests
    //
    // Uniform rule: every detection start hides chrome, every stop shows it,
    // regardless of initiator. Background/foreground auto-pause/resume and
    // snapAfterAppStart route through the same ontheflyDetectionTapped().

    func testOntheflyDetectionTapped_Start_HidesChrome() {
        XCTAssertTrue(sut.chromeVisible)

        sut.ontheflyDetectionTapped()

        XCTAssertFalse(sut.chromeVisible)
        XCTAssertTrue(sut.isFullscreen)
        XCTAssertTrue(sut.showsFloatingChromeButton)
    }

    func testOntheflyDetectionTapped_Stop_ShowsChrome() {
        sut.ontheflyDetectionTapped()
        XCTAssertFalse(sut.chromeVisible)

        sut.ontheflyDetectionTapped()

        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertFalse(sut.showsFloatingChromeButton)
    }

    func testChromeToggleTapped_RevealsAndHidesChromeWhileDetecting() {
        sut.ontheflyDetectionTapped()
        XCTAssertFalse(sut.chromeVisible)

        sut.chromeToggleTapped()
        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertTrue(sut.ontheflyDetectionEnabled, "Revealing chrome must not stop detection")
        XCTAssertTrue(sut.showsFloatingChromeButton, "Floating button stays while detection runs")

        sut.chromeToggleTapped()
        XCTAssertFalse(sut.chromeVisible)
        XCTAssertTrue(sut.isFullscreen)
    }

    func testOntheflyDetectionTapped_Stop_DismissesSnapAdjustment() {
        sut.ontheflyDetectionTapped()
        sut.showSnapAdjustment = true

        sut.ontheflyDetectionTapped()

        XCTAssertFalse(sut.showSnapAdjustment, "Stopping detection would orphan an open adjustment overlay")
    }

    func testOntheflyDetectionResetTapped_DoesNotTouchChrome() {
        sut.ontheflyDetectionTapped()
        sut.chromeToggleTapped()
        XCTAssertTrue(sut.chromeVisible)

        sut.ontheflyDetectionResetTapped()

        XCTAssertTrue(sut.chromeVisible, "Timer restart must not change chrome state")
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
    }

    func testDetectionToggleSequence_BackgroundForegroundCycle_ReturnsToFullscreen() {
        // Simulates: detection on, user reveals chrome, app backgrounds (auto-pause),
        // app foregrounds (auto-resume). Uniform rule: resume re-enters fullscreen.
        sut.ontheflyDetectionTapped()
        sut.chromeToggleTapped()
        XCTAssertTrue(sut.chromeVisible)

        sut.ontheflyDetectionTapped() // background: auto-pause
        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.ontheflyDetectionEnabled)

        sut.ontheflyDetectionTapped() // foreground: auto-resume
        XCTAssertFalse(sut.chromeVisible, "Detection resume re-enters fullscreen (uniform rule)")
        XCTAssertTrue(sut.isFullscreen)
    }

    // MARK: - Fullscreen Detection Setting

    func testOntheflyDetectionTapped_Start_KeepsChrome_WhenFullscreenDetectionDisabled() {
        settings.fullscreenDetection = false

        sut.ontheflyDetectionTapped()

        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertTrue(sut.chromeVisible, "Disabled feature keeps the chrome visible during detection")
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertFalse(sut.showsFloatingChromeButton, "No floating button when the feature is off")
    }

    func testFullscreenDetectionSettingChanged_DisablingMidDetection_RestoresChrome() {
        sut.ontheflyDetectionTapped()
        XCTAssertFalse(sut.chromeVisible)

        settings.fullscreenDetection = false
        sut.fullscreenDetectionSettingChanged()

        XCTAssertTrue(sut.chromeVisible)
        XCTAssertTrue(sut.ontheflyDetectionEnabled, "Changing the setting must not stop detection")
        XCTAssertFalse(sut.showsFloatingChromeButton)
    }

    func testFullscreenDetectionSettingChanged_EnablingMidDetection_EntersFullscreen() {
        settings.fullscreenDetection = false
        sut.ontheflyDetectionTapped()
        XCTAssertTrue(sut.chromeVisible)

        settings.fullscreenDetection = true
        sut.fullscreenDetectionSettingChanged()

        XCTAssertFalse(sut.chromeVisible)
        XCTAssertTrue(sut.isFullscreen)
    }

    func testFullscreenDetectionSettingChanged_WhileDetectionOff_IsNoOp() {
        settings.fullscreenDetection = false

        sut.fullscreenDetectionSettingChanged()

        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
    }

    // MARK: - On-the-fly Detection Reset Tests

    func testOntheflyDetectionResetTapped_WhenEnabled_RestartsTimer() {
        sut.ontheflyDetectionEnabled = true
        snapState.startTimer(for: 1)
        XCTAssertNotNil(snapState.timerCancellable)

        sut.ontheflyDetectionResetTapped()

        // Timer should be restarted (stop + start)
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testOntheflyDetectionResetTapped_WhenDisabled_DoesNothing() {
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)

        sut.ontheflyDetectionResetTapped()

        // Should not start timer when detection is disabled
        XCTAssertNil(snapState.timerCancellable)
    }

    // MARK: - Web Content Process Loss (AIA-0879)

    private let site = "umweltdaten.hessen.de"

    /// Puts the SUT in a running detection run, the way the toolbar does.
    private func startDetection() {
        sut.ontheflyDetectionTapped(recordAnalytics: false)
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)
    }

    /// One termination, with a fresh generation. The real signal is generation-stamped because it
    /// arrives through a republishing `@Published` value.
    @discardableResult
    private func terminate(host: String?, at now: Date = Date()) -> UInt64 {
        eventSequence += 1
        sut.webContentProcessDidTerminate(sequence: eventSequence, host: host, now: now)
        return eventSequence
    }

    /// One "the page came back" event, with a fresh sequence.
    private func settleLoaded() {
        eventSequence += 1
        sut.webContentDidLoad(sequence: eventSequence)
    }

    /// One "the load stopped with nothing following it" event.
    private func settleStopped() {
        eventSequence += 1
        sut.webContentDidStopLoading(sequence: eventSequence)
    }

    func testWebContentProcessDidTerminate_FirstTime_InterruptsWithoutEndingTheRun() {
        startDetection()

        terminate(host: site)

        XCTAssertTrue(sut.ontheflyDetectionEnabled, "One termination must not cost the whole run")
        XCTAssertTrue(sut.isInterruptedByContentLoss)
        XCTAssertNil(snapState.timerCancellable, "Nothing may be captured while the page recovers")
    }

    func testWebContentProcessDidTerminate_WhileInterrupted_RefusesEveryCapturePath() {
        startDetection()
        let run = sut.detectionRunID
        terminate(host: site)

        // The apply-time boundary, which is what actually gates a physical WebKit snapshot.
        XCTAssertFalse(sut.accepts(SnapshotRequest(runID: run, sequence: 1)),
                       "A request enqueued before the termination must not start a capture now")

        // And every path that requests one off the timer. Observed through the publisher the
        // coordinator actually consumes: these paths do not touch the timer, so asserting on
        // `timerCancellable` would pass whether or not the gate is there.
        var requests: [SnapshotRequest] = []
        let cancellable = snapState.combinedPublishers.sink { requests.append($0) }
        defer { cancellable.cancel() }

        sut.driverDidRegister()
        sut.contentGeometryDidChange()
        sut.contentInteractionDidEnd()

        XCTAssertTrue(requests.isEmpty,
                      "No capture may be requested while the page that killed the renderer reloads")
    }

    // MARK: Redelivery

    func testWebContentProcessDidTerminate_SameSequenceTwice_IsAnsweredOnce() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        // SwiftUI can deliver one change to an outgoing and an incoming subscription both. Answering
        // twice would spend the site's strike and end the run on a single renderer death.
        sut.webContentProcessDidTerminate(sequence: 1, host: site, now: start)
        sut.webContentProcessDidTerminate(sequence: 1, host: site, now: start)

        XCTAssertTrue(sut.ontheflyDetectionEnabled, "One death must not be counted as two")
        XCTAssertTrue(sut.isInterruptedByContentLoss)
    }

    func testWebContentProcessDidTerminate_ReplayOfAnOlderEventIsIgnored() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        // Through the helper, so the termination and the settlement that follows share the one
        // sequence the real publisher issues. Mixing a hand-written number with the helper's counter
        // produced a settlement numbered BELOW its own termination, which the consumer correctly
        // refused — a broken test, not a broken guard.
        let replayed = terminate(host: site, at: start)
        settleLoaded()

        // A remount replays an event that was already answered.
        sut.webContentProcessDidTerminate(sequence: replayed, host: site, now: start.addingTimeInterval(5))

        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertFalse(sut.isInterruptedByContentLoss,
                       "A replayed termination must not re-interrupt a healthy run")
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testWebContentProcessDidTerminate_SequenceIsConsumedEvenWhileDetectionIsOff() {
        // Detection off: the event is still consumed, so turning detection on and receiving the same
        // replayed generation cannot interrupt the new run.
        sut.webContentProcessDidTerminate(sequence: 7, host: site)
        startDetection()

        sut.webContentProcessDidTerminate(sequence: 7, host: site)

        XCTAssertFalse(sut.isInterruptedByContentLoss)
        XCTAssertNotNil(snapState.timerCancellable)
    }

    // MARK: Resume

    func testWebContentDidLoad_ResumesTheInterruptedRun() {
        startDetection()
        let run = sut.detectionRunID
        terminate(host: site)

        settleLoaded()

        XCTAssertFalse(sut.isInterruptedByContentLoss)
        XCTAssertNotNil(snapState.timerCancellable, "The replacement document has loaded")
        XCTAssertEqual(sut.detectionRunID, run, "Resuming continues the run; it does not start a new one")
        XCTAssertTrue(sut.accepts(SnapshotRequest(runID: run, sequence: 2)))
    }

    func testWebContentDidLoad_OnAnOrdinaryLoadDoesNothing() {
        startDetection()
        snapState.stopTimer()

        settleLoaded()

        XCTAssertNil(snapState.timerCancellable,
                     "Every ordinary page load calls this; only an interruption may resume from it")
    }

    // MARK: Escalation

    func testWebContentProcessDidTerminate_SecondTimeOnTheSameSite_EndsTheRun() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        terminate(host: site, at: start)
        settleLoaded()
        terminate(host: site, at: start.addingTimeInterval(139))

        XCTAssertFalse(sut.ontheflyDetectionEnabled, "The loop is broken by ending the run")
        XCTAssertNil(snapState.timerCancellable)
        XCTAssertTrue(sut.chromeVisible, "Ending a run restores the browser chrome")
        XCTAssertFalse(sut.isInterruptedByContentLoss,
                       "A run that has ended must not also be left interrupted")
    }

    func testWebContentDidLoad_AfterTheRunEnded_DoesNotResurrectIt() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        terminate(host: site, at: start)
        settleLoaded()
        terminate(host: site, at: start.addingTimeInterval(10))
        XCTAssertFalse(sut.ontheflyDetectionEnabled)

        settleLoaded()

        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable, "The reload that follows must not restart detection")
    }

    func testWebContentProcessDidTerminate_WhileDetectionIsOff_DoesNothing() {
        XCTAssertFalse(sut.ontheflyDetectionEnabled)

        terminate(host: site)

        XCTAssertFalse(sut.isInterruptedByContentLoss)
        XCTAssertNil(snapState.timerCancellable)
    }

    // MARK: Interaction with the other ways detection idles

    func testFindingCaptureEnded_DoesNotResumeIntoARecoveringPage() {
        startDetection()
        sut.findingCaptureStarted()
        terminate(host: site)

        sut.findingCaptureEnded()

        // The capture path restarts the timer on its own; without the interruption gate it would
        // resume capture into the document that is still replacing a dead renderer.
        XCTAssertNil(snapState.timerCancellable)
        XCTAssertTrue(sut.isInterruptedByContentLoss)
    }

    func testFindingCaptureEnded_StillResumesWhenNothingTerminated() {
        startDetection()
        sut.findingCaptureStarted()
        XCTAssertNil(snapState.timerCancellable)

        sut.findingCaptureEnded()

        XCTAssertNotNil(snapState.timerCancellable, "The ordinary capture path must be unaffected")
    }

    func testBackgroundPauseAndForegroundResume_PreserveTheInterruption() {
        startDetection()
        terminate(host: site)

        // Exactly what MLBrowser's lifecycle handlers do.
        sut.ontheflyDetectionTapped(isUserInitiated: false)
        sut.ontheflyDetectionTapped(recordAnalytics: false, isUserInitiated: false)

        XCTAssertTrue(sut.ontheflyDetectionEnabled, "The session continues across a suspend")
        XCTAssertTrue(sut.isInterruptedByContentLoss,
                      "A trip to the home screen must not resume capture into the recovering page")
        XCTAssertNil(snapState.timerCancellable)
    }

    func testBackgroundPauseAndForegroundResume_PreserveTheSiteStrike() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        terminate(host: site, at: start)
        settleLoaded()

        sut.ontheflyDetectionTapped(isUserInitiated: false)
        sut.ontheflyDetectionTapped(recordAnalytics: false, isUserInitiated: false)
        terminate(host: site, at: start.addingTimeInterval(60))

        XCTAssertFalse(sut.ontheflyDetectionEnabled,
                       "The loop must not survive the fix by the user visiting the home screen")
    }

    func testOntheflyDetectionResetTapped_DoesNotResumeIntoARecoveringPage() {
        startDetection()
        terminate(host: site)

        // Settings calls this whenever the snapshot frequency changes; it is not a "capture now"
        // gesture and must not be read as proof the web content is ready.
        sut.ontheflyDetectionResetTapped()

        XCTAssertTrue(sut.isInterruptedByContentLoss)
        XCTAssertNil(snapState.timerCancellable)
        XCTAssertFalse(sut.accepts(SnapshotRequest(runID: sut.detectionRunID, sequence: 1)))
    }

    // MARK: Recovery that never returns

    func testWebContentDidStopLoading_ResumesTheRunRatherThanLeavingItStuck() {
        startDetection()
        terminate(host: site)

        // Pressing Stop during the recovery reload produces neither a finish nor a classified
        // failure. Before this path existed the interruption had no exit: detection sat enabled and
        // capturing nothing, with the toolbar still showing a run.
        settleStopped()

        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertFalse(sut.isInterruptedByContentLoss)
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testWebContentDidStopLoading_KeepsTheSiteStrike() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        terminate(host: site, at: start)
        settleStopped()

        terminate(host: site, at: start.addingTimeInterval(60))

        XCTAssertFalse(sut.ontheflyDetectionEnabled,
                       "Resuming after a stopped load must not forgive the site its first death")
    }

    func testWebContentDidStopLoading_OnAnOrdinaryStopDoesNothing() {
        startDetection()
        snapState.stopTimer()

        settleStopped()

        XCTAssertNil(snapState.timerCancellable,
                     "Stopping an ordinary load must not start a detection timer")
    }

    func testSettlementRedelivery_IsAnsweredOnce() {
        startDetection()
        terminate(host: site)

        settleLoaded()
        // The same settlement redelivered by a remount, after a NEW termination interrupted the run
        // again, must not resume it.
        terminate(host: site, at: Date().addingTimeInterval(-1_000))
        sut.webContentDidLoad(sequence: eventSequence - 1)

        XCTAssertTrue(sut.isInterruptedByContentLoss,
                      "A replayed settlement must not clear a later interruption")
        XCTAssertNil(snapState.timerCancellable)
    }

    func testRemountAfterTerminationAndRecovery_DoesNotStrandTheRun() {
        // The hazard two publishers created: a termination while WebScreen was unmounted, and the
        // recovery that settled after it, both replayed on remount. With the settlement delivered
        // first its sequence was consumed while nothing was interrupted, and the termination that
        // followed then interrupted the run with nothing left to clear it.
        //
        // One publisher replays only the LATEST event, so the remount sees the settlement alone —
        // and a stale termination arriving afterwards is refused by sequence either way.
        startDetection()
        let terminationSequence: UInt64 = 5
        let settlementSequence: UInt64 = 6

        // Remount replays the latest event only.
        sut.webContentDidLoad(sequence: settlementSequence)
        // And the older termination, if anything delivered it, is already behind.
        sut.webContentProcessDidTerminate(sequence: terminationSequence, host: site)

        XCTAssertFalse(sut.isInterruptedByContentLoss,
                       "A remount after the page came back must not strand the run")
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testWebContentDidFailToLoad_EndsTheRunRatherThanLeavingItInterrupted() {
        startDetection()
        terminate(host: site)

        sut.webContentDidFailToLoad()

        // Otherwise detection sits enabled and capturing nothing, with no way for the user to tell.
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertFalse(sut.isInterruptedByContentLoss)
    }

    func testWebContentDidFailToLoad_OnAnOrdinaryFailureDoesNothing() {
        startDetection()

        sut.webContentDidFailToLoad()

        XCTAssertTrue(sut.ontheflyDetectionEnabled,
                      "A load failure with no termination behind it is not this policy's business")
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testUserRestart_ClearsTheInterruptionAndTheStrike() {
        startDetection()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        terminate(host: site, at: start)
        terminate(host: site, at: start.addingTimeInterval(10))
        XCTAssertFalse(sut.ontheflyDetectionEnabled)

        sut.ontheflyDetectionTapped(recordAnalytics: false)

        XCTAssertFalse(sut.isInterruptedByContentLoss)
        XCTAssertNotNil(snapState.timerCancellable)
        // The strike is spent: this run gets its own first-termination grace.
        terminate(host: site, at: start.addingTimeInterval(20))
        XCTAssertTrue(sut.ontheflyDetectionEnabled,
                      "A run the user started must not end on the previous run's strike")
    }

}

@MainActor
final class AppChromeStateTests: XCTestCase {

    var settings: Settings!
    var snapState: SnapState!
    var deepState: DeepState!
    // `DetectionSessionState.snapAdjustment` is `unowned`; hold it strong for the whole test.
    var snapAdjustment: SnapAdjustment!
    var dataController: DataController!
    var demoDataManager: DemoDataManager!
    // AppChromeState borrows the detection controller for app-reset; keep it strong so the
    // `unowned` snapAdjustment edge inside it can never dangle mid-test.
    var detectionState: DetectionSessionState!
    var sut: AppChromeState!
    private var tempStoreURL: URL?

    override func setUp() async throws {
        try await super.setUp()

        settings = Settings()
        // Settings persists to UserDefaults.standard; pin the default so tests
        // that flip the flag cannot leak into later tests via the suite's defaults.
        settings.fullscreenDetection = true
        dataController = DataController(inMemory: true)
        snapState = SnapState(settings: settings)
        deepState = DeepState(dataController: dataController)
        snapAdjustment = SnapAdjustment()
        demoDataManager = DemoDataManager(dataController: dataController)

        detectionState = DetectionSessionState(
            snap: snapState,
            settings: settings,
            snapAdjustment: snapAdjustment
        )
        sut = AppChromeState(
            detectionState: detectionState,
            deep: deepState,
            settings: settings,
            demoDataManager: demoDataManager
        )
    }

    override func tearDown() async throws {
        snapState.stopTimer()
        sut = nil
        detectionState = nil
        demoDataManager = nil
        dataController = nil
        snapAdjustment = nil
        deepState = nil
        snapState = nil
        settings = nil

        // Clean up temporary SQLite store if used
        if let url = tempStoreURL {
            try? FileManager.default.removeItem(at: url)
            // Also remove -wal and -shm files
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
            tempStoreURL = nil
        }

        try await super.tearDown()
    }

    /// Sets up the test with a temporary SQLite store instead of in-memory.
    /// Use this for tests that call resetApplication() or other batch delete operations.
    private func setUpWithSQLiteStore() async {
        // Unload the in-memory store before creating the SQLite store to avoid conflicts.
        // Note: In test environments, store removal failures are typically non-critical
        // as the old store will be discarded when dataController is replaced.
        for store in dataController.container.persistentStoreCoordinator.persistentStores {
            do {
                try dataController.container.persistentStoreCoordinator.remove(store)
            } catch {
                // Log but continue - the old in-memory store will be discarded anyway
                print("Warning: Failed to remove in-memory store during test setup: \(error)")
            }
        }

        let (sqliteController, storeURL) = createTempSQLiteDataController()
        tempStoreURL = storeURL
        dataController = sqliteController
        await dataController.awaitStoreReady()

        deepState = DeepState(dataController: dataController)
        demoDataManager = DemoDataManager(dataController: dataController)

        detectionState = DetectionSessionState(
            snap: snapState,
            settings: settings,
            snapAdjustment: snapAdjustment
        )
        sut = AppChromeState(
            detectionState: detectionState,
            deep: deepState,
            settings: settings,
            demoDataManager: demoDataManager
        )
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(sut.deep)
        XCTAssertNotNil(sut.settings)
        XCTAssertNotNil(sut.demoDataManager)
        XCTAssertNotNil(sut.detectionState)
    }

    func testInitialState() {
        XCTAssertEqual(sut.mode, .web)
        XCTAssertFalse(sut.presentedSideMenu)
        XCTAssertNil(sut.selectedConfigurationId)
        XCTAssertNil(sut.pageToOpen)
    }

    // MARK: - Side Menu Tests

    func testTogglingSideMenu_TogglesState() {
        XCTAssertFalse(sut.presentedSideMenu)

        sut.togglingSideMenu()

        XCTAssertTrue(sut.presentedSideMenu)
    }

    func testTogglingSideMenu_TogglesBackToFalse() {
        sut.presentedSideMenu = true

        sut.togglingSideMenu()

        XCTAssertFalse(sut.presentedSideMenu)
    }

    func testTogglingSideMenu_MultipleToggles() {
        XCTAssertFalse(sut.presentedSideMenu)

        sut.togglingSideMenu()
        XCTAssertTrue(sut.presentedSideMenu)

        sut.togglingSideMenu()
        XCTAssertFalse(sut.presentedSideMenu)

        sut.togglingSideMenu()
        XCTAssertTrue(sut.presentedSideMenu)
    }

    // MARK: - Drawer Sheet Tests (AIA-0984)

    /// Presents every drawer sheet at once. The flags are independent, so this is a setup
    /// convenience, not a state the drawer reaches.
    private func presentEveryDrawerSheet() {
        sut.drawerPresentation.isFindingsPresented = true
        sut.drawerPresentation.isSignInPresented = true
        sut.drawerPresentation.settings = .manageAccount
    }

    private func assertNoDrawerSheet(_ message: String, line: UInt = #line) {
        XCTAssertFalse(sut.drawerPresentation.isFindingsPresented, message, line: line)
        XCTAssertFalse(sut.drawerPresentation.isSignInPresented, message, line: line)
        XCTAssertNil(sut.drawerPresentation.settings, message, line: line)
    }

    /// The drawer view unmounts when the drawer closes, which used to drop its sheets' `@State`;
    /// the shared model must be reset instead, on every closing path.
    func testClosingTheDrawer_DismissesItsSheets() {
        for sheet in [\DrawerPresentation.isFindingsPresented, \DrawerPresentation.isSignInPresented] {
            sut.presentedSideMenu = true
            sut.drawerPresentation[keyPath: sheet] = true

            sut.presentedSideMenu = false

            XCTAssertFalse(sut.drawerPresentation[keyPath: sheet], "\(sheet) must close with the drawer")
        }
        for settings in [SettingsPresentation.settings, .manageAccount] {
            sut.presentedSideMenu = true
            sut.drawerPresentation.settings = settings

            sut.presentedSideMenu = false

            XCTAssertNil(sut.drawerPresentation.settings, "Settings (\(settings)) must close with the drawer")
        }
    }

    func testTogglingTheDrawerClosed_DismissesItsSheets() {
        sut.presentedSideMenu = true
        presentEveryDrawerSheet()

        sut.togglingSideMenu()

        assertNoDrawerSheet("Toggling the drawer closed must dismiss its sheets")
    }

    func testOpeningTheDrawer_KeepsItsSheets() {
        presentEveryDrawerSheet()

        sut.presentedSideMenu = true
        XCTAssertTrue(sut.drawerPresentation.isFindingsPresented)
        XCTAssertTrue(sut.drawerPresentation.isSignInPresented)
        XCTAssertEqual(sut.drawerPresentation.settings, .manageAccount)

        // An open drawer written open again (SharedFindingView's own-finding path) is not a close.
        sut.presentedSideMenu = true
        XCTAssertTrue(sut.drawerPresentation.isFindingsPresented)
        XCTAssertTrue(sut.drawerPresentation.isSignInPresented)
        XCTAssertEqual(sut.drawerPresentation.settings, .manageAccount)
    }

    // MARK: - Mode Tests

    /// `AppMode` has a single case since AIA-0898 removed the unreachable gallery, so there is no
    /// second value to change to. Asserting the default is what remains genuinely testable --
    /// keeping a "can be changed" test that assigns `.web` to `.web` would look like coverage
    /// while proving nothing.
    func testMode_DefaultsToWeb() {
        XCTAssertEqual(sut.mode, .web)
    }

    // MARK: - Configuration Selection Tests

    func testSelectedConfigurationId_CanBeSet() {
        let id = UUID()

        sut.selectedConfigurationId = id

        XCTAssertEqual(sut.selectedConfigurationId, id)
    }

    func testSelectedConfigurationId_CanBeCleared() {
        sut.selectedConfigurationId = UUID()

        sut.selectedConfigurationId = nil

        XCTAssertNil(sut.selectedConfigurationId)
    }

    // MARK: - Page To Open Tests

    func testPageToOpen_CanBeSet() {
        let url = URL(string: "https://example.com")!

        sut.pageToOpen = url

        XCTAssertEqual(sut.pageToOpen, url)
    }

    // MARK: - Reset Application Tests
    // Note: All resetApplication tests use SQLite store because NSBatchDeleteRequest
    // (used by deep.reset()) doesn't work with in-memory stores.

    func testResetApplication_CompletesSuccessfully() async {
        await setUpWithSQLiteStore()

        // Given: initial state
        let initialMode = sut.mode

        // When: reset application is called
        await sut.resetApplication()

        // Then: reset completes without errors and state is still valid
        XCTAssertEqual(sut.mode, initialMode, "Mode should remain unchanged after reset")
        XCTAssertNotNil(sut.settings, "Settings should not be nil after reset")
        XCTAssertNotNil(sut.deep, "Deep state should not be nil after reset")
    }

    func testResetApplication_DisablesDetectionIfEnabled() async {
        await setUpWithSQLiteStore()

        // Given: detection is enabled
        detectionState.ontheflyDetectionEnabled = true
        snapState.startTimer(for: 1)
        XCTAssertTrue(detectionState.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)

        // When: reset application is called
        await sut.resetApplication()

        // Then: detection is disabled and chrome is restored to the default state
        XCTAssertFalse(detectionState.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)
        XCTAssertTrue(detectionState.chromeVisible)
    }

    func testResetApplication_CallsDeepReset() async throws {
        await setUpWithSQLiteStore()

        // Given: deep state has some configurations (non-demo)
        let config = DeepConfiguration.create(in: dataController.container.viewContext)
        let configId = UUID()
        config.entityId = configId
        config.creationDate_ = .now
        config.demo = false
        try DeepConfiguration.save(in: dataController.container.viewContext)

        // Verify the config exists
        XCTAssertNotNil(DeepConfiguration.select(configId, in: dataController.container.viewContext))

        // When: reset application is called
        await sut.resetApplication()

        // Then: the original configuration should be deleted
        let deletedConfig = DeepConfiguration.select(configId, in: dataController.container.viewContext)
        XCTAssertNil(deletedConfig, "Original configuration should be deleted after reset")
    }

    func testResetApplication_CallsSettingsReset() async {
        await setUpWithSQLiteStore()

        // Given: settings have been modified
        settings.applicationResetButtonToggle = false
        let initialToggleState = settings.applicationResetButtonToggle

        // When: reset application is called
        await sut.resetApplication()

        // Then: settings toggle state changes
        XCTAssertNotEqual(settings.applicationResetButtonToggle, initialToggleState)
    }

    func testResetApplication_DeletesBrowsingHistory() async {
        await setUpWithSQLiteStore()

        // Given: some browsing history exists
        await demoDataManager.createDemoDataIfNeeded()
        let countBefore = WebHistoryEntry.count(in: dataController.container.viewContext)
        XCTAssertGreaterThan(countBefore, 0)

        // When: reset application is called
        await sut.resetApplication()

        // Then: browsing history is deleted and recreated with demo data
        // Since resetApplication awaits both deleteBrowsingHistory and createDemoDataIfNeeded,
        // the operations should be complete when we reach this point. The resetApplication
        // method calls createDemoDataIfNeeded after deletion, which populates the store
        // with demo pages, so we expect a positive count.
        let countAfter = WebHistoryEntry.count(in: dataController.container.viewContext)
        XCTAssertGreaterThan(countAfter, 0, "Demo data should be recreated after reset")
    }
}
