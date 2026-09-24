//
//  DetectionTilingTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 12.06.26.
//

import XCTest
import UIKit
import SwiftUI
@testable import ML_Browser

// MARK: - TileLayout region tests

final class TileLayoutRegionsTests: XCTestCase {

	func testRegions_Empty_IsSingleFullFrame() {
		XCTAssertEqual(TileLayout.regions(for: []), [TileLayout.fullFrame])
	}

	func testRegions_Pyramid_HasSixRegions() {
		XCTAssertEqual(TileLayout.regions(for: .pyramid).count, 6)
	}

	func testRegions_Pyramid_QuadrantsTileTheUnitSquare() {
		let quadrants = TileLayout.regions(for: .pyramid).prefix(4)
		// Four half-size regions, disjoint, summing to the full area = an exact tiling.
		let totalArea = quadrants.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
		XCTAssertEqual(totalArea, 1.0, accuracy: 0.0001)
		for (index, lhs) in quadrants.enumerated() {
			XCTAssertEqual(lhs.size, CGSize(width: 0.5, height: 0.5))
			XCTAssertTrue(TileLayout.fullFrame.contains(lhs))
			for rhs in quadrants.dropFirst(index + 1) {
				let overlap = lhs.intersection(rhs)
				XCTAssertEqual(overlap.width * overlap.height, 0)
			}
		}
	}

	func testRegions_Pyramid_FifthIsCenteredHalfSize() {
		let center = TileLayout.regions(for: .pyramid)[4]
		XCTAssertEqual(center, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
	}

	func testRegions_Pyramid_LastIsFullFrame() {
		// The full-frame pass protects artifacts larger than any half-size region.
		XCTAssertEqual(TileLayout.regions(for: .pyramid).last, TileLayout.fullFrame)
	}

	// MARK: - 3x3 (AIA-0426)

	func testRegions_Grid3x3_HasTenRegions() {
		// 9 grid cells + 1 full-frame pass.
		XCTAssertEqual(TileLayout.regions(for: .grid3x3).count, 10)
	}

	func testRegions_Grid3x3_NineCellsTileTheUnitSquare() {
		let cells = TileLayout.regions(for: .grid3x3).prefix(9)
		// Nine ninth-size cells, disjoint, summing to the full area = an exact tiling.
		let totalArea = cells.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
		XCTAssertEqual(totalArea, 1.0, accuracy: 0.0001)
		for (index, lhs) in cells.enumerated() {
			XCTAssertEqual(lhs.width, 1.0 / 3.0, accuracy: 0.0001)
			XCTAssertEqual(lhs.height, 1.0 / 3.0, accuracy: 0.0001)
			XCTAssertTrue(TileLayout.fullFrame.contains(lhs))
			for rhs in cells.dropFirst(index + 1) {
				let overlap = lhs.intersection(rhs)
				XCTAssertEqual(overlap.width * overlap.height, 0, accuracy: 0.0001)
			}
		}
	}

	func testRegions_Grid3x3_LastIsFullFrame() {
		XCTAssertEqual(TileLayout.regions(for: .grid3x3).last, TileLayout.fullFrame)
	}

	// MARK: - Union + fallbacks

	func testRegions_Union_HasFifteenUniqueRegions() {
		// 6 (pyramid) + 10 (grid) − 1 shared full frame = 15.
		XCTAssertEqual(TileLayout.regions(for: [.pyramid, .grid3x3]).count, 15)
	}

	func testRegions_Union_PreservesPyramidOrderAndItsFullFrame() {
		// Pyramid stays first so regionIndex 0…5 is byte-identical to a pyramid-only run, and the
		// surviving full frame is pyramid's (index 5) — the grid's duplicate is deduped out.
		let union = TileLayout.regions(for: [.pyramid, .grid3x3])
		XCTAssertEqual(Array(union.prefix(6)), TileLayout.pyramidRegions)
		XCTAssertEqual(union[5], TileLayout.fullFrame)
		// Exactly one full frame survives across the whole union.
		XCTAssertEqual(union.filter { $0 == TileLayout.fullFrame }.count, 1)
	}

	func testRegions_UnknownBitsOnly_FallsBackToFullFrame() {
		// Future-proofing: a non-empty set with only unknown bits must fall back to the full frame,
		// never zero passes. (The current data flow only ever produces {pyramid, grid3x3}.)
		let unknown = TilingScheme(rawValue: 1 << 4)
		XCTAssertEqual(TileLayout.regions(for: unknown), [TileLayout.fullFrame])
	}
}

// MARK: - TileBorderOverlay transform (AIA-0426)

@MainActor
final class TileBorderOverlayTests: XCTestCase {

