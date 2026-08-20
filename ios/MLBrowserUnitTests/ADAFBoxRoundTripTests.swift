//
//  ADAFBoxRoundTripTests.swift
//  MLBrowserUnitTests
//
//  AIA-0680, acceptance criteria 3 and 5: a detected box has to come back out through the whole
//  chain — region crop, resize, pad, and `TileLayout.remap` — and land where it started.
//
//  A round trip on its own is weak evidence and this file is built around that fact. If the forward
//  and inverse directions share a mistake, they cancel and the round trip passes while every box on
//  the page is displaced. The Y flip is the worst instance: a forward crop reading `region.minY` and
//  an inverse writing `pixelRect.minY` round-trip perfectly while mirroring the page. So the
//  assertions here lead with **one-way anchors** — production geometry compared against integers
//  torchvision produced, and a hand-computed crop rectangle with the arithmetic written out — and use
//  the round trip only as the composition check on top.
//

import XCTest
import UIKit
import NativeModelConverter
@testable import ML_Browser

final class ADAFBoxRoundTripTests: XCTestCase {

	// A page divisible by neither two nor three, so every tiling edge lands between pixels and the
	// rounding this test exists to pin actually happens.
	private static let pageWidth = 901
	private static let pageHeight = 1501
	private static let minSize = 800
	private static let maxSize = 1333
	private static let strideDivisible = 32

	/// Boxes are compared in page pixels, never normalised: a normalised tolerance means one thing on
	/// a 901-pixel page and something else on a 300-pixel region, and AIA-0680 declares a one-pixel
	/// displacement detectable. Float geometry lands near 1e-10, so this leaves a wide margin while
	/// staying far below the shift the mutation tests introduce.
	private static let pagePixelTolerance = 0.01

	private var frame: NativeModelImageSize {
		NativeModelImageSize(width: Self.pageWidth, height: Self.pageHeight)
	}

