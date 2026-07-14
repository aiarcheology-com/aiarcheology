//
//  DetectionTiling.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 12.06.26.
//

import Foundation
import CoreGraphics

/// A single detection result in full-image normalized Vision coordinates.
///
/// Replaces `VNRecognizedObjectObservation` on the detect path: tiled detection (AIA-0217)
/// must remap region-relative bounding boxes into full-image space, and Vision observations
/// are neither mutable nor publicly constructible. A value type also crosses actors as a
/// real `Sendable` instead of an `@unchecked` Vision class.
struct DetectedObject: Sendable {
	/// `Hashable` because the annotation views iterate labels with `ForEach(_, id: \.self)`.
	struct Label: Sendable, Hashable {
		let identifier: String
		let confidence: Float
	}

	let uuid: UUID
	/// Per-label classification confidences, ordered as Vision reports them (best first).
	let labels: [Label]
	/// The observation's own confidence — distinct from any label confidence.
	let confidence: Float
	/// Full-image normalized bounding box, Vision coordinates (bottom-left origin).
	let boundingBox: CGRect
	/// Index into the region list that produced this box (dedup provenance + debugging).
	let regionIndex: Int

	var primaryLabelIdentifier: String? {
		labels.first?.identifier
	}
}

/// Which tiling scheme(s) feed the detector (AIA-0426). Independent toggles: the user can enable
/// Pyramid, 3x3, both (the union of their regions), or neither (full-frame only). An `OptionSet` —
/// not an enum — precisely because "both" is a valid, first-class state.
struct TilingScheme: OptionSet, Sendable {
	let rawValue: Int
	/// The AIA-0217 scheme: 4 quadrants + center + full frame (6 regions).
	static let pyramid = TilingScheme(rawValue: 1 << 0)
	/// AIA-0426: a 3x3 grid + full frame (10 regions).
	static let grid3x3 = TilingScheme(rawValue: 1 << 1)
}

/// Region layout and geometry for tiled detection (AIA-0217, AIA-0426).
///
/// Regions are normalized rects in Vision coordinates, so the actual crop pixel sizes
/// derive dynamically from whatever snapshot the renderer produced — no hardcoded sizes.
/// Every region keeps the snapshot's aspect ratio, so the detector's `.scaleFit`
/// letterboxing is unchanged while content resolution increases.
enum TileLayout {
	static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

	/// Pyramid (AIA-0217): 4 quadrants + center (the issue's 5 images) + a full-frame pass — without
	/// the full frame, an artifact larger than any half-size region would be missed entirely; the
	/// dedup containment stage prefers the full-frame box over region-clipped partials.
	static let pyramidRegions: [CGRect] = [
		CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
		CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
		CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
		CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
		CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
		fullFrame
	]

	/// 3x3 (AIA-0426): 9 grid cells (row-major, Vision bottom-left origin) + a full-frame pass = 10.
	/// The last element is the *literal* `fullFrame` constant (not `3 × 1/3`, which floating-point
	/// rounds off `1.0`) so it dedups exactly against the pyramid full frame in `regions(for:)`.
	static let grid3x3Regions: [CGRect] = {
		let step = 1.0 / 3.0
		var regions: [CGRect] = []
		for row in 0..<3 {
			for col in 0..<3 {
				regions.append(CGRect(x: CGFloat(col) * step, y: CGFloat(row) * step, width: step, height: step))
			}
		}
		regions.append(fullFrame)
		return regions
	}()

	/// The regions to run for the enabled scheme(s).
	/// - Empty set → full frame only (untiled).
	/// - Both schemes → the union of their regions, with exact duplicates (the shared full-frame pass)
	///   collapsed, so each unique region runs once; cross-region NMS (`dedupAcrossRegions`) merges the
	///   overlapping detections. Pyramid stays first, so `regionIndex` 0…5 is byte-identical to a
	///   pyramid-only run and the surviving full frame is pyramid's (index 5).
	/// - A non-empty set with only unknown bits falls back to the full frame rather than zero passes.
	///   (Future-proofing for an added scheme; the current data flow only ever produces {pyramid, grid3x3}.)
	static func regions(for schemes: TilingScheme) -> [CGRect] {
		guard schemes.isEmpty.not else { return [fullFrame] }
		var result: [CGRect] = []
		if schemes.contains(.pyramid) { result.append(contentsOf: pyramidRegions) }
		if schemes.contains(.grid3x3) { result.append(contentsOf: grid3x3Regions) }
		// Collapse exact duplicates (the full-frame pass both schemes share) so it runs once. Uses
		// `Array.contains` (CGRect: Equatable, iOS 13+) rather than `Set<CGRect>` (CGRect: Hashable is
		// iOS 18+, above this target). The lists are tiny (≤16), so the O(n²) pass is free.
		var deduped: [CGRect] = []
		for region in result where deduped.contains(region).not {
			deduped.append(region)
		}
		return deduped.isEmpty ? [fullFrame] : deduped
	}