	func testScreenRect_FullFrame_FillsTheView() {
		let rect = TileBorderOverlay.screenRect(for: TileLayout.fullFrame, in: CGSize(width: 100, height: 200))
		XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 100, height: 200))
	}

	func testScreenRect_BottomLeftVisionQuadrant_MapsToLowerHalfInSwiftUI() {
		// Vision uses a bottom-left origin: (0,0,0.5,0.5) is the BOTTOM-left quadrant, which must map
		// to the LOWER half of SwiftUI's top-left coordinate space (y flips).
		let rect = TileBorderOverlay.screenRect(
			for: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
			in: CGSize(width: 100, height: 100)
		)
		XCTAssertEqual(rect, CGRect(x: 0, y: 50, width: 50, height: 50))
	}

	func testScreenRect_TopRightVisionQuadrant_MapsToTopRightInSwiftUI() {
		// Vision (0.5,0.5,0.5,0.5) is the TOP-right quadrant → SwiftUI top-right.
		let rect = TileBorderOverlay.screenRect(
			for: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
			in: CGSize(width: 100, height: 100)
		)
		XCTAssertEqual(rect, CGRect(x: 50, y: 0, width: 50, height: 50))
	}
}

// MARK: - Remap tests

final class TileLayoutRemapTests: XCTestCase {

	func testRemap_FullFrame_IsIdentity() {
		let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
		XCTAssertEqual(TileLayout.remap(box, into: TileLayout.fullFrame), box)
	}

	func testRemap_CornerRegion_OffsetsAndScales() throws {
		// Top-right quadrant in Vision coordinates (bottom-left origin).
		let region = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
		let box = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
		let remapped = try XCTUnwrap(TileLayout.remap(box, into: region))
		XCTAssertEqual(remapped.minX, 0.75, accuracy: 0.0001)
		XCTAssertEqual(remapped.minY, 0.75, accuracy: 0.0001)
		XCTAssertEqual(remapped.width, 0.1, accuracy: 0.0001)
		XCTAssertEqual(remapped.height, 0.1, accuracy: 0.0001)
	}

	func testRemap_CenterRegion_OffsetsByQuarter() throws {
		let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let remapped = try XCTUnwrap(TileLayout.remap(CGRect(x: 0, y: 0, width: 1, height: 1), into: region))
		XCTAssertEqual(remapped, region)
	}

	func testRemap_ClampsToUnitRect() throws {
		// A box reported slightly past the region edge must clamp, not leak past 1.
		let region = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
		let box = CGRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3)
		let remapped = try XCTUnwrap(TileLayout.remap(box, into: region))
		XCTAssertLessThanOrEqual(remapped.maxX, 1.0)
		XCTAssertLessThanOrEqual(remapped.maxY, 1.0)
		XCTAssertGreaterThan(remapped.width, 0)
		XCTAssertGreaterThan(remapped.height, 0)
	}

	func testRemap_RejectsNonFiniteBox() {
		let box = CGRect(x: CGFloat.nan, y: 0, width: 0.1, height: 0.1)
		XCTAssertNil(TileLayout.remap(box, into: TileLayout.fullFrame))
	}

	func testRemap_RejectsBoxOutsideUnitRect() {
		let box = CGRect(x: 2.5, y: 2.5, width: 0.1, height: 0.1)
		XCTAssertNil(TileLayout.remap(box, into: TileLayout.fullFrame))
	}

	func testRemap_RejectsEmptyBox() {
		let box = CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
		XCTAssertNil(TileLayout.remap(box, into: TileLayout.fullFrame))
	}
}

// MARK: - Dedup tests

final class TileLayoutDedupTests: XCTestCase {

	private func object(
		label: String = "artifact",
		confidence: Float,
		box: CGRect,
		region: Int
	) -> DetectedObject {
		DetectedObject(
			uuid: UUID(),
			labels: [DetectedObject.Label(identifier: label, confidence: confidence)],
			confidence: confidence,
			boundingBox: box,
			regionIndex: region
		)
	}

