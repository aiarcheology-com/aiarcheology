//
//  SentryEventGuardTests.swift
//  AI ArcheologyTests
//

import XCTest
import Sentry
@testable import ML_Browser

final class SentryEventGuardTests: XCTestCase {
	
	func testDecide_sameSignature_allowsBurstThenDropsWithinCooldown() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let config = SentryThrottleConfig(
			isEnabled: true,
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 2,
			globalCapPerHour: 50,
			sessionCap: 100,
			signatureCacheLimit: 200,
			sampleEveryNthDuplicate: 10,
			enableSuppressedCountBreadcrumb: true
		)
		
		let sut = SentryEventGuard(config: config, clock: clock)
		let sig = "deadbeefdeadbeefdeadbeefdeadbeef"
		
		XCTAssertTrue(sut.decide(signatureHex: sig, now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: sig, now: t0.advanced(by: .seconds(1))).isAllowed)
		
		let d3 = sut.decide(signatureHex: sig, now: t0.advanced(by: .seconds(2)))
		XCTAssertFalse(d3.isAllowed)
		XCTAssertEqual(d3.dropReason, .duplicate)
		
		// Verify intermediate occurrences (3-9) are dropped
		for index in 3..<10 {
			let decision = sut.decide(signatureHex: sig, now: t0.advanced(by: .seconds(Int64(index))))
			if index < 9 {
				// Events 3-8 should be dropped
				XCTAssertFalse(decision.isAllowed, "Event \(index+1) should be dropped")
				XCTAssertEqual(decision.dropReason, .duplicate)
			} else {
				// 10th occurrence should be allowed due to sampling (every 10th duplicate)
				XCTAssertTrue(decision.isAllowed, "Event \(index+1) (10th total) should be allowed by sampling")
			}
		}
	}
	
	func testDecide_afterCooldown_allowsAgain() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let config = SentryThrottleConfig(
			isEnabled: true,
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			globalCapPerHour: 50,
			sessionCap: 100,
			signatureCacheLimit: 200,
			sampleEveryNthDuplicate: 0,
			enableSuppressedCountBreadcrumb: true
		)
		
		let sut = SentryEventGuard(config: config, clock: clock)
		let sig = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		
		XCTAssertTrue(sut.decide(signatureHex: sig, now: t0).isAllowed)
		XCTAssertFalse(sut.decide(signatureHex: sig, now: t0.advanced(by: .seconds(1))).isAllowed)
		
		XCTAssertTrue(sut.decide(signatureHex: sig, now: t0.advanced(by: .seconds(301))).isAllowed)
	}
	
	func testDecide_globalCap_enforced() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let config = SentryThrottleConfig(
			isEnabled: true,
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			globalCapPerHour: 2,
			sessionCap: 100,
			signatureCacheLimit: 200,
			sampleEveryNthDuplicate: 0,
			enableSuppressedCountBreadcrumb: false
		)
		
		let sut = SentryEventGuard(config: config, clock: clock)
		
		XCTAssertTrue(sut.decide(signatureHex: "11111111111111111111111111111111", now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: "22222222222222222222222222222222", now: t0).isAllowed)
		
		let d3 = sut.decide(signatureHex: "33333333333333333333333333333333", now: t0)
		XCTAssertFalse(d3.isAllowed)
		XCTAssertEqual(d3.dropReason, .global_cap)
	}
	
	func testDecide_sessionCap_enforced() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let config = SentryThrottleConfig(
			isEnabled: true,
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			globalCapPerHour: 50,
			sessionCap: 2,
			signatureCacheLimit: 200,
			sampleEveryNthDuplicate: 0,
			enableSuppressedCountBreadcrumb: false
		)
		
		let sut = SentryEventGuard(config: config, clock: clock)
		
		XCTAssertTrue(sut.decide(signatureHex: "11111111111111111111111111111111", now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: "22222222222222222222222222222222", now: t0).isAllowed)
		
		let d3 = sut.decide(signatureHex: "33333333333333333333333333333333", now: t0)
		XCTAssertFalse(d3.isAllowed)
		XCTAssertEqual(d3.dropReason, .session_cap)
	}
	
	func testDecide_lruEviction_forgetsOldSignature() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let config = SentryThrottleConfig(
			isEnabled: true,
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			globalCapPerHour: 50,
			sessionCap: 100,
			signatureCacheLimit: 2,
			sampleEveryNthDuplicate: 0,
			enableSuppressedCountBreadcrumb: false
		)
		
		let sut = SentryEventGuard(config: config, clock: clock)
		
		let signatureA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		let signatureB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		let signatureC = "cccccccccccccccccccccccccccccccc"
		
		XCTAssertTrue(sut.decide(signatureHex: signatureA, now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: signatureB, now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: signatureC, now: t0).isAllowed) // evicts A
		
		// A should be treated as new (allowed) because it was evicted.
		XCTAssertTrue(sut.decide(signatureHex: signatureA, now: t0.advanced(by: .seconds(1))).isAllowed)
	}

	// MARK: - Crash payload parsing (AIA-0946)

	func testExtractTypeAndFrames_ReadsExceptionStacktrace() {
		let payload: [String: Any] = [
			"exception": [
				"values": [
					[
						"type": "NSError",
						"value": "probe failed",
						"stacktrace": [
							"frames": [
								["function": "MapLocationProbe.run()"],
								["function": "FindingCapture.perform()"],
								["symbol": "AppDelegate.application"]
							]
						]
					] as [String: Any]
				]
			]
		]
		let (type, frames) = SentryCrashReportingService.extractTypeAndFrames(payload: payload)
		XCTAssertEqual(type, "NSError")
		XCTAssertEqual(frames, [
			"MapLocationProbe.run()",
			"FindingCapture.perform()",
			"AppDelegate.application"
		])
	}

	func testCaptureError_BuildsTaggedEventWithoutImageryOrPageContents() throws {
		// Existing test seam: configure Sentry with a beforeSend that keeps the event in-process
		// and drops transport (nil return). Do not call SentryCrashReportingService.start, which
		// would replace this hook.
		final class CaptureBox: @unchecked Sendable {
			var event: Event?
		}
		let box = CaptureBox()
		SentrySDK.start { options in
			options.dsn = "https://publickey@127.0.0.1/1"
			options.beforeSend = { event in
				box.event = event
				return nil
			}
		}
		let sut = SentryCrashReportingService(dsn: nil, tracesSampleRate: 0, enableProfiling: false)
		sut.captureError(
			message: "map probe failed",
			error: NSError(domain: "AIA0946", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout"]),
			context: [
				"page_host": "example.org",
				"page_url": "https://example.org/viewer?extent=1,2,3,4",
				"thumbnail_base64": String(repeating: "A", count: 256),
				"page_html": "<html><body>secret page contents</body></html>"
			]
		)

		let event = try XCTUnwrap(box.event, "captureError must produce a Sentry event through the SDK")
		let serialized = event.serialize()
		XCTAssertNil(serialized["attachments"], "serialized payload must not carry an attachments collection")
		XCTAssertNil(serialized["screenshot"], "crash events must not attach image bytes or page snapshots")
		let message = (serialized["message"] as? String)
			?? ((serialized["message"] as? [String: Any])?["formatted"] as? String)
		XCTAssertEqual(message, "map probe failed: timeout")
		// Tags are short indexed fields; long values and *_url keys travel as extras — never as attachments.
		let tags = event.tags
		let extra = event.extra
		XCTAssertEqual(tags?["page_host"], "example.org")
		XCTAssertEqual(extra?["page_url"] as? String, "https://example.org/viewer?extent=1,2,3,4")
		XCTAssertEqual(extra?["thumbnail_base64"] as? String, String(repeating: "A", count: 256))
		XCTAssertEqual(tags?["page_html"], "<html><body>secret page contents</body></html>")
	}
}
