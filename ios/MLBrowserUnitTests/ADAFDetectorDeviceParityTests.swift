//
//  ADAFDetectorDeviceParityTests.swift
//  MLBrowserUnitTests
//
//  AIA-0688's physical-device closeout. This test is opt-in because the locally staged detector
//  is roughly 191 MiB and is intentionally not a source-controlled test fixture.
//
//  Both tests run against the torchvision-oracle fixture produced by
//  scripts/prepare_adaf_device_parity_assets.sh.
//
//  `.cpuOnly` is the only placement that holds the 1 px budget. Measured on an iPhone 16 Pro Max
//  (iOS 26.5.2), maximum box shift against the oracle:
//
//      .cpuOnly                      0.00033092498779296875 px
//      .cpuAndNeuralEngine / .all    3.913543701171875 px
//      .cpuAndGPU                    9.662333488464355 px
//
//  An earlier revision of this file asserted that `.cpuAndGPU` met the same budgets, on the strength
//  of AIA-0676 measuring that placement bit-identical to `.cpuOnly`. That probe ran on a
//  random-weights model and did not generalise: on the real detector the GPU path is the *worst* of
//  the three. The requirement is therefore CPU placement, not ANE exclusion — the GPU runs this
//  graph in Float32, so its ~1e-06 reassociation difference is already enough to flip a near-tie in
//  the terminal NMS onto a different overlapping proposal.
//
//  The contract and the characterisation are deliberately separate test methods. When they shared
//  one method, an accelerator failure aborted the run before the blank-tile checks were reached, so
//  the contract could never be observed passing on its own.
//

import CoreGraphics
import CoreML
import Foundation
import NativeModelConverter
import Vision
import XCTest
@testable import ML_Browser

final class ADAFDetectorDeviceParityTests: XCTestCase {

	private static let fixtureName = "AOBarrowOracle"
	private static let modelName = "AOBarrowDetector"
	private static let canvasName = "AOBarrowCanvas"

	/// The parity contract: `.cpuOnly` reproduces torchvision, and the shipping loader selects it.
	func testDeviceComputeUnits_cpuOnlyMatchesTorchvisionThroughTheShippingLoader() async throws {
		let probe = try makeProbe()

		let cpuDetections = try detect(
			image: probe.image, compiledModel: probe.compiledModel, computeUnits: .cpuOnly,
			geometry: probe.geometry
		)
		assertOracleBudgets(
			measure(cpuDetections, reference: probe.fixture.reference, matchIoU: probe.fixture.rule.matchIoU),
			referenceCount: probe.fixture.reference.count,
			rule: probe.fixture.rule,
			computeUnits: .cpuOnly,
			systemVersion: probe.systemVersion
		)

		// The converter stamps its numerical requirement into creatorDefined metadata, and the app's
		// production loader honors it before Vision receives the model. Assert on the same path that
		// imported ADAF models actually take.
		let loadedShippingModel = try await Detector.loadModel(from: probe.compiledModel, demo: true)
		let shippingModel = try XCTUnwrap(
			loadedShippingModel,
			"The converted detector must load through the production driver path."
		)
		let userDefined = try XCTUnwrap(
			shippingModel.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
			"The converted detector must carry creatorDefined metadata. A fixture staged before the "
				+ "runtime policy existed will fail here; regenerate it from HEAD."
		)
		XCTAssertEqual(
			NativeModelRuntimePolicy.computeUnitPolicy(from: userDefined),
			.cpuOnly,
			"The converted ADAF detector must carry the measured CPU placement requirement."
		)
		assertOracleBudgets(
			measure(
				try detect(image: probe.image, model: shippingModel, geometry: probe.geometry),
				reference: probe.fixture.reference, matchIoU: probe.fixture.rule.matchIoU
			),
			referenceCount: probe.fixture.reference.count,
			rule: probe.fixture.rule,
			computeUnits: .cpuOnly,
			systemVersion: probe.systemVersion
		)

		let blankDetections = try detect(
			image: try makeBlankImage(size: probe.canvasSize), compiledModel: probe.compiledModel,
			computeUnits: .cpuOnly, geometry: probe.geometry
		)
		XCTAssertTrue(
			blankDetections.isEmpty,
			"cpuOnly produced \(blankDetections.count) phantom detections for an empty tile"
		)
	}