	func testDedup_ClippedHigherConfidenceBox_LosesToContainingFullBox() {
		// A quadrant clips the artifact to a partial box
		// with HIGHER confidence; the center region sees the full box. Geometry must win.
		let regions = TileLayout.pyramidRegions
		let clipped = object(confidence: 0.95, box: CGRect(x: 0.45, y: 0.4, width: 0.05, height: 0.1), region: 0)
		let full = object(confidence: 0.6, box: CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.2), region: 5)

		for input in [[clipped, full], [full, clipped]] {
			let result = TileLayout.dedupAcrossRegions(input, regions: regions)
			XCTAssertEqual(result.map(\.uuid), [full.uuid])
		}
	}

	func testDedup_NestedInteriorBoxInDifferentRegion_IsKept() {
		// Regression for AIA-0702: the zoomed tile found a genuinely smaller feature
		// inside a larger full-frame detection. It is not a tile-boundary partial.
		let nested = object(confidence: 0.95, box: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), region: 0)
		let enclosing = object(confidence: 0.6, box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), region: 1)

		let regions = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), TileLayout.fullFrame]
		let result = TileLayout.dedupAcrossRegions([nested, enclosing], regions: regions)

		XCTAssertEqual(Set(result.map(\.uuid)), Set([nested.uuid, enclosing.uuid]))
	}

	func testDedup_NestedBoxAgainstOwnRegionEdge_IsDropped() {
		let regions = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), TileLayout.fullFrame]
		let clipped = object(confidence: 0.95, box: CGRect(x: 0.45, y: 0.2, width: 0.05, height: 0.1), region: 0)
		let enclosing = object(confidence: 0.6, box: CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.3), region: 1)

		let result = TileLayout.dedupAcrossRegions([clipped, enclosing], regions: regions)

		XCTAssertEqual(result.map(\.uuid), [enclosing.uuid])
	}

	func testDedup_BoxAtImageEdgeInFullFrame_IsKept() {
		let regions = [TileLayout.fullFrame, CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]
		let imageEdgeBox = object(confidence: 0.95, box: CGRect(x: 0, y: 0.2, width: 0.05, height: 0.1), region: 0)
		let enclosing = object(confidence: 0.6, box: CGRect(x: 0, y: 0.1, width: 0.3, height: 0.3), region: 1)

		let result = TileLayout.dedupAcrossRegions([imageEdgeBox, enclosing], regions: regions)

		XCTAssertEqual(Set(result.map(\.uuid)), Set([imageEdgeBox.uuid, enclosing.uuid]))
	}

	func testDedup_SeveralNestedInteriorBoxes_AreAllKept() {
		let regions = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), TileLayout.fullFrame]
		let enclosing = object(confidence: 0.6, box: CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.4), region: 1)
		let first = object(confidence: 0.9, box: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05), region: 0)
		let second = object(confidence: 0.8, box: CGRect(x: 0.2, y: 0.2, width: 0.05, height: 0.05), region: 0)
		let third = object(confidence: 0.7, box: CGRect(x: 0.3, y: 0.3, width: 0.05, height: 0.05), region: 0)

		let result = TileLayout.dedupAcrossRegions([enclosing, first, second, third], regions: regions)

		XCTAssertEqual(Set(result.map(\.uuid)), Set([enclosing.uuid, first.uuid, second.uuid, third.uuid]))
	}

	func testDedup_SingleClassMultiTileNestedDetections_AllSurvive() {
		let regions = TileLayout.pyramidRegions
		let fullFrame = object(confidence: 0.6, box: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), region: 5)
		let bottomLeft = object(confidence: 0.9, box: CGRect(x: 0.15, y: 0.15, width: 0.05, height: 0.05), region: 0)
		let bottomRight = object(confidence: 0.8, box: CGRect(x: 0.65, y: 0.15, width: 0.05, height: 0.05), region: 1)
		let topLeft = object(confidence: 0.7, box: CGRect(x: 0.15, y: 0.65, width: 0.05, height: 0.05), region: 2)
		let topRight = object(confidence: 0.65, box: CGRect(x: 0.65, y: 0.65, width: 0.05, height: 0.05), region: 3)
		let input = [fullFrame, bottomLeft, bottomRight, topLeft, topRight]

		let result = TileLayout.dedupAcrossRegions(input, regions: regions)

		XCTAssertEqual(Set(result.map(\.uuid)), Set(input.map(\.uuid)))
	}

	func testDedup_ClippedAndNestedInputOrder_DoesNotChangeSurvivors() {
		let regions = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), TileLayout.fullFrame]
		let enclosing = object(confidence: 0.6, box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), region: 1)
		let clipped = object(confidence: 0.95, box: CGRect(x: 0.45, y: 0.2, width: 0.05, height: 0.1), region: 0)
		let nested = object(confidence: 0.8, box: CGRect(x: 0.25, y: 0.25, width: 0.05, height: 0.05), region: 0)
		let expected = Set([enclosing.uuid, nested.uuid])

		for input in [[enclosing, clipped, nested], [nested, enclosing, clipped], [clipped, nested, enclosing]] {
			XCTAssertEqual(Set(TileLayout.dedupAcrossRegions(input, regions: regions).map(\.uuid)), expected)
		}
	}

	func testDedup_NearIdenticalCrossRegionBoxes_KeepsHigherConfidence() {
		let weaker = object(confidence: 0.5, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), region: 0)
		let stronger = object(confidence: 0.9, box: CGRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), region: 4)

		for input in [[weaker, stronger], [stronger, weaker]] {
			let result = TileLayout.dedupAcrossRegions(input, regions: TileLayout.pyramidRegions)
			XCTAssertEqual(result.map(\.uuid), [stronger.uuid])
		}
	}

	func testDedup_SameRegionBoxes_AreNeverSuppressed() {
		// Within one region the model's own suppression already ruled.
		let first = object(confidence: 0.9, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), region: 0)
		let second = object(confidence: 0.5, box: CGRect(x: 0.41, y: 0.41, width: 0.18, height: 0.18), region: 0)

		let result = TileLayout.dedupAcrossRegions([first, second], regions: [TileLayout.fullFrame])
		XCTAssertEqual(Set(result.map(\.uuid)), Set([first.uuid, second.uuid]))
	}

	func testDedup_DifferentLabels_AreNeverSuppressed() {
		let lidar = object(label: "lidar", confidence: 0.9, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), region: 0)
		let mound = object(label: "mound", confidence: 0.5, box: CGRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), region: 4)

		let result = TileLayout.dedupAcrossRegions([lidar, mound], regions: TileLayout.pyramidRegions)
		XCTAssertEqual(Set(result.map(\.uuid)), Set([lidar.uuid, mound.uuid]))
	}

	func testDedup_DistantSameLabelBoxes_AreKept() {
		// Two genuinely distinct artifacts of the same class must both survive.
		let left = object(confidence: 0.8, box: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1), region: 0)
		let right = object(confidence: 0.7, box: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), region: 3)

		let result = TileLayout.dedupAcrossRegions([left, right], regions: TileLayout.pyramidRegions)
		XCTAssertEqual(Set(result.map(\.uuid)), Set([left.uuid, right.uuid]))
	}

	func testDedup_UnlabeledBoxes_AreNeverSuppressed() {
		// nil == nil must not make two unlabeled cross-region detections compete.
		let first = DetectedObject(
			uuid: UUID(), labels: [], confidence: 0.9,
			boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), regionIndex: 0
		)
		let second = DetectedObject(
			uuid: UUID(), labels: [], confidence: 0.5,
			boundingBox: CGRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), regionIndex: 4
		)

		let result = TileLayout.dedupAcrossRegions([first, second], regions: TileLayout.pyramidRegions)
		XCTAssertEqual(Set(result.map(\.uuid)), Set([first.uuid, second.uuid]))
	}

	func testDedup_SingleObject_PassesThrough() {
		let only = object(confidence: 0.4, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), region: 5)
		XCTAssertEqual(TileLayout.dedupAcrossRegions([only], regions: TileLayout.pyramidRegions).map(\.uuid), [only.uuid])
	}
}

