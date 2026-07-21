//
//  SentryBreadcrumbGuardTests.swift
//  AI ArcheologyTests
//

import XCTest
@testable import ML_Browser

final class SentryBreadcrumbGuardTests: XCTestCase {
	
	func testShouldAllow_allowsBurstThenDropsWithinCooldown() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let sut = SentryBreadcrumbGuard(
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 2,
			sampleEveryNthDuplicate: 0,
			signatureCacheLimit: 200,
			clock: clock
		)
		
		let sig = "aaabbbcccdddeeefff000111222333444"
		
		// First two should be allowed (burst = 2)
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0))
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(1))))
		
		// Third should be dropped (burst exceeded)
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(2))))
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(3))))
	}
	
	func testShouldAllow_afterCooldown_resetsWindow() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let sut = SentryBreadcrumbGuard(
			perSignatureCooldown: .seconds(60),
			perSignatureBurst: 1,
			sampleEveryNthDuplicate: 0,
			signatureCacheLimit: 200,
			clock: clock
		)
		
		let sig = "testSignature"
		
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0))
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(30))))
		
		// After cooldown, should allow again
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(61))))
	}
	
	func testShouldAllow_samplingEveryNth_allowsNthDuplicate() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let sut = SentryBreadcrumbGuard(
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			sampleEveryNthDuplicate: 5,
			signatureCacheLimit: 200,
			clock: clock
		)
		
		let sig = "samplingTest"
		
		// First is allowed (burst = 1)
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0))
		
		// 2-4 should be dropped
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(1))))
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(2))))
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(3))))
		
		// 5th should be allowed (sampling every 5th)
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(4))))
		
		// 6-9 should be dropped
		for index in 5..<9 {
			XCTAssertFalse(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(Int64(index)))))
		}
		
		// 10th should be allowed
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig, now: t0.advanced(by: .seconds(9))))
	}
	
	func testShouldAllow_differentSignatures_independentLimits() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let sut = SentryBreadcrumbGuard(
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			sampleEveryNthDuplicate: 0,
			signatureCacheLimit: 200,
			clock: clock
		)
		
		let sig1 = "signature1"
		let sig2 = "signature2"
		
		// Both signatures should independently allow their first occurrence
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig1, now: t0))
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig2, now: t0))
		
		// Both should drop their second occurrence
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig1, now: t0.advanced(by: .seconds(1))))
		XCTAssertFalse(sut.shouldAllow(signatureHex: sig2, now: t0.advanced(by: .seconds(1))))
	}
	
	func testShouldAllow_lruEviction_forgetsOldSignature() {
		let clock = ContinuousClock()
		let t0 = clock.now
		
		let sut = SentryBreadcrumbGuard(
			perSignatureCooldown: .seconds(300),
			perSignatureBurst: 1,
			sampleEveryNthDuplicate: 0,
			signatureCacheLimit: 2,
			clock: clock
		)
		
		let sig1 = "sig1"
		let sig2 = "sig2"
		let sig3 = "sig3"
		
		// Fill cache with sig1 and sig2
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig1, now: t0))
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig2, now: t0))
		
		// Add sig3, which should evict sig1 (LRU)
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig3, now: t0))
		
		// sig1 should be treated as new (allowed) because it was evicted
		XCTAssertTrue(sut.shouldAllow(signatureHex: sig1, now: t0.advanced(by: .seconds(1))))
	}
}