	/// Characterises the placements the policy excludes, and trips if one of them starts conforming.
	///
	/// This is not a second parity claim. It records what each accelerator does on this hardware so a
	/// future OS, chip, or graph change cannot quietly move the boundary in either direction: a
	/// *worse* result still fails the structural checks below, and a *conforming* result fails the
	/// tripwire and asks for the CPU-only requirement to be re-evaluated.
	func testDeviceComputeUnits_acceleratorPlacementsStayOutsideTheParityBudget() throws {
		let probe = try makeProbe()
		let cpuDetections = try detect(
			image: probe.image, compiledModel: probe.compiledModel, computeUnits: .cpuOnly,
			geometry: probe.geometry
		)

		for computeUnits in [MLComputeUnits.cpuAndGPU, .cpuAndNeuralEngine, .all] {
			let detections = try detect(
				image: probe.image, compiledModel: probe.compiledModel, computeUnits: computeUnits,
				geometry: probe.geometry
			)
			let againstOracle = measure(
				detections, reference: probe.fixture.reference, matchIoU: probe.fixture.rule.matchIoU
			)
			reportDivergence(
				againstOracle, referenceCount: probe.fixture.reference.count, reference: "torchvision",
				computeUnits: computeUnits, systemVersion: probe.systemVersion
			)
			reportDivergence(
				measure(detections, reference: cpuDetections, matchIoU: probe.fixture.rule.matchIoU),
				referenceCount: cpuDetections.count, reference: "cpuOnly",
				computeUnits: computeUnits, systemVersion: probe.systemVersion
			)

			// The detection *set* survives every measured placement; only the box budget breaks. A
			// changed set would be a materially worse regression than the one this policy documents.
			XCTAssertTrue(
				againstOracle.disappeared.isEmpty && againstOracle.appeared.isEmpty,
				"\(computeUnits.label) changed the torchvision detection set: "
					+ "\(againstOracle.disappeared.count) disappeared, \(againstOracle.appeared.count) appeared"
			)
			XCTAssertGreaterThan(
				againstOracle.maximumBoxShift ?? 0,
				probe.fixture.rule.maxBoxShiftPixels,
				"\(computeUnits.label) now holds the \(probe.fixture.rule.maxBoxShiftPixels) px budget "
					+ "(box shift \(describe(againstOracle.maximumBoxShift)) px). This is the tripwire, not a "
					+ "failure of the detector: re-measure this placement and re-evaluate the CPU-only "
					+ "requirement in NativeModelRuntimePolicy before relaxing it."
			)

			// A phantom detection on an empty tile would be a correctness bug on any placement, not a
			// precision budget question, so it is asserted rather than merely reported.
			let blankDetections = try detect(
				image: try makeBlankImage(size: probe.canvasSize), compiledModel: probe.compiledModel,
				computeUnits: computeUnits, geometry: probe.geometry
			)
			XCTAssertTrue(
				blankDetections.isEmpty,
				"\(computeUnits.label) produced \(blankDetections.count) phantom detections for an empty tile"
			)
		}
	}

	// MARK: - Probe

	private struct Probe {
		let fixture: Fixture
		let geometry: NativeModelImageSizing.Geometry
		let canvasSize: NativeModelImageSize
		let image: CGImage
		let compiledModel: URL
		let systemVersion: String
	}

	private func makeProbe() throws -> Probe {
		guard Bundle(for: Self.self).url(forResource: Self.fixtureName, withExtension: "json") != nil else {
			throw XCTSkip(
				"Device-only parity probe. Run scripts/prepare_adaf_device_parity_assets.sh and stage "
					+ "the assets with AIA_DEVICE_PARITY_ASSETS before building the test bundle."
			)
		}
		let fixture = try loadFixture()
		let sourceSize = NativeModelImageSize(width: fixture.sourceSize.width, height: fixture.sourceSize.height)
		let canvasSize = NativeModelImageSize(width: fixture.canvasSize.width, height: fixture.canvasSize.height)
		let geometry = try XCTUnwrap(
			NativeModelImageSizing.geometry(source: sourceSize, minSize: 800, maxSize: 1_333, canvas: canvasSize)
		)
		let canvas = try loadPortablePixmap(named: Self.canvasName)
		XCTAssertEqual(canvas.width, canvasSize.width)
		XCTAssertEqual(canvas.height, canvasSize.height)
		return Probe(
			fixture: fixture,
			geometry: geometry,
			canvasSize: canvasSize,
			image: try makeImage(rgb: canvas.rgb, width: canvas.width, height: canvas.height),
			compiledModel: try loadCompiledModel(),
			systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
		)
	}

