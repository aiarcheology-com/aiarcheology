//
//  ObservationRectangleView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct ObservationRectangleView: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval
	var showIdentifiers: Bool
	var animateDetections: Bool

	@State private var phasedOut = false

	/// Room the label needs above the box before it is tucked inside instead.
	///
	/// `@ScaledMetric`, because the label is `.caption` and grows with Dynamic Type: a fixed 22pt
	/// was enough at standard sizes and not at accessibility ones, where the guard passed with too
	/// little room and the web view's `.clipped()` cut the label's top off.
	@ScaledMetric(relativeTo: .caption) private var labelClearance: CGFloat = 24

	var body: some View {
		let size = DetectionViewport.size(ofNormalized: observation.boundingBox, in: geometry.size)
		let center = DetectionViewport.center(ofNormalized: observation.boundingBox, in: geometry.size)
		// Room above, and which horizontal edge the label grows from. See ``ObservationLabelPlacement``.
		let placement = ObservationLabelPlacement.decide(
			center: center,
			boxSize: size,
			viewWidth: geometry.size.width,
			labelClearance: labelClearance
		)
		let hasRoomAbove = placement.hasRoomAbove
		let anchor = placement.anchor

		// **A `ZStack`-free single positioned view, and an `.overlay` for the label — never a
		// `VStack`** (AIA-0765). The label and the box used to be two children of a `VStack`:
		// `.position` resolves inside the child's own layout row, and the stack offset that row by
		// the label row's height, so every label the box carried pushed the box further down the
		// page. With many classes above one box the drift was large enough to leave the rectangle
		// nowhere near what it had detected. An overlay draws without contributing any size, so the
		// box's geometry is now independent of whether a label is shown at all.
		//
		// `ObservationCircleView` and `ObservationPointView` never had this bug precisely because
		// they used `ZStack` + `.position`.
		Rectangle()
			.fill(Color.clear)
			.border(color, width: 4)
			// On the box alone, *before* the overlay. A parent's opacity multiplies through to its
			// overlay, so leaving this on the outside dimmed the label to 0.5 for the whole of the
			// marker's life. Both still leave together, because both read `phasedOut`.
			.opacity(phasedOut ? 0 : 0.5)
			.frame(width: size.width, height: size.height)
			.overlay(alignment: anchor) {
				if showIdentifiers, let label = observation.primaryLabel {
					DetectionLabelView(identifier: label.identifier, confidence: observation.confidence, color: color)
						// **Load-bearing.** An overlay is offered its *host's* size, so without this
						// the label is proposed the bounding box's width — and `.frame(maxWidth:)`
						// can only shrink a proposal, never enlarge one. A small detection would
						// therefore still truncate its class to an ellipsis, or to nothing: the very
						// symptom AIA-0765 is about, surviving the fix for it. `.fixedSize()` makes
						// the label take its ideal width and overflow the box instead, which is what
						// the reference image shows.
						.fixedSize()
						// Lifts the label clear of the border by aligning its *bottom* to the box's
						// top. Doing it with an alignment guide rather than an offset means no part
						// of this needs the label's measured size.
						.alignmentGuide(.top) { hasRoomAbove ? $0[.bottom] : $0[.top] }
						// Full opacity, unlike the box: a half-transparent class name over a busy
						// page is the unreadability this ticket is about.
						.opacity(phasedOut ? 0 : 1)
				}
			}
			.position(center)
			.detectionPhaseOut($phasedOut, after: phaseOutTime, animated: animateDetections)
	}
}

/// Vision boxes are normalized with a bottom-left origin. The view's coordinates are top-left,
/// so the vertical axis flips. Both the point marker and the rectangle use this, which is what
/// keeps a class label on the same detection as its box.
enum DetectionViewport {
	static func center(ofNormalized box: CGRect, in size: CGSize) -> CGPoint {
		CGPoint(x: box.midX * size.width, y: (1 - box.midY) * size.height)
	}

	static func size(ofNormalized box: CGRect, in size: CGSize) -> CGSize {
		CGSize(width: box.width * size.width, height: box.height * size.height)
	}
}

/// Where a detection label sits relative to its box.
///
/// A box hard against the top of the view has nowhere to put a label above it, so that one sits
/// just inside the top edge. Horizontally the label anchors to whichever side of the box faces
/// more free space, so a long class name near the right-hand edge grows inwards. That only means
/// anything because the label sizes itself and can be wider than the box; against a label clamped
/// to the box width the two anchors would be the same rectangle.
struct ObservationLabelPlacement: Equatable {
	var hasRoomAbove: Bool
	/// `true` grows the label leftward from the box's top-right corner.
	var anchorsTrailing: Bool

	var anchor: Alignment { anchorsTrailing ? .topTrailing : .topLeading }

	static func decide(
		center: CGPoint,
		boxSize: CGSize,
		viewWidth: CGFloat,
		labelClearance: CGFloat
	) -> ObservationLabelPlacement {
		ObservationLabelPlacement(
			hasRoomAbove: (center.y - boxSize.height / 2) >= labelClearance,
			anchorsTrailing: (center.x - boxSize.width / 2) > viewWidth * 0.6
		)
	}
}