	private func normalized(_ rect: CGRect) -> NativeModelNormalizedRect {
		NativeModelNormalizedRect(
			x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)
		)
	}

	private func cgRect(_ rect: NativeModelNormalizedRect) -> CGRect {
		CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
	}

	// MARK: - One-way anchor: the crop rectangle

	/// Hand-computed, with the arithmetic in the comment rather than borrowed from the implementation.
	func testCropPlan_matchesAHandComputedPixelRectangle() throws {
		// Vision's bottom-left third of the page. `TileLayout.grid3x3Regions` really does produce this
		// rectangle — origin at y = 0 is the page BOTTOM.
		let region = NativeModelNormalizedRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1.0 / 3.0)
		let plan = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: region))
		//   left   = 0 · 901                = 0
		//   right  = (1/3) · 901 = 300.333  → 300
		//   top    = (1 − 1/3) · 1501 = 1000.667 → 1001   <- the flip
		//   bottom = (1 − 0) · 1501         = 1501
		XCTAssertEqual(plan.pixelRect.x, 0)
		XCTAssertEqual(plan.pixelRect.y, 1001)
		XCTAssertEqual(plan.pixelRect.width, 300)
		XCTAssertEqual(plan.pixelRect.height, 500)
	}

	/// The flip has a direction, and only comparing two regions proves which one.
	func testCropPlan_aHigherVisionRegionIsAHigherPlaceOnThePage() throws {
		let third = 1.0 / 3.0
		let bottom = try XCTUnwrap(NativeModelImageSizing.cropPlan(
			frame: frame, region: NativeModelNormalizedRect(x: 0, y: 0, width: third, height: third)
		))
		let top = try XCTUnwrap(NativeModelImageSizing.cropPlan(
			frame: frame, region: NativeModelNormalizedRect(x: 0, y: 2 * third, width: third, height: third)
		))
		XCTAssertLessThan(top.pixelRect.y, bottom.pixelRect.y, "Vision's y grows upward; a raster row index grows downward")
		XCTAssertEqual(top.pixelRect.y, 0, "the topmost third starts at raster row 0")
	}

	// MARK: - One-way anchor: the geometry the network sees

	/// Compared against the integers in the committed torchvision oracle, not against anything this
	/// codebase computed. A third of this page is 300×500, which `GeneralizedRCNNTransform` resizes to
	/// 800×1333 — `max_size` binding, not `min_size` — on a 800×1344 canvas.
	func testGeometry_forARealTileMatchesTorchvisionsOwnIntegers() throws {
		let region = NativeModelNormalizedRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1.0 / 3.0)
		let plan = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: region))
		let geometry = try XCTUnwrap(NativeModelImageSizing.geometry(
			source: NativeModelImageSize(width: plan.pixelRect.width, height: plan.pixelRect.height),
			minSize: Self.minSize, maxSize: Self.maxSize, strideDivisible: Self.strideDivisible
		))
		// 300×500, aspect 1.667 — just above 1333/800, so max_size binds:
		//   scale = min(800/300, 1333/500) = min(2.6667, 2.666) = 2.666
		//   resized = floor(300·2.666) × floor(500·2.666) = 799 × 1333
		//   canvas  = 800 × 1344
		XCTAssertEqual(geometry.resizedSize.width, 799)
		XCTAssertEqual(geometry.resizedSize.height, 1333)
		XCTAssertEqual(geometry.canvasSize.width, 800)
		XCTAssertEqual(geometry.canvasSize.height, 1344)
		XCTAssertEqual(geometry.padRight, 1)
		XCTAssertEqual(geometry.padBottom, 11)
		XCTAssertTrue(geometry.hasPerAxisScale, "300×500 does not scale equally on both axes")
	}

	// MARK: - The composition

	/// page → region crop → resize/pad → (a box arrives) → inverse → `TileLayout.remap` → page.
	func testRoundTrip_returnsABoxToThePageItCameFrom() throws {
		let third = 1.0 / 3.0
		let regions: [NativeModelNormalizedRect] = [
			NativeModelNormalizedRect(x: 0, y: 0, width: third, height: third),
			NativeModelNormalizedRect(x: third, y: third, width: third, height: third),
			NativeModelNormalizedRect(x: 2 * third, y: 2 * third, width: third, height: third),
			NativeModelNormalizedRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
		]
		let boxesInCrop: [NativeModelNormalizedRect] = [
			NativeModelNormalizedRect(x: 0.10, y: 0.10, width: 0.30, height: 0.20),
			NativeModelNormalizedRect(x: 0.55, y: 0.62, width: 0.25, height: 0.30),
			NativeModelNormalizedRect(x: 0.02, y: 0.03, width: 0.90, height: 0.90)
		]

		for region in regions {
			let plan = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: region))
			let geometry = try XCTUnwrap(NativeModelImageSizing.geometry(
				source: NativeModelImageSize(width: plan.pixelRect.width, height: plan.pixelRect.height),
				minSize: Self.minSize, maxSize: Self.maxSize, strideDivisible: Self.strideDivisible
			))

			for expected in boxesInCrop {
				// Forward: where this crop-relative box lands on the model's canvas.
				let onCanvas = try XCTUnwrap(geometry.canvasBox(fromSourceBox: expected))
				// Inverse: what the detect path would do with a box arriving at that position.
				let backInCrop = try XCTUnwrap(geometry.sourceBox(fromCanvasBox: onCanvas))
				// And out through the region, using the region the crop ACTUALLY covers.
				let onPage = try XCTUnwrap(
					TileLayout.remap(cgRect(backInCrop), into: cgRect(plan.effectiveRegion)),
					"remap rejected a box that came from inside the region"
				)
				// The same box mapped straight out, for comparison.
				let reference = try XCTUnwrap(TileLayout.remap(cgRect(expected), into: cgRect(plan.effectiveRegion)))

				XCTAssertEqual(
					Double(onPage.minX) * Double(Self.pageWidth), Double(reference.minX) * Double(Self.pageWidth),
					accuracy: Self.pagePixelTolerance, "x, region \(region)"
				)
				XCTAssertEqual(
					Double(onPage.minY) * Double(Self.pageHeight), Double(reference.minY) * Double(Self.pageHeight),
					accuracy: Self.pagePixelTolerance, "y, region \(region)"
				)
				XCTAssertEqual(
					Double(onPage.width) * Double(Self.pageWidth), Double(reference.width) * Double(Self.pageWidth),
					accuracy: Self.pagePixelTolerance, "width, region \(region)"
				)
				XCTAssertEqual(
					Double(onPage.height) * Double(Self.pageHeight), Double(reference.height) * Double(Self.pageHeight),
					accuracy: Self.pagePixelTolerance, "height, region \(region)"
				)
			}
		}
	}

	/// A detection touching the region's outer edge takes `TileLayout.remap`'s clamp branch
	/// (`DetectionTiling.swift:126-129`), which is a different code path from the common one and can
	/// introduce `CGRect.intersection` drift.
	func testRoundTrip_survivesABoxTouchingTheRegionEdge() throws {
		let third = 1.0 / 3.0
		let region = NativeModelNormalizedRect(x: 2 * third, y: 2 * third, width: third, height: third)
		let plan = try XCTUnwrap(NativeModelImageSizing.cropPlan(frame: frame, region: region))
		let geometry = try XCTUnwrap(NativeModelImageSizing.geometry(
			source: NativeModelImageSize(width: plan.pixelRect.width, height: plan.pixelRect.height),
			minSize: Self.minSize, maxSize: Self.maxSize, strideDivisible: Self.strideDivisible
		))
		// Flush against the crop's top-right corner.
		let edgeBox = NativeModelNormalizedRect(x: 0.7, y: 0.7, width: 0.3, height: 0.3)
		let onCanvas = try XCTUnwrap(geometry.canvasBox(fromSourceBox: edgeBox))
		let back = try XCTUnwrap(geometry.sourceBox(fromCanvasBox: onCanvas))
		let onPage = try XCTUnwrap(TileLayout.remap(cgRect(back), into: cgRect(plan.effectiveRegion)))

		XCTAssertLessThanOrEqual(onPage.maxX, 1.0 + 1e-9, "a clamped box must not leave the page")
		XCTAssertLessThanOrEqual(onPage.maxY, 1.0 + 1e-9)
		let reference = try XCTUnwrap(TileLayout.remap(cgRect(edgeBox), into: cgRect(plan.effectiveRegion)))
		XCTAssertEqual(
			Double(onPage.maxX) * Double(Self.pageWidth), Double(reference.maxX) * Double(Self.pageWidth),
			accuracy: Self.pagePixelTolerance
		)
	}

	// MARK: - Points are not pixels

	/// `UIImage+Extensions` returns the original image when its CIFilter chain fails, so the snapshot
	/// reaching `Detector.detect` has `scale == 1` on the happy path and 2 or 3 on the fallback. A crop
	/// planned from `UIImage.size` is therefore right most of the time and wrong by a whole screen
	/// scale factor the rest, which is exactly the failure that never shows up in a simulator run of
	/// the common case.
	func testCropPlan_isPlannedFromPixelsNotPoints() throws {
		let pixelWidth = 900
		let pixelHeight = 1500
		let scale: CGFloat = 3
		let format = UIGraphicsImageRendererFormat()
		format.scale = scale
		let image = UIGraphicsImageRenderer(
			size: CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale), format: format
		).image { context in
			UIColor.gray.setFill()
			context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale))
		}
		let cgImage = try XCTUnwrap(image.cgImage)
		XCTAssertEqual(cgImage.width, pixelWidth, "precondition: this image is 3× its point size")
		XCTAssertNotEqual(Int(image.size.width), cgImage.width, "precondition: points and pixels differ here")

		let region = NativeModelNormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
		let fromPixels = try XCTUnwrap(NativeModelImageSizing.cropPlan(
			frame: NativeModelImageSize(width: cgImage.width, height: cgImage.height), region: region
		))
		let fromPoints = try XCTUnwrap(NativeModelImageSizing.cropPlan(
			frame: NativeModelImageSize(width: Int(image.size.width), height: Int(image.size.height)), region: region
		))
		XCTAssertEqual(fromPixels.pixelRect.width, pixelWidth / 2)
		XCTAssertEqual(
			fromPoints.pixelRect.width, pixelWidth / Int(scale) / 2,
			"a points-based plan crops a third of the pixels it should — this assertion documents the trap"
		)
	}
}