// MARK: - Geometry helper tests

final class TileLayoutGeometryTests: XCTestCase {

	func testIntersectionOverUnion_Identical_IsOne() {
		let rect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
		XCTAssertEqual(TileLayout.intersectionOverUnion(rect, rect), 1.0, accuracy: 0.0001)
	}

	func testIntersectionOverUnion_Disjoint_IsZero() {
		let lhs = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
		let rhs = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
		XCTAssertEqual(TileLayout.intersectionOverUnion(lhs, rhs), 0)
	}

	func testContainment_InnerFullyInsideOuter_IsOne() {
		let outer = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
		let inner = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
		XCTAssertEqual(TileLayout.containment(of: inner, in: outer), 1.0, accuracy: 0.0001)
	}

	func testContainment_EmptyInner_IsZero() {
		let outer = CGRect(x: 0, y: 0, width: 1, height: 1)
		XCTAssertEqual(TileLayout.containment(of: .zero, in: outer), 0)
	}
}

// MARK: - SnapshotDetectionQueue tests

private extension QueuedSnapshot {
	/// These tests are about ordering, not provenance (AIA-0846 covers that in DetectionCoordinatorTests).
	init(_ image: UIImage) {
		self.init(image: image, provenance: .unknown)
	}
}

@MainActor
final class SnapshotDetectionQueueTests: XCTestCase {

