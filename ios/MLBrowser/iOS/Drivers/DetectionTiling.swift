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

/// Region layout and geometry for tiled detection (AIA-0217).
///
/// Regions are normalized rects in Vision coordinates, so the actual crop pixel sizes
/// derive dynamically from whatever snapshot the renderer produced — no hardcoded sizes.
/// Every half-size region keeps the snapshot's aspect ratio, so the detector's `.scaleFit`
/// letterboxing is unchanged while content resolution roughly doubles.
enum TileLayout {
	static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

	/// Tiled: 4 quadrants + center (the issue's 5 images) + a full-frame pass — without it,
	/// an artifact larger than any half-size region would be missed entirely; the dedup
	/// containment stage prefers the full-frame box over region-clipped partials.
	static func regions(tiled: Bool) -> [CGRect] {
		guard tiled else { return [fullFrame] }
		return [
			CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
			CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
			CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
			CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
			CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
			fullFrame
		]
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
