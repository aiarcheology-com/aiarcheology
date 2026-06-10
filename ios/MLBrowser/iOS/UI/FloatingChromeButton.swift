//
//  FloatingChromeButton.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 10.06.26.
//

import SwiftUI

/// A movable, semi-transparent button shown while on-the-fly detection runs.
/// Tapping it toggles the browser chrome (navigation bar) without stopping detection.
///
/// The drag gesture is attached to the button itself — only the button's frame is
/// hit-testable, so touches elsewhere pass through to the content underneath.
/// The position is owned by the parent (the button is conditionally mounted and
/// local state would not survive unmount); `nil` means the default corner.
struct FloatingChromeButton: View {
	@EnvironmentObject var guide: Guide
	@Binding var position: CGPoint?

	@GestureState private var dragOffset: CGSize = .zero

	private static let diameter: CGFloat = 52
	private static let margin: CGFloat = 16

	var body: some View {
		// Deliberately not a Button: a Button claims the touch and an attached
		// DragGesture rarely wins, so the button could not be dragged with a
		// plain swipe. A tap gesture and a drag gesture arbitrate cleanly.
		GeometryReader { geometry in
			Image(systemName: "slider.horizontal.3")
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(.primary)
				.frame(width: Self.diameter, height: Self.diameter)
				.background(
					// Translucency on the background only — the icon keeps full
					// opacity so it stays legible over busy web content.
					Circle()
						.fill(.ultraThinMaterial)
						.opacity(0.7)
				)
				// Border and shadow keep the button findable on pages that match
				// the material's tone (a white sheet made it nearly invisible).
				.overlay(
					Circle()
						.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
				)
				.shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
				.contentShape(Circle())
				// Both gestures on the same view: the drag engages after 10pt
				// of movement, a still touch falls through to the tap.
				.highPriorityGesture(drag(in: geometry.size))
				.onTapGesture {
					guide.chromeToggleTapped()
				}
				.accessibilityAddTraits(.isButton)
				.testability(Testability.Button.floatingChromeToggle)
				.accessibilityLabel(L10n.Browser.FloatingButton.label)
				.position(displayedPosition(in: geometry.size))
		}
	}

	/// The committed position (or the default corner), re-clamped every render so
	/// rotation and size changes cannot strand the button off screen, plus the
	/// live drag translation.
	private func displayedPosition(in size: CGSize) -> CGPoint {
		let base = clamp(position ?? defaultPosition(in: size), in: size)
		return clamp(CGPoint(x: base.x + dragOffset.width, y: base.y + dragOffset.height), in: size)
	}

	private func drag(in size: CGSize) -> some Gesture {
		DragGesture()
			.updating($dragOffset) { value, state, _ in
				state = value.translation
			}
			.onEnded { value in
				let base = clamp(position ?? defaultPosition(in: size), in: size)
				position = clamp(
					CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height),
					in: size
				)
			}
	}

	private func defaultPosition(in size: CGSize) -> CGPoint {
		CGPoint(
			x: size.width - Self.diameter / 2 - Self.margin,
			y: size.height - Self.diameter / 2 - Self.margin
		)
	}

	private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
		let radius = Self.diameter / 2
		return CGPoint(
			x: min(max(point.x, radius + Self.margin), max(size.width - radius - Self.margin, radius + Self.margin)),
			y: min(max(point.y, radius + Self.margin), max(size.height - radius - Self.margin, radius + Self.margin))
		)
	}
}