	func testEnqueue_WhileIdle_StartsImmediately() {
		let queue = SnapshotDetectionQueue()
		var started: [UIImage] = []
		let image = UIImage()

		queue.enqueue(QueuedSnapshot(image)) { snapshot, _ in started.append(snapshot.image) }

		XCTAssertEqual(started, [image])
		XCTAssertTrue(queue.inFlight)
	}

	func testEnqueue_WhileInFlight_CoalescesToNewest() {
		let queue = SnapshotDetectionQueue()
		var started: [UIImage] = []
		var completions: [@MainActor () -> Void] = []
		let pass: SnapshotDetectionQueue.Pass = { snapshot, done in
			started.append(snapshot.image)
			completions.append(done)
		}
		let first = UIImage()
		let second = UIImage()
		let third = UIImage()

		queue.enqueue(QueuedSnapshot(first), pass: pass)
		queue.enqueue(QueuedSnapshot(second), pass: pass)
		queue.enqueue(QueuedSnapshot(third), pass: pass)
		// Only the first pass ran; the middle snapshot was coalesced away.
		XCTAssertEqual(started, [first])

		completions[0]()
		XCTAssertEqual(started, [first, third])

		completions[1]()
		XCTAssertEqual(started, [first, third])
		XCTAssertFalse(queue.inFlight)
	}

	func testCancelPending_DropsCoalescedSnapshot() {
		let queue = SnapshotDetectionQueue()
		var started: [UIImage] = []
		var completions: [@MainActor () -> Void] = []
		let pass: SnapshotDetectionQueue.Pass = { snapshot, done in
			started.append(snapshot.image)
			completions.append(done)
		}

		queue.enqueue(QueuedSnapshot(UIImage()), pass: pass)
		queue.enqueue(QueuedSnapshot(UIImage()), pass: pass)
		queue.cancelPending()
		completions[0]()

		XCTAssertEqual(started.count, 1)
		XCTAssertFalse(queue.inFlight)
	}
}

// MARK: - The one label a detection shows and saves (AIA-0765)

@MainActor
final class DetectionPrimaryLabelTests: XCTestCase {

	private func object(_ labels: [(String, Float)]) -> DetectedObject {
		DetectedObject(
			uuid: UUID(),
			labels: labels.map { DetectedObject.Label(identifier: $0.0, confidence: $0.1) },
			confidence: 0.5,
			boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			regionIndex: 0
		)
	}

	func testPrimaryLabel_IsVisionsBestFirstEntry() {
		let subject = object([("ship", 0.77), ("boat", 0.31)])
		XCTAssertEqual(subject.primaryLabel?.identifier, "ship")
		XCTAssertEqual(subject.primaryLabel?.confidence, 0.77)
	}

	/// The screen, the dedup stage and the saved finding must name the *same* class. This pins them
	/// to one accessor: a view that re-derived "the best label" by scanning for the maximum would
	/// disagree with `FindingRepository` here, on any input where the order and the maximum differ.
	func testPrimaryLabel_AgreesWithTheIdentifierUsedForDedupAndSavedFindings() {
		let subject = object([("ship", 0.42), ("boat", 0.91)])
		XCTAssertEqual(subject.primaryLabel?.identifier, subject.primaryLabelIdentifier)
		XCTAssertEqual(subject.primaryLabel?.identifier, "ship")
	}

	func testPrimaryLabel_UnlabeledObservation_HasNone() {
		XCTAssertNil(object([]).primaryLabel)
		XCTAssertNil(object([]).primaryLabelIdentifier)
	}

	func testLabelText_IsClassNameAndConfidenceToTwoPlaces() {
		XCTAssertEqual(DetectionLabelView.text(identifier: "ship", confidence: 0.7712), "ship 0.77")
	}

