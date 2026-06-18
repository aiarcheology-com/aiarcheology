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
/// (the dimmed app stays inert; only the Skip button dismisses the tour). A thin stroke outlines
/// the hole so the focused element reads clearly, including in dark mode.
struct TourSpotlight: View {
	@Environment(\.colorScheme) private var colorScheme
	/// Cutout rect in the overlay's coordinate space. `nil` dims the whole screen (no hole).
	let cutout: CGRect?
	/// Corner radius of the cutout.
	var cornerRadius: CGFloat = 10
	/// Padding added around the target rect so the control isn't cropped by the hole edge.
	var inset: CGFloat = 6
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
					// A focus ring around the cutout: a clear rounded border + a soft halo, so the
					// spotlighted control reads as "enclosed" (matches the macOS look) — AIA-0333.
					RoundedRectangle(cornerRadius: cornerRadius)
						.stroke(Color.white.opacity(0.95), lineWidth: 2)
						.shadow(color: .white.opacity(0.45), radius: 5)
						.frame(width: hole.width, height: hole.height)
						.offset(x: hole.minX, y: hole.minY)
						.allowsHitTesting(false)
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
