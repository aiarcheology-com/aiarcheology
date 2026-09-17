//
//  VisionScaleFitProbeTests.swift
//  MLBrowserUnitTests
//
//  AIA-0680, acceptance criterion 1: is `VNCoreMLRequest`'s `.scaleFit` an identity when the image
//  already matches the model's input size?
//
//  It has to be measured rather than reasoned about, because the answer decides the design. If it is
//  an identity, the app can pre-size an ADAF input and let Vision pass it through untouched. If it is
//  not, the only alternative is bypassing `VNCoreMLRequest`'s scaling — which collides with AIA-0675's
//  criterion 9, since a model that does not present a Vision detector interface makes
//  `Detector.detect`'s `as? [VNRecognizedObjectObservation]` cast yield zero detections with no error.
//
//  The measurement is decomposed into three parts on purpose. A single "Vision output versus source
//  bytes" number conflates two different things — pixel-format and colour conversion, which happens
//  whatever Vision does, and resampling, which is the actual question — and reports their sum as if it
//  answered one of them.
//

import CoreImage
import CoreML
import UIKit
import Vision
import XCTest
import NativeModelConverter

final class VisionScaleFitProbeTests: XCTestCase {

	private static let side = 64
	private static let mismatchedSide = 65

	// MARK: - Fixture

	/// Loads the committed identity probe, compiling it at runtime if Xcode copied it uncompiled.
	///
	/// Both lookups are here because whether Xcode's CoreML build rule fires for a model in a test
	/// target's Resources phase is a build-system detail, not something this test should depend on —
	/// and the runtime-compile branch is what `DeepDriver.loadModel(from:computeUnit:)` does for an imported
	/// model anyway. `XCTUnwrap` on the pair means an absent fixture fails loudly rather than skipping.
	private func loadProbeModel() throws -> MLModel {
		let bundle = Bundle(for: Self.self)
		if let compiled = bundle.url(forResource: "VisionScaleFitProbe", withExtension: "mlmodelc") {
			return try MLModel(contentsOf: compiled)
		}
		let raw = try XCTUnwrap(
			bundle.url(forResource: "VisionScaleFitProbe", withExtension: "mlmodel"),
			"VisionScaleFitProbe is missing from the test bundle — regenerate it with "
				+ "scripts/generate_vision_scalefit_probe_model.py and check its Resources membership"
		)
		let compiled = try MLModel.compileModel(at: raw)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
		return try MLModel(contentsOf: compiled)
	}

	// MARK: - Input

	/// Per-channel-distinct integer values, so a red/blue swap cannot hide behind equal channels and
	/// every value is exact in both uint8 and float32.
	private func planarPattern(side: Int) -> [Float] {
		var planar = [Float](repeating: 0, count: 3 * side * side)
		let plane = side * side
		for row in 0..<side {
			for column in 0..<side {
				let offset = row * side + column
				planar[offset] = Float((column * 3 + row * 5) % 256)
				planar[plane + offset] = Float((column * 7 + row * 11) % 256)
				planar[2 * plane + offset] = Float((column * 13 + row * 17) % 256)
			}
		}
		return planar
	}

	/// Builds the image the way the detect path does: a CGImage in sRGB, wrapped as a `UIImage` and
	/// then a `CIImage`, which is what `Detector.detect(image:regions:)` hands its request handler.
	///
	/// The bytes are laid out by `NativeModelImageSizing.interleavedBGRA`, the same function the real
	/// pipeline would use, so a channel-order mistake shows up as a channel-order failure below rather
	/// than masquerading as "Vision is not an identity".
	private func makeImage(side: Int) throws -> (image: UIImage, planar: [Float]) {
		let planar = planarPattern(side: side)
		let bytes = try XCTUnwrap(
			NativeModelImageSizing.interleavedBGRA(from: planar, size: NativeModelImageSize(width: side, height: side))
		)
		let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
		let provider = try XCTUnwrap(CGDataProvider(data: data))
		let cgImage = try XCTUnwrap(CGImage(
			width: side,
			height: side,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: side * 4,
			space: colorSpace,
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		))
		return (UIImage(cgImage: cgImage), planar)
	}

	// MARK: - Readers

	private func planarOutput(from features: MLFeatureProvider) throws -> [Float] {
		let value = try XCTUnwrap(features.featureValue(for: "passthrough")?.multiArrayValue)
		return (0..<value.count).map { Float(truncating: value[$0]) }
	}