	/// Remaps a region-relative normalized box (what Vision reports under a
	/// `regionOfInterest`) into full-image normalized space. No Y flip — the annotation
	/// views own the Vision→SwiftUI flip. Returns nil for degenerate model output
	/// (non-finite values or a box that clamps to nothing).
	static func remap(_ box: CGRect, into region: CGRect) -> CGRect? {
		let full = CGRect(
			x: region.minX + box.minX * region.width,
			y: region.minY + box.minY * region.height,
			width: box.width * region.width,
			height: box.height * region.height
		)
		guard full.minX.isFinite, full.minY.isFinite, full.width.isFinite, full.height.isFinite else {
			return nil
		}
		guard full.isEmpty.not else { return nil }
		// Clamp only when the box actually overflows — intersection introduces
		// floating-point drift even on boxes already inside the unit rect.
		guard fullFrame.contains(full).not else { return full }
		let clamped = full.intersection(fullFrame)
		guard clamped.isEmpty.not else { return nil }
		return clamped
	}

	/// Merges duplicates the overlapping regions create (the center and full-frame regions
	/// overlap every quadrant). Only boxes from *different* regions with the same primary
	/// label compete — within one region the model's own suppression already ruled.
	///
	/// Two order-independent stages:
	/// 1. Containment, geometry-preferring: a box mostly inside a larger same-label box is
	///    a region-clipped partial of it — drop the smaller one *regardless of confidence*
	///    (confidence-first suppression strands exactly the clipped boxes this targets).
	/// 2. Greedy IoU suppression by confidence for the near-identical survivors.
	static func dedupAcrossRegions(
		_ objects: [DetectedObject],
		containmentThreshold: CGFloat = 0.7,
		iouThreshold: CGFloat = 0.45,
		clippedAreaRatio: CGFloat = 0.8
	) -> [DetectedObject] {
		guard objects.count > 1 else { return objects }

		var survivors = [DetectedObject]()
		// Largest first: every kept box is at least as large as any later competitor,
		// so "smaller partial inside larger full" is checked in one direction only.
		// The stage fires only when the candidate is meaningfully smaller (a clipped
		// partial) — near-equal-area duplicates would otherwise be dropped by sort
		// order instead of by confidence; those belong to stage 2.
		// Ties break on uuid so equal inputs in any order produce the same result set
		// (Swift's sort is not stable).
		let byArea = objects.sorted {
			let lhs = area(of: $0.boundingBox)
			let rhs = area(of: $1.boundingBox)
			return lhs == rhs ? $0.uuid.uuidString > $1.uuid.uuidString : lhs > rhs
		}
		for candidate in byArea {
			let contained = survivors.contains { kept in
				competing(kept, candidate)
					&& area(of: candidate.boundingBox) <= clippedAreaRatio * area(of: kept.boundingBox)
					&& containment(of: candidate.boundingBox, in: kept.boundingBox) >= containmentThreshold
			}
			if contained.not {
				survivors.append(candidate)
			}
		}

		var kept = [DetectedObject]()
		let byConfidence = survivors.sorted {
			if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
			let lhs = area(of: $0.boundingBox)
			let rhs = area(of: $1.boundingBox)
			return lhs == rhs ? $0.uuid.uuidString > $1.uuid.uuidString : lhs > rhs
		}
		for candidate in byConfidence {
			let suppressed = kept.contains { winner in
				competing(winner, candidate)
					&& intersectionOverUnion(winner.boundingBox, candidate.boundingBox) >= iouThreshold
			}
			if suppressed.not {
				kept.append(candidate)
			}
		}
		return kept
	}

	// MARK: - Geometry helpers

	private static func competing(_ lhs: DetectedObject, _ rhs: DetectedObject) -> Bool {
		// Unlabeled observations never compete: nil == nil must not let two unlabeled
		// detections from different regions suppress each other.
		guard let lhsLabel = lhs.primaryLabelIdentifier,
			  let rhsLabel = rhs.primaryLabelIdentifier else { return false }
		return lhs.regionIndex != rhs.regionIndex && lhsLabel == rhsLabel
	}

	private static func area(of rect: CGRect) -> CGFloat {
		rect.width * rect.height
	}

	/// Fraction of `inner`'s area covered by `outer`.
	static func containment(of inner: CGRect, in outer: CGRect) -> CGFloat {
		let innerArea = area(of: inner)
		guard innerArea > 0 else { return 0 }
		return area(of: inner.intersection(outer)) / innerArea
	}

	static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
		let intersection = area(of: lhs.intersection(rhs))
		let union = area(of: lhs) + area(of: rhs) - intersection
		guard union > 0 else { return 0 }
		return intersection / union
	}
}
