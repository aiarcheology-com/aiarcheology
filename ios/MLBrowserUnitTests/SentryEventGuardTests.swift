//
//  SentryEventGuardTests.swift
//  AI ArcheologyTests
//

import XCTest
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
		
		// 10th occurrence should be allowed due to sampling (every 10th duplicate)
		var last: SentryEventGuardDecision = d3
		for i in 3..<10 {
			last = sut.decide(signatureHex: sig, now: t0.advanced(by: .seconds(Int64(i))))
		}
		XCTAssertTrue(last.isAllowed)
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
		
		let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		let c = "cccccccccccccccccccccccccccccccc"
		
		XCTAssertTrue(sut.decide(signatureHex: a, now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: b, now: t0).isAllowed)
		XCTAssertTrue(sut.decide(signatureHex: c, now: t0).isAllowed) // evicts A
		
		// A should be treated as new (allowed) because it was evicted.
		XCTAssertTrue(sut.decide(signatureHex: a, now: t0.advanced(by: .seconds(1))).isAllowed)
	}
}


