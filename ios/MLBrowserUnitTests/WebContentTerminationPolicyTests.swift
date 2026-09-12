//
//  WebContentTerminationPolicyTests.swift
//  MLBrowserUnitTests
//
//  AIA-0879: the escalation that decides whether a dead web content process interrupts a detection
//  run or ends it.
//
//  The policy takes `now` as a parameter rather than reading a clock, so the window is exercised
//  with date arithmetic — this suite never waits on real time.
//

import XCTest
@testable import ML_Browser

final class WebContentTerminationPolicyTests: XCTestCase {

	private let now = Date(timeIntervalSinceReferenceDate: 0)
	private let host = "umweltdaten.hessen.de"

	// MARK: - The strike

	func testResponse_FirstTerminationOnASiteInterrupts() {
		var sut = WebContentTerminationPolicy()

		XCTAssertEqual(sut.response(host: host, now: now), .interrupt,
					   "A renderer can die once for reasons that are not the page's fault")
	}

	func testResponse_SecondTerminationOnTheSameSiteInsideTheWindowEndsTheRun() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)

		let second = sut.response(host: host, now: now.addingTimeInterval(139))

		// 139s is the first real gap measured on the reported device (13:42:00 -> 13:44:19).
		XCTAssertEqual(second, .endRun, "Twice on one site inside the window is the loop")
	}

	func testResponse_SecondTerminationOutsideTheWindowOnlyInterrupts() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)

		let second = sut.response(
			host: host,
			now: now.addingTimeInterval(WebContentTerminationPolicy.defaultRepeatWindow)
		)

		XCTAssertEqual(second, .interrupt, "Far enough apart is two incidents, not a loop")
	}

	func testResponse_AnInterleavedSiteDoesNotEraseAnotherSitesStrike() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)
		// Remembering only the most recent site lost the strike that mattered here: B would overwrite
		// A's record, so A's repeat read as a first offence and the loop carried on. An iframed portal
		// is routinely two hosts, so this interleaving is not exotic.
		_ = sut.response(host: "zbgis.skgeodesy.sk", now: now.addingTimeInterval(30))

		let repeatOnA = sut.response(host: host, now: now.addingTimeInterval(60))

		XCTAssertEqual(repeatOnA, .endRun)
	}

	func testResponse_StrikesExpirePerSite() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)
		let window = WebContentTerminationPolicy.defaultRepeatWindow

		// A's strike has expired; B's is fresh. The two must not share a fate.
		_ = sut.response(host: "zbgis.skgeodesy.sk", now: now.addingTimeInterval(window + 1))

		XCTAssertEqual(sut.response(host: host, now: now.addingTimeInterval(window + 2)), .interrupt)
		XCTAssertEqual(sut.response(host: "zbgis.skgeodesy.sk", now: now.addingTimeInterval(window + 3)), .endRun)
	}

	func testResponse_TerminationsOnDifferentSitesDoNotCompound() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)

		let other = sut.response(host: "zbgis.skgeodesy.sk", now: now.addingTimeInterval(10))

		XCTAssertEqual(other, .interrupt,
					   "Two sites failing once each must not end a run between them")
	}

	func testResponse_HostIsMatchedCaseInsensitively() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: "Umweltdaten.Hessen.DE", now: now)

		let second = sut.response(host: host, now: now.addingTimeInterval(10))

		XCTAssertEqual(second, .endRun, "Host case must not buy a site a second strike")
	}

	// MARK: - Sites that cannot be keyed

	func testResponse_NilHostAlwaysInterrupts() {
		var sut = WebContentTerminationPolicy()

		XCTAssertEqual(sut.response(host: nil, now: now), .interrupt)
		XCTAssertEqual(sut.response(host: nil, now: now.addingTimeInterval(1)), .interrupt,
					   "An unattributable termination cannot be shown to have repeated")
	}

	func testResponse_EmptyHostIsTreatedAsNoHost() {
		var sut = WebContentTerminationPolicy()

		XCTAssertEqual(sut.response(host: "", now: now), .interrupt)
		XCTAssertEqual(sut.response(host: "", now: now.addingTimeInterval(1)), .interrupt)
	}

	func testResponse_NilHostDoesNotArmTheEscalationForARealSite() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: nil, now: now)

		let real = sut.response(host: host, now: now.addingTimeInterval(1))

		XCTAssertEqual(real, .interrupt, "A host-less termination must not spend a real site's strike")
	}

	// MARK: - After the run ends

	func testResponse_StrikeIsClearedOnceTheRunEnds() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)
		XCTAssertEqual(sut.response(host: host, now: now.addingTimeInterval(10)), .endRun)

		let afterRestart = sut.response(host: host, now: now.addingTimeInterval(20))

		XCTAssertEqual(afterRestart, .interrupt,
					   "A restarted run must not end instantly on the previous run's strike")
	}

	// MARK: - Clock

	func testResponse_ClockMovedBackwardsDoesNotEndTheRun() {
		var sut = WebContentTerminationPolicy()
		_ = sut.response(host: host, now: now)

		let backwards = sut.response(host: host, now: now.addingTimeInterval(-60))

		// A bare `elapsed < window` test reads a negative interval as "close together" and ends the
		// run on what is really one termination.
		XCTAssertEqual(backwards, .interrupt, "A backwards clock step must not be read as a repeat")
	}

	// MARK: - Window

	func testDefaultRepeatWindow_IsTenMinutes() {
		// Pinned, not merely bounded: an earlier version asserted only "greater than the observed
		// gaps", which any large number satisfies and which would not have noticed the window
		// silently growing to an hour (raised in review).
		XCTAssertEqual(WebContentTerminationPolicy.defaultRepeatWindow, 600)
		// And the reason it is that: the gaps measured on the reported device were 139s, 257s and
		// 444s, so `WebContentRecoveryPolicy.defaultWindow` (60s) would never have fired on any of
		// them and this type would have been dead code.
		XCTAssertGreaterThan(WebContentTerminationPolicy.defaultRepeatWindow, 444)
	}

	func testResponse_HonoursAnInjectedWindow() {
		var sut = WebContentTerminationPolicy(repeatWindow: 30)
		_ = sut.response(host: host, now: now)

		XCTAssertEqual(sut.response(host: host, now: now.addingTimeInterval(29)), .endRun)
	}
}