	// MARK: - Fixture

	private func loadFixture() throws -> Fixture {
		let bundle = Bundle(for: Self.self)
		let url = try XCTUnwrap(
			bundle.url(forResource: Self.fixtureName, withExtension: "json"),
			"The device fixture is absent. Run scripts/prepare_adaf_device_parity_assets.sh and pass "
				+ "AIA_DEVICE_PARITY_ASSETS=$PWD/.adaf-device-parity-assets to xcodebuild."
		)
		return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
	}

	private func loadCompiledModel() throws -> URL {
		let bundle = Bundle(for: Self.self)
		if let compiled = bundle.url(forResource: Self.modelName, withExtension: "mlmodelc") {
			return compiled
		}
		return try XCTUnwrap(
			bundle.url(forResource: Self.modelName, withExtension: "mlmodel"),
			"The locally staged detector is absent from the test bundle. Check the Device Parity Assets build phase."
		)
	}

	private func loadPortablePixmap(named name: String) throws -> PortablePixmap {
		let bundle = Bundle(for: Self.self)
		let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "ppm"))
		let bytes = [UInt8](try Data(contentsOf: url))
		var index = 0
		let magic = try nextHeaderToken(in: bytes, index: &index)
		let width = try XCTUnwrap(Int(try nextHeaderToken(in: bytes, index: &index)))
		let height = try XCTUnwrap(Int(try nextHeaderToken(in: bytes, index: &index)))
		let maximum = try XCTUnwrap(Int(try nextHeaderToken(in: bytes, index: &index)))
		guard magic == "P6", width > 0, height > 0, maximum == 255 else {
			throw FixtureError.invalidPortablePixmap(name)
		}
		guard index < bytes.count, isWhitespace(bytes[index]) else {
			throw FixtureError.invalidPortablePixmap(name)
		}
		index += 1
		if index < bytes.count, bytes[index - 1] == 13, bytes[index] == 10 { index += 1 }
		let expected = try checkedProduct(width, height, 3)
		guard bytes.count - index == expected else { throw FixtureError.invalidPortablePixmap(name) }
		return PortablePixmap(rgb: Array(bytes[index...]), width: width, height: height)
	}

	private func nextHeaderToken(in bytes: [UInt8], index: inout Int) throws -> String {
		while index < bytes.count {
			if isWhitespace(bytes[index]) {
				index += 1
				continue
			}
			if bytes[index] == 35 {
				while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
				continue
			}
			break
		}
		let start = index
		while index < bytes.count, isWhitespace(bytes[index]) == false, bytes[index] != 35 { index += 1 }
		guard start < index, let token = String(bytes: bytes[start..<index], encoding: .ascii) else {
			throw FixtureError.invalidPortablePixmap(Self.canvasName)
		}
		return token
	}

	private func isWhitespace(_ byte: UInt8) -> Bool {
		byte == 9 || byte == 10 || byte == 13 || byte == 32
	}

	private func checkedProduct(_ left: Int, _ right: Int, _ multiplier: Int) throws -> Int {
		let (product, overflow) = left.multipliedReportingOverflow(by: right)
		let (result, resultOverflow) = product.multipliedReportingOverflow(by: multiplier)
		guard overflow == false, resultOverflow == false else { throw FixtureError.invalidPortablePixmap(Self.canvasName) }
		return result
	}

	// MARK: - Vision

	private func detect(
		image: CGImage,
		compiledModel: URL,
		computeUnits: MLComputeUnits,
		geometry: NativeModelImageSizing.Geometry
	) throws -> [Detection] {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = computeUnits
		let model = try MLModel(contentsOf: compiledModel, configuration: configuration)
		return try detect(image: image, model: model, geometry: geometry)
	}

	private func detect(
		image: CGImage,
		model: MLModel,
		geometry: NativeModelImageSizing.Geometry
	) throws -> [Detection] {
		let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
		request.imageCropAndScaleOption = .scaleFill
		try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
		let observations = try XCTUnwrap(
			request.results as? [VNRecognizedObjectObservation],
			"The converted artifact must expose Vision detector observations."
		)
		return observations.compactMap { observation in
			guard let sourceBox = geometry.sourceBox(fromCanvasBox: NativeModelNormalizedRect(
				x: Double(observation.boundingBox.origin.x),
				y: Double(observation.boundingBox.origin.y),
				width: Double(observation.boundingBox.width),
				height: Double(observation.boundingBox.height)
			)) else { return nil }
			let width = Double(geometry.sourceSize.width)
			let height = Double(geometry.sourceSize.height)
			return Detection(
				box: [
					sourceBox.x * width,
					(1 - sourceBox.y - sourceBox.height) * height,
					(sourceBox.x + sourceBox.width) * width,
					(1 - sourceBox.y) * height
				],
				score: Double(observation.confidence)
			)
		}
	}

	private func makeImage(rgb: [UInt8], width: Int, height: Int) throws -> CGImage {
		let pixels = try checkedProduct(width, height, 1)
		let rgbByteCount = try checkedProduct(width, height, 3)
		guard rgb.count == rgbByteCount else { throw FixtureError.invalidPortablePixmap(Self.canvasName) }
		var bgra = [UInt8](repeating: 255, count: try checkedProduct(width, height, 4))
		for pixel in 0..<pixels {
			bgra[pixel * 4] = rgb[pixel * 3 + 2]
			bgra[pixel * 4 + 1] = rgb[pixel * 3 + 1]
			bgra[pixel * 4 + 2] = rgb[pixel * 3]
		}
		let data = Data(bgra)
		let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
		return try XCTUnwrap(CGImage(
			width: width,
			height: height,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		))
	}

	private func makeBlankImage(size: NativeModelImageSize) throws -> CGImage {
		let pixels = try checkedProduct(size.width, size.height, 1)
		let planar = (0..<3).flatMap { channel in
			Array(repeating: NativeModelImageSizing.imageNetMeanPixels[channel], count: pixels)
		}
		let bgra = try XCTUnwrap(NativeModelImageSizing.interleavedBGRA(from: planar, size: size))
		var rgb = [UInt8](repeating: 0, count: try checkedProduct(size.width, size.height, 3))
		for pixel in 0..<pixels {
			rgb[pixel * 3] = bgra[pixel * 4 + 2]
			rgb[pixel * 3 + 1] = bgra[pixel * 4 + 1]
			rgb[pixel * 3 + 2] = bgra[pixel * 4]
		}
		return try makeImage(rgb: rgb, width: size.width, height: size.height)
	}

	// MARK: - Comparison

	private struct Comparison {
		let matched: Int
		let disappeared: [Detection]
		let appeared: [Detection]
		let maximumBoxShift: Double?
		let maximumScoreDelta: Double?
	}

	/// One-to-one greedy IoU matching, mirroring the oracle's `compare()` so appeared and
	/// disappeared detections stay visible instead of hiding inside an aggregate error.
	private func measure(_ candidate: [Detection], reference: [Detection], matchIoU: Double) -> Comparison {
		var available = Set(candidate.indices)
		var shifts: [Double] = []
		var deltas: [Double] = []
		var matched = 0
		var disappeared: [Detection] = []
		for expected in reference {
			let match = available.max { left, right in
				iou(expected.box, candidate[left].box) < iou(expected.box, candidate[right].box)
			}
			guard let match, iou(expected.box, candidate[match].box) >= matchIoU else {
				disappeared.append(expected)
				continue
			}
			available.remove(match)
			matched += 1
			shifts.append(boxShift(expected.box, candidate[match].box))
			deltas.append(abs(expected.score - candidate[match].score))
		}
		return Comparison(
			matched: matched,
			disappeared: disappeared,
			appeared: available.map { candidate[$0] },
			maximumBoxShift: shifts.max(),
			maximumScoreDelta: deltas.max()
		)
	}

	private func assertOracleBudgets(
		_ comparison: Comparison,
		referenceCount: Int,
		rule: Rule,
		computeUnits: MLComputeUnits,
		systemVersion: String
	) {
		let label = computeUnits.label
		XCTAssertTrue(
			comparison.disappeared.isEmpty && comparison.appeared.isEmpty,
			"\(label) changed the torchvision detection set: \(comparison.disappeared.count) disappeared, "
				+ "\(comparison.appeared.count) appeared"
		)
		XCTAssertLessThanOrEqual(
			comparison.maximumBoxShift ?? .infinity,
			rule.maxBoxShiftPixels,
			"\(label) box shift \(describe(comparison.maximumBoxShift)) exceeds \(rule.maxBoxShiftPixels) px"
		)
		XCTAssertLessThanOrEqual(
			comparison.maximumScoreDelta ?? .infinity,
			rule.maxScoreDelta,
			"\(label) score delta \(describe(comparison.maximumScoreDelta)) exceeds \(rule.maxScoreDelta)"
		)
		print(
			"[AIA-0688] \(systemVersion) \(label): \(comparison.matched)/\(referenceCount) detections matched, "
				+ "max box shift \(describe(comparison.maximumBoxShift)) px, "
				+ "max score delta \(describe(comparison.maximumScoreDelta))"
		)
	}

	/// Records what an excluded placement actually did, without asserting a budget on it.
	///
	/// Reporting rather than asserting is deliberate. The numbers below are hardware- and
	/// OS-specific; pinning them as expectations would turn a phone swap into a red test that says
	/// nothing useful. The caller asserts the structural invariants and the tripwire instead.
	private func reportDivergence(
		_ comparison: Comparison,
		referenceCount: Int,
		reference: String,
		computeUnits: MLComputeUnits,
		systemVersion: String
	) {
		print(
			"[AIA-0688] \(systemVersion) \(computeUnits.label) vs \(reference): "
				+ "\(comparison.matched)/\(referenceCount) detections matched, "
				+ "max box shift \(describe(comparison.maximumBoxShift)) px, "
				+ "max score delta \(describe(comparison.maximumScoreDelta))"
		)
	}

	private func describe(_ value: Double?) -> String {
		guard let value else { return "none" }
		return "\(value)"
	}

	private func iou(_ left: [Double], _ right: [Double]) -> Double {
		let x0 = max(left[0], right[0])
		let y0 = max(left[1], right[1])
		let x1 = min(left[2], right[2])
		let y1 = min(left[3], right[3])
		let intersection = max(0, x1 - x0) * max(0, y1 - y0)
		let leftArea = max(0, left[2] - left[0]) * max(0, left[3] - left[1])
		let rightArea = max(0, right[2] - right[0]) * max(0, right[3] - right[1])
		let union = leftArea + rightArea - intersection
		return union > 0 ? intersection / union : 0
	}

	private func boxShift(_ left: [Double], _ right: [Double]) -> Double {
		zip(left, right).map { abs($0 - $1) }.max() ?? .infinity
	}
}

private extension MLComputeUnits {
	var label: String {
		switch self {
		case .cpuOnly: "cpuOnly"
		case .cpuAndGPU: "cpuAndGPU"
		case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
		case .all: "all"
		@unknown default: "unknown"
		}
	}
}

private struct Fixture: Decodable {
	let sourceSize: Size
	let canvasSize: Size
	let reference: [Detection]
	let rule: Rule
}

private struct Size: Decodable {
	let width: Int
	let height: Int
}

private struct Rule: Decodable {
	let matchIoU: Double
	let maxBoxShiftPixels: Double
	let maxScoreDelta: Double

	enum CodingKeys: String, CodingKey {
		case matchIoU = "match_iou"
		case maxBoxShiftPixels = "max_box_shift_px"
		case maxScoreDelta = "max_score_delta"
	}
}

private struct Detection: Decodable {
	let box: [Double]
	let score: Double
}

private struct PortablePixmap {
	let rgb: [UInt8]
	let width: Int
	let height: Int
}

private enum FixtureError: LocalizedError {
	case invalidPortablePixmap(String)

	var errorDescription: String? {
		switch self {
		case .invalidPortablePixmap(let name): "Invalid PPM fixture: \(name)"
		}
	}
}