	private func worstDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
		guard lhs.count == rhs.count else { return .infinity }
		return zip(lhs, rhs).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
	}

	// MARK: - (a) The conversion floor: what happens before Vision does anything

	/// Renders the CIImage into a pixel buffer in the model's own constrained format and predicts
	/// directly. Vision has to perform this same conversion, so whatever it costs is a floor under
	/// (b) rather than part of the resampling answer.
	private func predictionOutput(model: MLModel, image: UIImage) throws -> [Float] {
		let constraint = try XCTUnwrap(
			model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
			"the probe must present an image input, or Vision would refuse it outright"
		)
		var buffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			nil, constraint.pixelsWide, constraint.pixelsHigh, constraint.pixelFormatType,
			[kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer
		)
		let pixelBuffer = try XCTUnwrap(buffer, "CVPixelBufferCreate failed with status \(status)")
		let ciImage = try XCTUnwrap(CIImage(image: image))
		CIContext().render(ciImage, to: pixelBuffer)

		let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
		return try planarOutput(from: model.prediction(from: input))
	}

	// MARK: - (b) and (c) Vision

	private func visionOutput(model: MLModel, image: UIImage) throws -> [Float] {
		let visionModel = try VNCoreMLModel(for: model)
		let request = VNCoreMLRequest(model: visionModel)
		// Exactly what Detector.loadFile() sets.
		request.imageCropAndScaleOption = .scaleFit
		let ciImage = try XCTUnwrap(CIImage(image: image))
		try VNImageRequestHandler(ciImage: ciImage).perform([request])

		let observations = try XCTUnwrap(
			request.results as? [VNCoreMLFeatureValueObservation],
			"a raw multi-array output should come back as VNCoreMLFeatureValueObservation"
		)
		let observation = try XCTUnwrap(observations.first)
		let value = try XCTUnwrap(observation.featureValue.multiArrayValue)
		return (0..<value.count).map { Float(truncating: value[$0]) }
	}

	// MARK: - The measurement

	func testScaleFit_isMeasuredAtMatchedSizeAndTheProbeIsNotBlind() async throws {
		let systemDescription = await MainActor.run {
			"\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
		}
		let model = try loadProbeModel()
		let (image, planar) = try makeImage(side: Self.side)

		let predicted = try predictionOutput(model: model, image: image)
		let visionOutputMatched = try visionOutput(model: model, image: image)
		let floor = worstDifference(predicted, planar)
		let visionMatched = worstDifference(visionOutputMatched, planar)
		// The decisive comparison is Vision against the direct prediction **elementwise**. Subtracting
		// two scalar maxima would not establish it: the two worst pixels can be different pixels with
		// errors in opposite directions, so a floor of 50 and a Vision error of 50 would look like a
		// difference of zero while Vision was in fact wrong by 50 everywhere.
		let visionVersusPrediction = worstDifference(visionOutputMatched, predicted)

		// The control. The same pattern one pixel larger forces `.scaleFit` to actually resample; if
		// this does not diverge sharply from the matched-size figure, the probe is measuring nothing
		// and the matched-size result is worthless.
		let (larger, _) = try makeImage(side: Self.mismatchedSide)
		let visionMismatched = worstDifference(try visionOutput(model: model, image: larger), planar)

		print(
			"""
			[AIA-0680] Vision .scaleFit probe, iOS simulator, \(systemDescription), sRGB source, pixel format \
			\(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint?.pixelFormatType ?? 0):
			  (a) conversion floor, CIContext render + MLModel.prediction : \(floor)
			  (b) Vision .scaleFit at matched \(Self.side)×\(Self.side)      : \(visionMatched)
			  (c) Vision .scaleFit at mismatched \(Self.mismatchedSide)×\(Self.mismatchedSide)   : \(visionMismatched)
			  Vision against the direct prediction, elementwise            : \(visionVersusPrediction)
			  (values are raw 0…255 code units; the last line is the answer, the two above it are context)
			"""
		)

		XCTAssertGreaterThan(
			visionMismatched, 8,
			"the mismatched-size control must show substantial resampling, or this probe cannot detect "
				+ "resampling at all and (b) proves nothing"
		)
		XCTAssertLessThan(
			visionMatched, visionMismatched / 4,
			"at matched size Vision must be dramatically closer to the source than when it resamples"
		)
		// The claim the design rests on: at matched size Vision adds nothing beyond the conversion every
		// path pays. Asserted elementwise against the direct prediction, so no cancellation between two
		// unrelated maxima can make a real divergence look like zero.
		XCTAssertLessThanOrEqual(
			visionVersusPrediction, 0.5,
			"Vision resampled a matched-size input; pre-sizing app-side would not survive it, and the "
				+ "fallback collides with AIA-0675 criterion 9"
		)
		XCTAssertLessThanOrEqual(floor, 0.5, "the conversion itself must not move a pixel either")
	}

	/// Kept separate from the geometry so the two findings cannot be confused. Core ML de-interleaves a
	/// 32BGRA buffer into R, G, B planes for an `.rgb` input, so a byte-order mistake in the fixture
	/// would otherwise read as "Vision is not an identity".
	func testProbe_returnsTheChannelsInTheOrderItWasGivenThem() throws {
		let model = try loadProbeModel()
		let (image, planar) = try makeImage(side: Self.side)
		let output = try visionOutput(model: model, image: image)
		let plane = Self.side * Self.side
		XCTAssertEqual(output.count, 3 * plane)

		// Elementwise, not by channel mean. The means of this pattern are 126.81, 128.13 and 127.31 —
		// within about one code unit of each other — so a mean comparison at any usable tolerance cannot
		// see the red/blue swap it exists to catch. Individual pixels differ by far more.
		for channel in 0..<3 {
			let worst = zip(
				output[(channel * plane)..<((channel + 1) * plane)],
				planar[(channel * plane)..<((channel + 1) * plane)]
			).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
			XCTAssertLessThanOrEqual(worst, 0.5, "channel \(channel) does not match the channel it was given")
		}
	}
}
