//
//  NativeModelImageSizingContractTests.swift
//  NativeModelConverterTests
//

import XCTest
@testable import NativeModelConverter

final class NativeModelImageSizingContractTests: XCTestCase {

	func testADAFContract_hasAPinnedCompleteWireForm() throws {
		let contract = NativeModelImageSizingContract.adafFasterRCNN
		XCTAssertEqual(contract.minSize, 800)
		XCTAssertEqual(contract.maxSize, 1_333)
		XCTAssertEqual(contract.canvas, NativeModelImageSize(width: 1_344, height: 1_344))
		XCTAssertEqual(contract.contentPlacement, .topLeft)
		XCTAssertEqual(contract.paddingFill, .normalizedZero)
		XCTAssertEqual(
			try contract.canonicalJSON(),
			#"{"canvasHeight":1344,"canvasWidth":1344,"contentPlacement":"top-left","format":"com.aiarcheology.native-model-image-sizing","formatVersion":1,"maxSize":1333,"minSize":800,"paddingFill":"normalized-zero","transformProfile":"torchvision-generalized-rcnn-v1"}"#
		)
	}

	func testConsumer_acceptsOnlyTheCompleteSupportedContract() throws {
		let json = try NativeModelImageSizingContract.adafFasterRCNN.canonicalJSON()
		let accepted = NativeModelImageSizingContract(userDefined: [
			NativeModelImageSizingContract.userDefinedKey: json
		])
		XCTAssertEqual(accepted, .adafFasterRCNN)

		let unsupportedVersion = #"{"canvasHeight":1344,"canvasWidth":1344,"contentPlacement":"top-left","format":"com.aiarcheology.native-model-image-sizing","formatVersion":2,"maxSize":1333,"minSize":800,"paddingFill":"normalized-zero","transformProfile":"torchvision-generalized-rcnn-v1"}"#
		XCTAssertNil(NativeModelImageSizingContract(userDefined: [
			NativeModelImageSizingContract.userDefinedKey: unsupportedVersion
		]))

		let incomplete = #"{"canvasHeight":1344,"canvasWidth":1344,"contentPlacement":"top-left","format":"com.aiarcheology.native-model-image-sizing","formatVersion":1,"maxSize":1333,"minSize":800,"transformProfile":"torchvision-generalized-rcnn-v1"}"#
		XCTAssertNil(NativeModelImageSizingContract(userDefined: [
			NativeModelImageSizingContract.userDefinedKey: incomplete
		]))

		let canvasTooSmallForTheDeclaredContent = #"{"canvasHeight":1333,"canvasWidth":1333,"contentPlacement":"top-left","format":"com.aiarcheology.native-model-image-sizing","formatVersion":1,"maxSize":1334,"minSize":800,"paddingFill":"normalized-zero","transformProfile":"torchvision-generalized-rcnn-v1"}"#
		XCTAssertNil(NativeModelImageSizingContract(userDefined: [
			NativeModelImageSizingContract.userDefinedKey: canvasTooSmallForTheDeclaredContent
		]), "a valid-looking contract cannot declare content larger than either canvas axis")
	}
}
