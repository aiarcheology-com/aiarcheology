//
//  AnnotationViewBuilder.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

/// Produces the detection results that may be shown or picked. The confidence filter lives before
/// the symbol switch, so rectangle, circle and point presentation share exactly the same set.
enum DetectionPresentation {
	static func filteredFrame(_ frame: AppliedDetectionFrame?) -> AppliedDetectionFrame? {
		guard let frame else { return nil }
		// The provenance travels with the image: the screen's pick flow reads this filtered copy.
		return AppliedDetectionFrame(
			image: frame.image,
			results: filteredResults(frame.results),
			provenance: frame.provenance
		)
	}

	static func filteredResults(_ results: [DetectionResult]) -> [DetectionResult] {
		results.compactMap { group in
			let threshold = Float(DeepConfiguration.detectionConfidenceThreshold(for: group.params.entityId))
			let observations = group.observations.filter { $0.confidence >= threshold }
			guard observations.isEmpty.not else { return nil }
			return (observations: observations, params: group.params)
		}
	}
}

/// Drives a detection annotation's single phase-out flag.
///
/// Both modes give a marker the same *lifetime* — the model's `phaseOutTime` — and differ only in
/// whether it animates on the way out. Static-marker mode used to have no lifetime at all: the flag
/// never flipped, so once detection stopped the last frame's markers stayed painted over the page
/// for as long as the view lived (AIA-0765). Stopping detection does not tear these views down —
/// the phase-out *is* how a detection leaves the screen.
struct DetectionPhaseOut: ViewModifier {
	@Binding var phasedOut: Bool
	let phaseOutTime: CFTimeInterval

	/// `false` = settings.disableDetectionAnimations. The marker holds its steady state for the
	/// whole lifetime and then simply disappears, rather than easing out across it.
	let animated: Bool

	func body(content: Content) -> some View {
		content.task {
			guard phasedOut.not else { return }
			guard animated else {
				// Cancellation (the view left the screen) must not flip the flag: `try?` would
				// swallow it and phase out a marker that no longer exists.
				do {
					try await Task.sleep(for: .seconds(phaseOutTime))
				} catch {
					return
				}
				phasedOut = true
				return
			}
			withAnimation(.easeInOut(duration: phaseOutTime)) {
				phasedOut = true
			}
		}
	}
}

extension View {
	/// Ends the annotation's life after `phaseOutTime`: animated, it starts easing out immediately
	/// and is gone when the time is up; static, it holds and then disappears at the end of it. See
	/// ``DetectionPhaseOut``.
	func detectionPhaseOut(_ phasedOut: Binding<Bool>, after phaseOutTime: CFTimeInterval, animated: Bool) -> some View {
		modifier(DetectionPhaseOut(phasedOut: phasedOut, phaseOutTime: phaseOutTime, animated: animated))
	}
}

struct AnnotationViewBuilder: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var params: DeepDriverParams
	var showIdentifiers: Bool
	var animateDetections: Bool

    var body: some View {
        Group {
            switch params.selectedSymbol {
            case .circle:
                ObservationCircleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers, animateDetections: animateDetections)
            case .square:
                ObservationRectangleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers, animateDetections: animateDetections)
            case .point:
                ObservationPointView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers, animateDetections: animateDetections)
            }
        }
    }
}

/// The one piece of text drawn for a detection: its highest-confidence class and that confidence
/// (AIA-0765).
///
/// Shared by all three symbols so there is a single answer to "what does a detection say". Before
/// this, each view rendered *every* label truncated to six characters with no confidence at all —
/// in a frame sized to the bounding box, so on a small box the text clipped to nothing. That is why
/// classes read as "not visible" even with identifiers switched on.
struct DetectionLabelView: View {
	let identifier: String

	/// **The observation's confidence, not the label's** — see ``text(identifier:confidence:)``.
	let confidence: Float

	let color: Color

