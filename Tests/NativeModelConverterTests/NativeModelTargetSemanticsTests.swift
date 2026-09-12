//
//  NativeModelTargetSemanticsTests.swift
//  NativeModelConverterTests
//

import XCTest
@testable import NativeModelConverter

final class NativeModelTargetSemanticsTests: XCTestCase {

	func testResolved_imageNet1KWithWrongClassCount_returnsNil() {
		let intent = NativeModelTargetSemanticsIntent(labelProfile: .imageNet1K, preprocessingProfile: .imageNetRGB)

		XCTAssertNil(intent.resolved(task: .classification, classCount: 999, imagePreprocessingWasApplied: true))
	}

	func testResolved_pascalVOCWithWrongClassCount_returnsNil() {
		let intent = NativeModelTargetSemanticsIntent(labelProfile: .pascalVOC, preprocessingProfile: .rgbZeroToOne)

		XCTAssertNil(intent.resolved(task: .detection, classCount: 21, imagePreprocessingWasApplied: true))
	}

	func testResolved_imageNet1KWithMatchingClassCount_returnsSemantics() {
		let intent = NativeModelTargetSemanticsIntent(labelProfile: .imageNet1K, preprocessingProfile: .imageNetRGB)

		let semantics = intent.resolved(task: .classification, classCount: 1000, imagePreprocessingWasApplied: true)

		XCTAssertEqual(
			semantics,
			NativeModelTargetSemantics(
				task: .classification,
				classCount: 1000,
				labelProfile: .imageNet1K,
				preprocessingProfile: .imageNetRGB
			)
		)
	}
}