	/// The label must show the **detection** score, never the class probability. A single-class
	/// detector reports every label at 1.0, so drawing `Label.confidence` made every annotation
	/// read "1.00" however weak the detection was -- the symptom that found this.
	func testLabelText_ShowsTheDetectionScoreNotTheDegenerateClassProbability() {
		let subject = DetectedObject(
			uuid: UUID(),
			labels: [DetectedObject.Label(identifier: "f3", confidence: 1.0)],
			confidence: 0.42,
			boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			regionIndex: 0
		)
		let identifier = subject.primaryLabel?.identifier ?? ""
		XCTAssertEqual(DetectionLabelView.text(identifier: identifier, confidence: subject.confidence), "f3 0.42")
	}

	/// The number on screen and the number the user's confidence threshold acts on must be the same
	/// one, or a threshold of 0.5 admits detections whose labels claim something else.
	func testLabelConfidence_IsTheFieldTheConfidenceFilterUses() {
		let weak = DetectedObject(
			uuid: UUID(),
			labels: [DetectedObject.Label(identifier: "f3", confidence: 1.0)],
			confidence: 0.2,
			boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			regionIndex: 0
		)
		// `DetectionPresentation.filteredResults` compares `observation.confidence` to the
		// threshold, so that is the field a label has to report.
		XCTAssertEqual(weak.confidence, 0.2)
		XCTAssertNotEqual(weak.primaryLabel?.confidence, weak.confidence)
	}

	/// Guards the decimal separator. `String(format:)` takes no locale and so always emits a dot;
	/// the `formatted()` this replaced is locale-aware and renders `0,77` wherever the separator is
	/// a comma — which, next to an unlocalized class identifier, reads as a second field rather than
	/// a decimal. A non-ASCII identifier is used to show the class name itself is passed through.
	func testLabelText_SeparatesTheConfidenceWithADotNotAComma() {
		let text = DetectionLabelView.text(identifier: "loď", confidence: 0.5)
		XCTAssertEqual(text, "loď 0.50")
		XCTAssertFalse(text.contains(","))
	}

	// MARK: Label legibility on a user-chosen annotation colour

	/// The annotation colour is a user preference with no bounds, so no fixed text colour is
	/// readable across it. These pin the two ends and the awkward middle.
	func testLegibleForeground_PicksBlackOnLightAnnotationColours() {
		XCTAssertEqual(DetectionLabelView.legibleForeground(on: .yellow), .black)
		XCTAssertEqual(DetectionLabelView.legibleForeground(on: .white), .black)
	}

	func testLegibleForeground_PicksWhiteOnDarkAnnotationColours() {
		XCTAssertEqual(DetectionLabelView.legibleForeground(on: .black), .white)
		XCTAssertEqual(DetectionLabelView.legibleForeground(on: Color(red: 0, green: 0, blue: 0.4)), .white)
	}

	/// The reported case: a mid pink. Whichever way this resolves, the choice must clear the WCAG
	/// 4.5:1 ratio for normal text -- the assertion is on the contrast, not on the colour, so it
	/// stays meaningful if the threshold logic is ever retuned.
	func testLegibleForeground_MidTonePinkStillClearsTheReadableContrastRatio() {
		let pink = Color(red: 1, green: 0.41, blue: 0.71)
		guard let luminance = DetectionLabelView.relativeLuminance(of: pink) else {
			return XCTFail("a plain sRGB colour must expose its components")
		}
		let chosen = DetectionLabelView.legibleForeground(on: pink)
		let ratio = chosen == .black
			? (luminance + 0.05) / 0.05
			: 1.05 / (luminance + 0.05)
		XCTAssertGreaterThan(ratio, 4.5, "label text must stay readable on the user's annotation colour")
	}

	func testRelativeLuminance_OrdersColoursByPerceivedBrightness() {
		let white = DetectionLabelView.relativeLuminance(of: .white)
		let pink = DetectionLabelView.relativeLuminance(of: Color(red: 1, green: 0.41, blue: 0.71))
		let black = DetectionLabelView.relativeLuminance(of: .black)
		XCTAssertEqual(white ?? -1, 1, accuracy: 0.01)
		XCTAssertEqual(black ?? -1, 0, accuracy: 0.01)
		XCTAssertGreaterThan(pink ?? -1, black ?? -1)
		XCTAssertLessThan(pink ?? 2, white ?? 2)
	}
}