	/// The class name and the score, e.g. `ship 0.77`.
	///
	/// The caller passes ``DetectedObject/confidence`` — the *detection* score — and not
	/// `Label.confidence`, which is the class probability. For a single-class detector the class
	/// probability is trivially `1.0`, so every label read `1.00` no matter how weak the detection
	/// was. `DetectionPresentation.filteredResults` already filters on the observation's confidence,
	/// so this is also the number the user's own confidence threshold acts on: a threshold of 0.5
	/// now means every visible label reads 0.50 or higher, which it did not before.
	///
	/// Formatted with `String(format:)` rather than `formatted()` **on purpose**: the latter is
	/// locale-aware and renders `0,77` wherever the decimal separator is a comma. This number sits
	/// directly beside a model's class identifier, which is not localized either, and a comma there
	/// reads as a second field rather than a decimal.
	static func text(identifier: String, confidence: Float) -> String {
		"\(identifier) \(String(format: "%.2f", confidence))"
	}

	var body: some View {
		Text(Self.text(identifier: identifier, confidence: confidence))
			.font(.caption.weight(.semibold))
			.lineLimit(1)
			.padding(.horizontal, 5)
			.padding(.vertical, 2)
			// **The plate carries the annotation colour; the text is chosen to contrast with it.**
			//
			// The other way round — the user's colour as *text* on a dark plate — is what shipped
			// first, and it reads badly: the annotation colour is the user's to pick, and a mid
			// pink or a yellow against dark grey is thin, small type at low contrast. Inverting it
			// keeps the colour identity where it is most visible (the plate matches the box) and
			// moves the contrast problem somewhere it can actually be solved, because the text now
			// sits on a colour this view knows.
			.foregroundStyle(Self.legibleForeground(on: color))
			.background(
				RoundedRectangle(cornerRadius: 4, style: .continuous)
					.fill(color)
			)
			// Annotations are drawn over the live web view, which is tappable. A bare `Text` was
			// small enough not to matter; a padded plate is a real target, and it must not swallow
			// taps meant for the page or for the detection itself.
			.allowsHitTesting(false)
	}

	/// Black or white — whichever contrasts more with `background`, by the WCAG ratio.
	///
	/// Computed rather than fixed because the annotation colour is a user preference with no
	/// bounds: any single choice of text colour is unreadable against some part of the range.
	/// Falls back to white for a colour whose components cannot be read (a pattern colour), which
	/// is the safer default over the dark web pages this app is usually pointed at.
	static func legibleForeground(on background: Color) -> Color {
		guard let luminance = relativeLuminance(of: background) else { return .white }
		// Contrast against white is (1 + 0.05) / (L + 0.05); against black, (L + 0.05) / 0.05.
		let contrastWithWhite = 1.05 / (luminance + 0.05)
		let contrastWithBlack = (luminance + 0.05) / 0.05
		return contrastWithBlack > contrastWithWhite ? .black : .white
	}

	/// WCAG relative luminance, or `nil` when the colour has no readable RGB components.
	static func relativeLuminance(of color: Color) -> Double? {
		var red: CGFloat = 0
		var green: CGFloat = 0
		var blue: CGFloat = 0
		var alpha: CGFloat = 0
		guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }

		// sRGB components are gamma-encoded; luminance is defined on the linear values.
		func linear(_ component: CGFloat) -> Double {
			let value = Double(component)
			return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
	}
}

extension CGRect {
	/// Interprets self as a Vision-normalized rect (bottom-left origin) and maps it
	/// into a top-left-origin space of the given size — view points or image pixels.
	/// Shared by the live annotations' hit areas, the save-sheet/detail highlight,
	/// and the inventory's thumbnail crop so the transforms cannot drift.
	func visionRect(in size: CGSize) -> CGRect {
		CGRect(
			x: minX * size.width,
			y: (1 - maxY) * size.height,
			width: width * size.width,
			height: height * size.height
		)
	}
}
