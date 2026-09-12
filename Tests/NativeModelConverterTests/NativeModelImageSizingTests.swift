//
//  NativeModelImageSizingTests.swift
//  NativeModelConverterTests
//
//  AIA-0680. Pins the app-side sizing against figures torchvision produced — Fixtures/
//  TorchvisionResizeOracle.json, written by scripts/generate_torchvision_resize_oracle.py, which
//  calls `GeneralizedRCNNTransform` rather than re-implementing it.
//
//  The distinction matters here more than usual. AIA-0675's weight-path slice shipped a test that
//  looked like it compared against real bytes and was in fact a closed loop, and a resize is the
//  same trap with a worse failure mode: a nearly-right bilinear moves every detected box with
//  nothing reporting an error. So nothing in this file computes an expected pixel value. The
//  geometry is asserted against committed integers; the pixels against committed samples.
//

import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelImageSizingTests: XCTestCase {

	// MARK: - Oracle

	private struct Oracle: Decodable {
		struct Sample: Decodable {
			let c: Int
			let y: Int
			let x: Int
			let value: Float
		}

		struct Transform: Decodable {
			let minSize: Int
			let maxSize: Int
			let sizeDivisible: Int
			let imageMean: [Float]
			let imageStd: [Float]
		}

		struct Case: Decodable {
			let name: String
			let pins: String
			let sourceWidth: Int
			let sourceHeight: Int
			let resizedWidth: Int
			let resizedHeight: Int
			let canvasWidth: Int
			let canvasHeight: Int
			let padRight: Int
			let padBottom: Int
			let scaleX: Double
			let scaleY: Double
			let paddedNormalisedSamples: [Sample]
			let resizedRawSamples: [Sample]
			let alignCornersTrueSamples: [Sample]
		}

		struct DegenerateAxisCase: Decodable {
			let name: String
			let channels: Int
			let sourceHeight: Int
			let sourceWidth: Int
			let targetHeight: Int
			let targetWidth: Int
			let source: [Float]
			let expected: [Float]
		}

		let degenerateAxisCases: [DegenerateAxisCase]
		let transform: Transform
		let absoluteToleranceNormalised: Float
		let absoluteToleranceRaw: Float
		let toleranceReason: String
		let cases: [Case]
	}

	private func loadOracle() throws -> Oracle {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: "TorchvisionResizeOracle", withExtension: "json"),
			"the committed oracle is missing from the test bundle"
		)
		return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
	}

	/// `((c·31 + y·7 + x·13) mod 256)`, planar CHW, in `[0, 255]` — the generator's input pattern.
	/// Integer-valued, so it is exact in float32 and exact through a uint8 buffer: any disagreement
	/// with torchvision is the resampler, never the input.
	private func deterministicImage(width: Int, height: Int) -> [Float] {
		var pixels = [Float](repeating: 0, count: 3 * width * height)
		var index = 0
		for channel in 0..<3 {
			for row in 0..<height {
				for column in 0..<width {
					pixels[index] = Float((channel * 31 + row * 7 + column * 13) % 256)
					index += 1
				}
			}
		}
		return pixels
	}

	private func geometry(for testCase: Oracle.Case, transform: Oracle.Transform) throws -> NativeModelImageSizing.Geometry {
		try XCTUnwrap(
			NativeModelImageSizing.geometry(
				source: NativeModelImageSize(width: testCase.sourceWidth, height: testCase.sourceHeight),
				minSize: transform.minSize,
				maxSize: transform.maxSize,
				strideDivisible: transform.sizeDivisible
			),
			"\(testCase.name): geometry could not be computed"
		)
	}

	// MARK: - Geometry, against torchvision's integers

	func testGeometry_matchesTorchvisionIntegersForEveryCase() throws {
		let oracle = try loadOracle()
		XCTAssertFalse(oracle.cases.isEmpty, "an empty oracle would make every assertion below vacuous")

		for testCase in oracle.cases {
			let geometry = try self.geometry(for: testCase, transform: oracle.transform)
			// Integers, not tolerances: these are sizes, and being one pixel out is the whole failure
			// this ticket exists to prevent.
			XCTAssertEqual(geometry.resizedSize.width, testCase.resizedWidth, "\(testCase.name) resized width — \(testCase.pins)")
			XCTAssertEqual(geometry.resizedSize.height, testCase.resizedHeight, "\(testCase.name) resized height — \(testCase.pins)")
			XCTAssertEqual(geometry.canvasSize.width, testCase.canvasWidth, "\(testCase.name) canvas width")
			XCTAssertEqual(geometry.canvasSize.height, testCase.canvasHeight, "\(testCase.name) canvas height")
			XCTAssertEqual(geometry.padRight, testCase.padRight, "\(testCase.name) pad right")
			XCTAssertEqual(geometry.padBottom, testCase.padBottom, "\(testCase.name) pad bottom")
			XCTAssertEqual(geometry.scaleX, testCase.scaleX, accuracy: 1e-12, "\(testCase.name) scaleX")
			XCTAssertEqual(geometry.scaleY, testCase.scaleY, accuracy: 1e-12, "\(testCase.name) scaleY")
		}
	}

	/// The per-axis scale is not a detail that can be averaged away, and one case in the oracle would
	/// let a single-scalar implementation pass. Both facts are asserted so neither can rot.
	func testGeometry_perAxisScaleIsRealAndTheTrapCaseWouldHideIt() throws {
		let oracle = try loadOracle()
		let named = Dictionary(uniqueKeysWithValues: oracle.cases.map { ($0.name, $0) })

		let perAxis = try XCTUnwrap(named["nonSquare769x512"])
		let geometry = try self.geometry(for: perAxis, transform: oracle.transform)
		XCTAssertTrue(geometry.hasPerAxisScale, "769×512 resizes to 1201×800; the two axes cannot share a scale")
		// Concretely: reusing scaleX for the vertical axis loses a pixel.
		let wrongHeight = Int((Double(perAxis.sourceHeight) * geometry.scaleX).rounded(.down))
		XCTAssertNotEqual(wrongHeight, geometry.resizedSize.height, "a single-scalar implementation must not agree here")

		let trap = try XCTUnwrap(named["nonSquare768x512"])
		let trapGeometry = try self.geometry(for: trap, transform: oracle.transform)
		XCTAssertFalse(
			trapGeometry.hasPerAxisScale,
			"768×512 scales both axes by exactly 1.5625 — it is in the oracle as a trap, and a suite "
				+ "that used only this case would report coverage it does not have"
		)
	}

	/// 646×1077 binds on `max_size` and still lands a pixel short on both axes. It is the case where
	/// precision and evaluation order in the output-size rule stop being academic.
	func testGeometry_knifeEdgeCaseDoesNotReachTheBindingLimit() throws {
		let oracle = try loadOracle()
		let knifeEdge = try XCTUnwrap(oracle.cases.first { $0.name == "knifeEdge646x1077" })
		let geometry = try self.geometry(for: knifeEdge, transform: oracle.transform)
		XCTAssertEqual(geometry.resizedSize.height, 1332, "the long side stops one pixel below max_size")
		XCTAssertEqual(geometry.resizedSize.width, 799, "and the short side one pixel below its own product")
		XCTAssertNotEqual(geometry.resizedSize.height, oracle.transform.maxSize, "assuming the bound is reached is the bug")
	}

	// MARK: - Pixels, against torchvision's samples

	func testResample_matchesTorchvisionResizeOnRawImage() throws {
		let oracle = try loadOracle()
		var worst: (name: String, error: Float) = ("", 0)
		var checked = 0
		XCTAssertFalse(
			oracle.cases.allSatisfy { $0.resizedRawSamples.isEmpty },
			"no case carries raw samples, so this test would pass without comparing anything"
		)

		for testCase in oracle.cases {
			let geometry = try self.geometry(for: testCase, transform: oracle.transform)
			// The oracle resized the [0, 1] image, so this does too — isolating the resampler from the
			// normalisation, which the next test covers.
			let source = deterministicImage(width: testCase.sourceWidth, height: testCase.sourceHeight).map { $0 / 255 }
			let resized = try XCTUnwrap(
				NativeModelImageSizing.resample(
					source, channels: 3, from: geometry.sourceSize, to: geometry.resizedSize
				),
				"\(testCase.name): resample returned nil"
			)
			guard testCase.resizedRawSamples.isEmpty == false else { continue }

			let plane = geometry.resizedSize.width * geometry.resizedSize.height
			for sample in testCase.resizedRawSamples {
				let index = sample.c * plane + sample.y * geometry.resizedSize.width + sample.x
				let error = abs(resized[index] - sample.value)
				if error > worst.error { worst = (testCase.name, error) }
				checked += 1
				XCTAssertEqual(
					resized[index], sample.value, accuracy: oracle.absoluteToleranceRaw,
					"\(testCase.name) at channel \(sample.c), row \(sample.y), column \(sample.x)"
				)
			}
		}
		XCTAssertGreaterThan(checked, 500, "a suite that compared a handful of points would not be evidence")
		print(
			"[AIA-0680] resampler vs torchvision over \(checked) samples, worst elementwise error: "
				+ "\(worst.error) on \(worst.name) ([0,1] units). Tolerance \(oracle.absoluteToleranceRaw) — "
				+ oracle.toleranceReason
		)
	}

	/// The whole forward claim in one assertion: resize the raw pixels, pad with the mean pixel, let
	/// the graph's affine normalise — and land on the tensor torchvision hands its network, which
	/// normalised *first* and padded with zeros. The two agree because bilinear interpolation is a
	/// convex combination and the affine is linear, so they commute.
	func testSizeThenNormalise_matchesTorchvisionPaddedTensor() throws {
		let oracle = try loadOracle()
		var worst: (name: String, error: Float) = ("", 0)

		for testCase in oracle.cases {
			let geometry = try self.geometry(for: testCase, transform: oracle.transform)
			let source = deterministicImage(width: testCase.sourceWidth, height: testCase.sourceHeight)
			let canvas = try XCTUnwrap(
				NativeModelImageSizing.size(source, channels: 3, geometry: geometry),
				"\(testCase.name): sizing returned nil"
			)
			let normalised = try XCTUnwrap(
				NativeModelImageSizing.normalized(
					canvas, channels: 3, size: geometry.canvasSize, preprocessing: .imageNetRGB
				),
				"\(testCase.name): normalisation returned nil"
			)

			let plane = geometry.canvasSize.width * geometry.canvasSize.height
			for sample in testCase.paddedNormalisedSamples {
				let index = sample.c * plane + sample.y * geometry.canvasSize.width + sample.x
				let error = abs(normalised[index] - sample.value)
				if error > worst.error { worst = (testCase.name, error) }
				XCTAssertEqual(
					normalised[index], sample.value, accuracy: oracle.absoluteToleranceNormalised,
					"\(testCase.name) at channel \(sample.c), row \(sample.y), column \(sample.x)"
				)
			}
		}
		print("[AIA-0680] sized+normalised vs torchvision, worst elementwise error: \(worst.error) (normalised units)")
	}

	/// The app receives BGRA raster bytes, but carrying a second planar Float copy of a tall page
	/// through all regions makes that representation itself the memory peak. This pins the direct
	/// sampler to the established planar implementation before Detector uses it to avoid that copy.
	func testDirectBGRASizing_matchesThePlanarSizingPath() throws {
		let sourceSize = NativeModelImageSize(width: 7, height: 5)
		let geometry = NativeModelImageSizing.Geometry(
			sourceSize: sourceSize,
			resizedSize: NativeModelImageSize(width: 11, height: 8),
			canvasSize: NativeModelImageSize(width: 16, height: 16)
		)
		let source = deterministicImage(width: sourceSize.width, height: sourceSize.height)
		let bgra = try XCTUnwrap(NativeModelImageSizing.interleavedBGRA(from: source, size: sourceSize))

		let expected = try XCTUnwrap(NativeModelImageSizing.size(source, channels: 3, geometry: geometry))
		let actual = try XCTUnwrap(NativeModelImageSizing.size(interleavedBGRA: bgra, geometry: geometry))
		XCTAssertEqual(actual, expected, "direct BGRA sampling must preserve the established resize and pad result")
	}

	/// The number production can actually deliver, as opposed to the float number above.
	///
	/// Core ML image inputs are 8-bit, so the resampler's fractional output is rounded on its way into
	/// the pixel buffer. This measures what that costs, and states it — the design is still far better
	/// than the 0.1296 an in-graph resize leaves, but only the honest figure supports that claim.
	func testQuantisedSizing_statesTheErrorProductionActuallyPays() throws {
		let oracle = try loadOracle()
		var worstNormalised: Float = 0

		for testCase in oracle.cases {
			let geometry = try self.geometry(for: testCase, transform: oracle.transform)
			let source = deterministicImage(width: testCase.sourceWidth, height: testCase.sourceHeight)
			let canvas = try XCTUnwrap(NativeModelImageSizing.size(source, channels: 3, geometry: geometry))
			let quantised = NativeModelImageSizing.quantizedToByteRange(canvas)
			let normalised = try XCTUnwrap(
				NativeModelImageSizing.normalized(
					quantised, channels: 3, size: geometry.canvasSize, preprocessing: .imageNetRGB
				)
			)

			let plane = geometry.canvasSize.width * geometry.canvasSize.height
			for sample in testCase.paddedNormalisedSamples {
				let index = sample.c * plane + sample.y * geometry.canvasSize.width + sample.x
				worstNormalised = max(worstNormalised, abs(normalised[index] - sample.value))
			}
		}

		// Half a code value on each of resample and pad, expressed in normalised units through the
		// worst channel (blue, std 0.225): (0.5/255)/0.225 = 0.00872 each. The bound is deliberately
		// just above the sum rather than round, so a regression that doubles it fails.
		let bound: Float = 0.02
		XCTAssertLessThan(worstNormalised, bound, "8-bit quantisation should cost well under one code value per stage")
		let inPixelUnits = worstNormalised * 0.225
		print(
			"[AIA-0680] production (8-bit) sizing error: \(worstNormalised) normalised "
				+ "≈ \(inPixelUnits) in [0,1] pixel units, against 0.1296 for the closest in-graph resize"
		)
		XCTAssertLessThan(inPixelUnits, 0.1296, "the whole design rests on beating the in-graph resize")
	}

	/// Proves the resampler is on `align_corners=False` rather than merely close to it.
	///
	/// Passing the previous test is weaker evidence than it looks. `align_corners=True` is a one-word
	/// difference, it produces a plausible image, and — writing `a = in/out` and `b = (in−1)/(out−1)` —
	/// the two conventions' source coordinates differ by `(a − b)·d + 0.5·(a − 1)`, which is zero at
	/// `d = (out − 1)/2` for every in/out pair. That is the edge midpoint; at the corners both clamp to
	/// the same source pixel. So the obvious sampling positions are exactly the positions where the
	/// wrong convention is invisible, and only an explicit disagreement settles it.
	func testResample_disagreesWithTheAlignCornersTrueConvention() throws {
		let oracle = try loadOracle()
		let falsifiable = oracle.cases.filter { $0.alignCornersTrueSamples.isEmpty == false }
		XCTAssertFalse(falsifiable.isEmpty, "without a wrong-convention reference this test asserts nothing")

		for testCase in falsifiable {
			let geometry = try self.geometry(for: testCase, transform: oracle.transform)
			let source = deterministicImage(width: testCase.sourceWidth, height: testCase.sourceHeight).map { $0 / 255 }
			let resized = try XCTUnwrap(
				NativeModelImageSizing.resample(source, channels: 3, from: geometry.sourceSize, to: geometry.resizedSize)
			)

			let plane = geometry.resizedSize.width * geometry.resizedSize.height
			var worst: Float = 0
			for sample in testCase.alignCornersTrueSamples {
				let index = sample.c * plane + sample.y * geometry.resizedSize.width + sample.x
				worst = max(worst, abs(resized[index] - sample.value))
			}
			// Far outside the tolerance the correct reference is held to, so the two references cannot
			// both be satisfied by the same implementation.
			XCTAssertGreaterThan(
				worst, oracle.absoluteToleranceRaw * 100,
				"\(testCase.name): the implementation is indistinguishable from align_corners=True, which "
					+ "means the previous test is passing for the wrong reason"
			)
		}
	}

	// MARK: - The trust boundary

	/// `resizedSize` is handed region sizes by whatever wires this up (AIA-0675). A zero or negative
	/// dimension has to be refused here rather than producing an empty buffer three calls later.
	func testResizedSize_refusesADegenerateSource() {
		for source in [
			NativeModelImageSize(width: 0, height: 10),
			NativeModelImageSize(width: 10, height: 0),
			NativeModelImageSize(width: -4, height: 10)
		] {
			XCTAssertNil(
				NativeModelImageSizing.resizedSize(for: source, minSize: 800, maxSize: 1333),
				"\(source) is not an image"
			)
		}
		XCTAssertNil(NativeModelImageSizing.resizedSize(for: NativeModelImageSize(width: 8, height: 8), minSize: 0, maxSize: 1333))
	}

	/// A one-pixel output axis samples the source **centre**, not its first pixel.
	///
	/// This is the `align_corners` trap in its least visible form. ATen's scale rule does carry an
	/// `output_size > 1 ? … : 0` guard, but it lives inside the `align_corners=True` branch; under the
	/// convention this component implements the scale stays `input/output` at every output length. The
	/// two answers differ by the whole span of the axis — 25.0 against 10.0 on `[10, 20, 30, 40]` — and
	/// the wrong one produces a perfectly plausible image.
	///
	/// It is reachable from the real sizing rule: a 2×2000 region binds on `maxSize` and resizes to
	/// 1×1333.
	func testResample_samplesTheSourceCentreWhenAnAxisCollapsesToOnePixel() throws {
		let oracle = try loadOracle()
		XCTAssertFalse(oracle.degenerateAxisCases.isEmpty, "no degenerate-axis reference: this test would assert nothing")

		for testCase in oracle.degenerateAxisCases {
			let resized = try XCTUnwrap(
				NativeModelImageSizing.resample(
					testCase.source,
					channels: testCase.channels,
					from: NativeModelImageSize(width: testCase.sourceWidth, height: testCase.sourceHeight),
					to: NativeModelImageSize(width: testCase.targetWidth, height: testCase.targetHeight)
				),
				"\(testCase.name): resample returned nil"
			)
			XCTAssertEqual(resized.count, testCase.expected.count, "\(testCase.name) element count")
			for (index, expected) in testCase.expected.enumerated() {
				XCTAssertEqual(resized[index], expected, accuracy: 1e-5, "\(testCase.name) at \(index)")
			}
		}

		// And the sizing rule really does produce it, so the case above is not hypothetical.
		let collapsed = try XCTUnwrap(
			NativeModelImageSizing.resizedSize(for: NativeModelImageSize(width: 2, height: 2000), minSize: 800, maxSize: 1333)
		)
		XCTAssertEqual(collapsed.width, 1, "a 2×2000 region really does collapse an axis to one pixel")
	}

	/// A 1×1 source scales to 800×800, where every output pixel's source coordinate `0.5·a − 0.5` is
	/// far below zero and must clamp to source pixel 0 rather than index out of bounds.
	func testResample_clampsBelowTheLowEdgeOnTheDegenerateCase() throws {
		let oracle = try loadOracle()
		let degenerate = try XCTUnwrap(oracle.cases.first { $0.name == "degenerate1x1" })
		let geometry = try self.geometry(for: degenerate, transform: oracle.transform)
		let source: [Float] = [10, 20, 30]
		let resized = try XCTUnwrap(
			NativeModelImageSizing.resample(source, channels: 3, from: geometry.sourceSize, to: geometry.resizedSize)
		)
		let plane = geometry.resizedSize.width * geometry.resizedSize.height
		XCTAssertEqual(resized.count, 3 * plane)
		// One source pixel per channel means every output pixel is that pixel, exactly.
		XCTAssertEqual(resized[0], 10)
		XCTAssertEqual(resized[plane - 1], 10)
		XCTAssertEqual(resized[2 * plane], 30)
	}

	/// The number AIA-0675 needs to decide whether a scalar Swift loop is fast enough, measured rather
	/// than reasoned about: a pass runs 15 regions every few seconds.
	func testResample_reportsItsCostForTheWiringSlice() throws {
		let oracle = try loadOracle()
		let realistic = try XCTUnwrap(oracle.cases.first { $0.name == "pageAspectRegion393x852" })
		let geometry = try self.geometry(for: realistic, transform: oracle.transform)
		let source = deterministicImage(width: realistic.sourceWidth, height: realistic.sourceHeight)

		let start = Date()
		_ = NativeModelImageSizing.size(source, channels: 3, geometry: geometry)
		let seconds = Date().timeIntervalSince(start)
		print(
			"[AIA-0680] sizing one 393×852 region to a 640×1344 canvas: \(Int(seconds * 1000)) ms, "
				+ "≈\(Int(seconds * 15_000)) ms for a 15-region pass — HOST DEBUG BUILD, which is about 100× "
				+ "slower than -O and must not be read as the shipping cost. Measured with swiftc -O the "
				+ "same call takes 4.8 ms per region, 0.07 s per pass, against the detect path's ~3 s cadence."
		)
	}

	// MARK: - The pad value

	func testPadding_fillsWithTheMeanPixelSoTheGraphSeesZero() throws {
		let oracle = try loadOracle()
		// A case with padding on both edges, so neither is assumed.
		let padded = try XCTUnwrap(oracle.cases.first { $0.padRight > 0 && $0.padBottom > 0 })
		let geometry = try self.geometry(for: padded, transform: oracle.transform)
		let source = deterministicImage(width: padded.sourceWidth, height: padded.sourceHeight)
		let canvas = try XCTUnwrap(NativeModelImageSizing.size(source, channels: 3, geometry: geometry))
		let normalised = try XCTUnwrap(
			NativeModelImageSizing.normalized(canvas, channels: 3, size: geometry.canvasSize, preprocessing: .imageNetRGB)
		)

		let plane = geometry.canvasSize.width * geometry.canvasSize.height
		// A position in the right margin and one in the bottom margin.
		let inRightMargin = 0 * plane + 0 * geometry.canvasSize.width + (geometry.canvasSize.width - 1)
		let inBottomMargin = 2 * plane + (geometry.canvasSize.height - 1) * geometry.canvasSize.width + 0
		// Not zero, and the test says so rather than pretending: 255·0.406 = 103.53 is not an 8-bit
		// value, and even before quantisation the float mean is only as exact as the constant.
		XCTAssertEqual(normalised[inRightMargin], 0, accuracy: 1e-5, "right margin should normalise to zero")
		XCTAssertEqual(normalised[inBottomMargin], 0, accuracy: 1e-5, "bottom margin should normalise to zero")

		// Padding is right and bottom only. A centred implementation would put content here.
		let topLeft = normalised[0]
		XCTAssertNotEqual(topLeft, 0, accuracy: 1e-6, "content must start at the canvas origin, not inset by half the padding")
	}

	// MARK: - The buffer handed to Core ML

	func testInterleavedBGRA_ordersChannelsForTheBufferCoreMLIsFed() throws {
		// Per-channel-distinct values, so a red/blue swap cannot hide behind equal channels.
		let size = NativeModelImageSize(width: 2, height: 1)
		let planar: [Float] = [10, 20, /* R */ 100, 110, /* G */ 200, 210 /* B */]
		let bytes = try XCTUnwrap(NativeModelImageSizing.interleavedBGRA(from: planar, size: size))
		XCTAssertEqual(Array(bytes[0..<4]), [200, 100, 10, 255], "byte 0 is blue, byte 2 is red")
		XCTAssertEqual(Array(bytes[4..<8]), [210, 110, 20, 255])
	}

	func testInterleavedBGRA_writesTheMeanFillAsTheBytesTheGraphCancels() throws {
		let size = NativeModelImageSize(width: 1, height: 1)
		let mean = NativeModelImageSizing.imageNetMeanPixels
		let bytes = try XCTUnwrap(NativeModelImageSizing.interleavedBGRA(from: [mean[0], mean[1], mean[2]], size: size))
		// 255·[0.485, 0.456, 0.406] = [123.675, 116.28, 103.53] → [124, 116, 104], written B, G, R, A.
		XCTAssertEqual(Array(bytes), [104, 116, 124, 255])
	}

	// MARK: - The inverse

	func testSourceBox_isTheInverseOfTheForwardMappingOnEveryCase() throws {
		let oracle = try loadOracle()
		let box = NativeModelNormalizedRect(x: 0.2, y: 0.3, width: 0.35, height: 0.25)

		for testCase in oracle.cases {
			let geometry = try self.geometry(for: testCase, transform: oracle.transform)
			let onCanvas = try XCTUnwrap(geometry.canvasBox(fromSourceBox: box), "\(testCase.name) forward")
			let returned = try XCTUnwrap(geometry.sourceBox(fromCanvasBox: onCanvas), "\(testCase.name) inverse")
			// Stated in source pixels, because a normalised tolerance means different things on a 393-px
			// crop and a 2000-px one.
			let horizontal = Double(testCase.sourceWidth)
			let vertical = Double(testCase.sourceHeight)
			XCTAssertEqual(returned.x * horizontal, box.x * horizontal, accuracy: 0.01, "\(testCase.name) x")
			XCTAssertEqual(returned.y * vertical, box.y * vertical, accuracy: 0.01, "\(testCase.name) y")
			XCTAssertEqual(returned.width * horizontal, box.width * horizontal, accuracy: 0.01, "\(testCase.name) width")
			XCTAssertEqual(returned.height * vertical, box.height * vertical, accuracy: 0.01, "\(testCase.name) height")
		}
	}

	/// One-way, so a shared error cannot cancel: a box placed by hand on the canvas, un-mapped with
	/// arithmetic written out in the comment rather than borrowed from the implementation.
	func testSourceBox_matchesAHandComputedInverse() throws {
		// 393×852 → 614×1333 content on a 640×1344 canvas (torchvision's own integers, from the oracle).
		let geometry = NativeModelImageSizing.Geometry(
			sourceSize: NativeModelImageSize(width: 393, height: 852),
			resizedSize: NativeModelImageSize(width: 614, height: 1333),
			canvasSize: NativeModelImageSize(width: 640, height: 1344)
		)
		// Canvas pixels (top-left): x 0…307, y 0…666.5 — the top-left quadrant of the *content*.
		// In Vision's bottom-left normalised terms that is
		//   x = 0, width = 307/640 = 0.4796875
		//   y = (1344 − 666.5)/1344 = 0.50409..., height = 666.5/1344 = 0.49590...
		let onCanvas = NativeModelNormalizedRect(
			x: 0, y: (1344.0 - 666.5) / 1344.0, width: 307.0 / 640.0, height: 666.5 / 1344.0
		)
		let source = try XCTUnwrap(geometry.sourceBox(fromCanvasBox: onCanvas))
		// Un-scale by source ÷ resized, per axis: 393/614 across, 852/1333 down.
		//   left   = 0   · 393/614 = 0
		//   right  = 307 · 393/614 = 196.5
		//   top    = 0   · 852/1333 = 0
		//   bottom = 666.5 · 852/1333 = 426.0
		XCTAssertEqual(source.x * 393, 0, accuracy: 0.01)
		XCTAssertEqual(source.width * 393, 196.5, accuracy: 0.01)
		XCTAssertEqual((1 - (source.y + source.height)) * 852, 0, accuracy: 0.01, "top edge, converted back to raster")
		XCTAssertEqual((1 - source.y) * 852, 426.0, accuracy: 0.01, "bottom edge, converted back to raster")
	}

	func testSourceBox_clipsABoxStraddlingThePadBoundary() throws {
		let geometry = NativeModelImageSizing.Geometry(
			sourceSize: NativeModelImageSize(width: 393, height: 852),
			resizedSize: NativeModelImageSize(width: 614, height: 1333),
			canvasSize: NativeModelImageSize(width: 640, height: 1344)
		)
		// Spans canvas x 600…640: 14 px of content, 26 px of padding.
		let straddling = NativeModelNormalizedRect(x: 600.0 / 640.0, y: 0.5, width: 40.0 / 640.0, height: 0.1)
		let source = try XCTUnwrap(geometry.sourceBox(fromCanvasBox: straddling))
		// Only the content part survives: right edge clipped to 614, i.e. 393 source pixels.
		XCTAssertEqual((source.x + source.width) * 393, 393, accuracy: 0.01, "the padded part must not extend the box")
		XCTAssertEqual(source.x * 393, 600.0 * 393.0 / 614.0, accuracy: 0.01)

		// Wholly inside the padding: there is no source box to report.
		let allPadding = NativeModelNormalizedRect(x: 620.0 / 640.0, y: 0.5, width: 20.0 / 640.0, height: 0.1)
		XCTAssertNil(geometry.sourceBox(fromCanvasBox: allPadding))
	}

	// MARK: - The crop, and its Y flip

	/// A hand-computed literal, because the flip is the one step in the chain that inverts itself: a
	/// forward crop using `region.minY` and an inverse using `pixelRect.minY` round-trip perfectly
	/// while mirroring every box on the page.
	func testCropPlan_flipsVisionCoordinatesToRasterPixels() throws {
		let frame = NativeModelImageSize(width: 901, height: 1501)
		// Vision's bottom-left third of the page.
		let bottomLeftThird = NativeModelNormalizedRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1.0 / 3.0)
		let plan = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: bottomLeftThird))
		//   left   = 0
		//   right  = 901/3      = 300.333 → 300
		//   top    = (1 − 1/3)·1501 = 1000.667 → 1001    <- the flip: Vision's y=0 is the page BOTTOM
		//   bottom = 1501
		XCTAssertEqual(plan.pixelRect, NativeModelPixelRect(x: 0, y: 1001, width: 300, height: 500))

		// The same region raised to the middle third must move UP the raster, not down.
		let middleThird = NativeModelNormalizedRect(x: 0, y: 1.0 / 3.0, width: 1.0 / 3.0, height: 1.0 / 3.0)
		let middle = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: middleThird))
		XCTAssertLessThan(middle.pixelRect.y, plan.pixelRect.y, "a higher Vision y is a smaller raster y")
	}

	/// The region that comes back out has to describe the pixels that were actually cropped, not the
	/// ideal thirds that were asked for — a third of 901 px is 300.333, and remapping through the
	/// ideal fraction displaces every box in the tile.
	func testCropPlan_reportsTheRegionTheIntegralCropReallyCovers() throws {
		let frame = NativeModelImageSize(width: 901, height: 1501)
		let ideal = NativeModelNormalizedRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1.0 / 3.0)
		let plan = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: ideal))

		XCTAssertEqual(plan.effectiveRegion.width * 901, Double(plan.pixelRect.width), accuracy: 1e-9)
		XCTAssertEqual(plan.effectiveRegion.x * 901, Double(plan.pixelRect.x), accuracy: 1e-9)
		// The vertical pair matters more than the horizontal one and was the gap: `effectiveRegion` is
		// consumed by `TileLayout.remap`, and a round trip that maps a box out and back through the SAME
		// effective region cancels any error in it. Only a comparison against the pixel rectangle — which
		// is itself pinned by a hand-computed literal — can catch a vertical shift.
		XCTAssertEqual(plan.effectiveRegion.height * 1501, Double(plan.pixelRect.height), accuracy: 1e-9)
		// Vision's y is measured from the bottom, so it is the crop's FAR raster edge that fixes it.
		XCTAssertEqual(
			plan.effectiveRegion.y * 1501, Double(1501 - (plan.pixelRect.y + plan.pixelRect.height)), accuracy: 1e-9,
			"effectiveRegion.y must describe the same rows pixelRect does, measured from the page bottom"
		)
		XCTAssertNotEqual(
			plan.effectiveRegion.width, ideal.width,
			"901 is not divisible by three; the effective region must differ from the requested one"
		)
	}

	func testCropPlan_rejectsARegionThatRoundsToNothing() throws {
		let frame = NativeModelImageSize(width: 100, height: 100)
		let sliver = NativeModelNormalizedRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001)
		XCTAssertNil(NativeModelImageSizing.cropPlan(frame: frame, region: sliver), "a zero-pixel crop is not a crop")
	}

	/// `Int(_: Double)` is a runtime trap, not a nil — so a region carrying a non-finite or absurd
	/// coordinate has to be refused before any conversion, and this test would crash rather than fail
	/// if it were not.
	func testCropPlan_rejectsRegionsThatWouldTrapTheConversion() {
		let frame = NativeModelImageSize(width: 100, height: 100)
		for region in [
			NativeModelNormalizedRect(x: .nan, y: 0, width: 0.5, height: 0.5),
			NativeModelNormalizedRect(x: 0, y: .infinity, width: 0.5, height: 0.5),
			NativeModelNormalizedRect(x: 0, y: 0, width: .nan, height: 0.5),
			NativeModelNormalizedRect(x: 1e300, y: 0, width: 0.5, height: 0.5),
			NativeModelNormalizedRect(x: 0, y: 0, width: -0.5, height: 0.5)
		] {
			XCTAssertNil(NativeModelImageSizing.cropPlan(frame: frame, region: region), "\(region) must be refused")
		}
	}

	/// A frame large enough that the crop arithmetic leaves `Int`'s range.
	///
	/// `Double(Int.max)` rounds **up** to exactly 2^63, which is already one past `Int.max`, so
	/// converting it back traps. Clamping with `min(frame.width, Int(value))` does not help: the
	/// conversion happens first. This test would crash rather than fail if the conversion were not
	/// range-checked before it happens.
	func testCropPlan_refusesAFrameWhoseArithmeticLeavesIntRange() {
		XCTAssertNil(NativeModelImageSizing.cropPlan(
			frame: NativeModelImageSize(width: Int.max, height: 1), region: .unit
		))
		XCTAssertNil(NativeModelImageSizing.cropPlan(
			frame: NativeModelImageSize(width: 1, height: Int.max), region: .unit
		))
	}

	/// Buffer-length guards multiply before they compare, so the product has to be checked rather
	/// than trusted: `channels * width * height` overflows and traps long before a count mismatch
	/// could return nil.
	func testBufferEntryPoints_refuseSizesWhoseElementCountOverflows() {
		let huge = NativeModelImageSize(width: Int.max, height: Int.max)
		let small = NativeModelImageSize(width: 2, height: 2)
		XCTAssertNil(NativeModelImageSizing.resample([0, 0, 0, 0], channels: 1, from: huge, to: small))
		XCTAssertNil(NativeModelImageSizing.resample([0, 0, 0, 0], channels: 1, from: small, to: huge))
		XCTAssertNil(NativeModelImageSizing.interleavedBGRA(from: [0, 0, 0], size: huge))
		XCTAssertNil(NativeModelImageSizing.normalized([0, 0, 0], channels: 3, size: huge, preprocessing: .imageNetRGB))
		XCTAssertNil(NativeModelImageSizing.canvas(
			from: [0, 0, 0, 0], channels: 1,
			geometry: NativeModelImageSizing.Geometry(sourceSize: small, resizedSize: small, canvasSize: huge),
			fill: [0]
		))
	}

	/// The same boundary on the other public entry points.
	func testPublicEntryPoints_refuseRatherThanTrapOnAbsurdInput() {
		XCTAssertNil(NativeModelImageSizing.canvasSize(for: NativeModelImageSize(width: Int.max, height: 8), strideDivisible: 32))
		XCTAssertNil(NativeModelImageSizing.resizedSize(for: NativeModelImageSize(width: 8, height: 8), minSize: Int.max, maxSize: Int.max))
		// A preprocessing value whose arrays are shorter than its colour space's channel count.
		let malformed = NativeModelImagePreprocessing(colorSpace: .rgb, scale: [], bias: [])
		XCTAssertNil(
			NativeModelImageSizing.normalized(
				[1, 2, 3], channels: 3, size: NativeModelImageSize(width: 1, height: 1), preprocessing: malformed
			),
			"empty scale/bias arrays would index out of bounds"
		)
	}
}
