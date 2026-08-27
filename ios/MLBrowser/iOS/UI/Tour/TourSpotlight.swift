//
//  TourSpotlight.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — dim + cutout layer.
//

import SwiftUI

/// The dim around a spotlighted element, drawn as **four rectangles** surrounding the cutout
/// rather than one full-screen layer with a cut-out shape.
///
/// Why four rectangles: a single masked/`eoFill` layer still hit-tests as a view over the hole,
/// so taps inside the cutout do NOT reach the real control beneath it (measured on-device). With
/// four rects there is literally **no overlay view over the hole**, so the real control there is
/// fully tappable — which is what the interactive tour steps require. Each dim rect swallows taps
/// (the dimmed app stays inert; only the Skip button dismisses the tour). The surrounding dim alone
/// defines the focused area — there is no border/halo around the hole (AIA-0380).
struct TourSpotlight: View {
	@Environment(\.colorScheme) private var colorScheme
	/// Cutout rect in the overlay's coordinate space. `nil` dims the whole screen (no hole).
	let cutout: CGRect?
	/// Padding added around the target rect so the control isn't cropped by the hole edge.
	var inset: CGFloat = Self.defaultInset

	/// The standard hole padding. Exposed so `TourPulse` can be drawn on the hole's edge instead
	/// of restating the number and drifting away from it.
	static let defaultInset: CGFloat = 6
	/// Whether the dim swallows taps. `false` makes it visual only (everything beneath stays
	/// interactive) — used for the in-sheet save step so the title field is still reachable.
	var blocksTaps: Bool = true

	/// Lighter dim in dark mode — a 0.55 black scrim on an already-dark UI reads as pitch black
	/// and loses the focused area; 0.4 keeps the spotlight legible (AIA-0333).
	private var dimOpacity: CGFloat { colorScheme == .dark ? 0.4 : 0.55 }

	var body: some View {
		GeometryReader { proxy in
			let full = CGRect(origin: .zero, size: proxy.size)
			let hole = cutout?.insetBy(dx: -inset, dy: -inset)
			ZStack(alignment: .topLeading) {
				if let hole = hole?.intersection(full), hole.isNull == false, hole.isEmpty == false {
					// Four dim rects around the hole; the hole itself has no view, so taps pass
					// through to the real control beneath.
					dimRect(CGRect(x: 0, y: 0, width: full.width, height: hole.minY))
					dimRect(CGRect(x: 0, y: hole.maxY, width: full.width, height: full.maxY - hole.maxY))
					dimRect(CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height))
					dimRect(CGRect(x: hole.maxX, y: hole.minY, width: full.maxX - hole.maxX, height: hole.height))
					// No focus ring: the surrounding dim alone defines the focused area. The white
					// rounded border + halo were removed (AIA-0380) — the frame read as clutter
					// around the spotlighted control.
				} else {
					dimRect(full)
				}
			}
			.ignoresSafeArea()
			.animation(.easeInOut(duration: 0.2), value: cutout)
		}
		.ignoresSafeArea()
	}

	/// One dim rectangle. Swallows taps on the dimmed area (so the dimmed app isn't interactive)
	/// without ever dismissing the tour.
	@ViewBuilder
	private func dimRect(_ rect: CGRect) -> some View {
		let base = Color.black.opacity(dimOpacity)
			.frame(width: max(0, rect.width), height: max(0, rect.height))
			.offset(x: rect.minX, y: rect.minY)
		if blocksTaps {
			base.contentShape(Rectangle()).onTapGesture { }
		} else {
			base.allowsHitTesting(false)
		}
	}
}

/// An animated ring drawn around an element the current tour step asks the user to **press**
/// (AIA-0757 A1/A4). Without it a passive-looking button next to a live **Skip** leaves the user
/// unsure which one the step wants.
///
/// This is **not** the frame AIA-0380 removed. That was a static white border + halo drawn around
/// *every* cutout, and it read as permanent chrome / clutter. This one is animated and appears only
/// on steps that require a specific press, so it reads as an invitation rather than decoration
/// around the whole tour.
///
/// Decoration only: hit-testing is disabled and it is hidden from accessibility, so it can never
/// swallow the tap that performs the step's action (`TourOverlay`'s transparent cutout tap target)
/// nor the real control it surrounds (the drawer's model toggle, the finding sheet's Save).
struct TourPulse: View {
	/// Corner radius of the ring — match the shape of whatever it surrounds.
	var cornerRadius: CGFloat = 12
	/// Ring colour. Blue is this app's "you can press this" tint (`AccentColor` is a deliberate
	/// neutral grey, so it cannot carry the meaning) and stays legible over the *un-dimmed* cutout
	/// in both appearances, unlike the white of the removed border.
	var color: Color = .blue
	/// One full pulse cycle.
	var period: Double = 1.4
	/// Ring thickness. Heavier than a hairline on purpose: the ring sits on the boundary between the
	/// lit cutout and the surrounding dim, where a thin stroke competes with that edge instead of
	/// reading as a mark of its own.
	var lineWidth: CGFloat = 6

	/// Reduce Motion gets a steady ring rather than an animation — the emphasis survives, the
	/// movement doesn't. Same accommodation as `FindingFlashOverlay`.
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var dimmed = false

	private var pulses: Bool { reduceMotion.not }

	var body: some View {
		RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
			.strokeBorder(color, lineWidth: lineWidth)
			.opacity(ringOpacity)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
			.animation(pulseAnimation, value: dimmed)
			.onAppear {
				// Toggling `dimmed` under a repeatForever animation is what produces the pulse.
				dimmed = pulses
			}
			.onChange(of: pulses) { _, arePulsing in
				// Flipping Reduce Motion mid-step changes `pulses` without re-appearing the view;
				// re-arm so an OFF flip starts pulsing immediately and an ON flip freezes it.
				dimmed = arePulsing
			}
	}

	private var ringOpacity: Double {
		guard pulses else { return 0.9 }
		return dimmed ? 0.2 : 1.0
	}

	private var pulseAnimation: Animation? {
		guard pulses else { return nil }
		return .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
	}
}
