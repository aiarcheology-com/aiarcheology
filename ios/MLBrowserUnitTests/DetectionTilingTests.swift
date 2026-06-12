//
//  DetectionTilingTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 12.06.26.
//

import XCTest
import UIKit
@testable import ML_Browser

// MARK: - TileLayout region tests

final class TileLayoutRegionsTests: XCTestCase {

	func testRegions_Untiled_IsSingleFullFrame() {
		XCTAssertEqual(TileLayout.regions(tiled: false), [TileLayout.fullFrame])
	}

	func testRegions_Tiled_HasSixRegions() {
		XCTAssertEqual(TileLayout.regions(tiled: true).count, 6)
	}

	func testRegions_Tiled_QuadrantsTileTheUnitSquare() {
		let quadrants = TileLayout.regions(tiled: true).prefix(4)
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

	func testRegions_Tiled_FifthIsCenteredHalfSize() {
		let center = TileLayout.regions(tiled: true)[4]
		XCTAssertEqual(center, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
	}

	func testRegions_Tiled_LastIsFullFrame() {
		// The full-frame pass protects artifacts larger than any half-size region.
		XCTAssertEqual(TileLayout.regions(tiled: true).last, TileLayout.fullFrame)
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
		// The Codex round-1 failure case: a quadrant clips the artifact to a partial box
		// with HIGHER confidence; the center region sees the full box. Geometry must win.
		let clipped = object(confidence: 0.95, box: CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.1), region: 0)
		let full = object(confidence: 0.6, box: CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16), region: 4)

		for input in [[clipped, full], [full, clipped]] {
			let result = TileLayout.dedupAcrossRegions(input)
			XCTAssertEqual(result.map(\.uuid), [full.uuid])
		}
	}

	func testDedup_NearIdenticalCrossRegionBoxes_KeepsHigherConfidence() {
		let weaker = object(confidence: 0.5, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), region: 0)
		let stronger = object(confidence: 0.9, box: CGRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), region: 4)

		for input in [[weaker, stronger], [stronger, weaker]] {
			let result = TileLayout.dedupAcrossRegions(input)
			XCTAssertEqual(result.map(\.uuid), [stronger.uuid])
		}
	}

	func testDedup_SameRegionBoxes_AreNeverSuppressed() {
		// Within one region the model's own suppression already ruled.
		let first = object(confidence: 0.9, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), region: 0)
		let second = object(confidence: 0.5, box: CGRect(x: 0.41, y: 0.41, width: 0.18, height: 0.18), region: 0)

		let result = TileLayout.dedupAcrossRegions([first, second])
		XCTAssertEqual(Set(result.map(\.uuid)), Set([first.uuid, second.uuid]))
	}

	func testDedup_DifferentLabels_AreNeverSuppressed() {
		let lidar = object(label: "lidar", confidence: 0.9, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), region: 0)
		let mound = object(label: "mound", confidence: 0.5, box: CGRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), region: 4)

		let result = TileLayout.dedupAcrossRegions([lidar, mound])
		XCTAssertEqual(Set(result.map(\.uuid)), Set([lidar.uuid, mound.uuid]))
	}

	func testDedup_DistantSameLabelBoxes_AreKept() {
		// Two genuinely distinct artifacts of the same class must both survive.
		let left = object(confidence: 0.8, box: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1), region: 0)
		let right = object(confidence: 0.7, box: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), region: 3)

		let result = TileLayout.dedupAcrossRegions([left, right])
		XCTAssertEqual(Set(result.map(\.uuid)), Set([left.uuid, right.uuid]))
	}

	func testDedup_SingleObject_PassesThrough() {
		let only = object(confidence: 0.4, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), region: 5)
		XCTAssertEqual(TileLayout.dedupAcrossRegions([only]).map(\.uuid), [only.uuid])
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

@MainActor
final class SnapshotDetectionQueueTests: XCTestCase {

	func testEnqueue_WhileIdle_StartsImmediately() {
		let queue = SnapshotDetectionQueue()
		var started: [UIImage] = []
		let image = UIImage()

		queue.enqueue(image) { image, _ in started.append(image) }

		XCTAssertEqual(started, [image])
		XCTAssertTrue(queue.inFlight)
	}

	func testEnqueue_WhileInFlight_CoalescesToNewest() {
		let queue = SnapshotDetectionQueue()
		var started: [UIImage] = []
		var completions: [@MainActor () -> Void] = []
		let pass: SnapshotDetectionQueue.Pass = { image, done in
			started.append(image)
			completions.append(done)
		}
		let first = UIImage()
		let second = UIImage()
		let third = UIImage()

		queue.enqueue(first, pass: pass)
		queue.enqueue(second, pass: pass)
		queue.enqueue(third, pass: pass)
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
		let pass: SnapshotDetectionQueue.Pass = { image, done in
			started.append(image)
			completions.append(done)
		}

		queue.enqueue(UIImage(), pass: pass)
		queue.enqueue(UIImage(), pass: pass)
		queue.cancelPending()
		completions[0]()

		XCTAssertEqual(started.count, 1)
		XCTAssertFalse(queue.inFlight)
	}
}
