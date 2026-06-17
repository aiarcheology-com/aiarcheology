//
//  TourSpotlight.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — dim + cutout layer.
//

import SwiftUI

/// The full-screen dim with a rounded-rectangle cutout around the spotlighted element.
///
/// Hit-testing (the highest-risk piece): the interaction shape is the dim area **with the
/// cutout excluded** (`.contentShape(.interaction, _, eoFill: true)`). Taps inside the
/// cutout fall through to the real control beneath it in the ZStack; taps on the dim are
/// swallowed and forwarded to the optional `onDimTap` (used for a "tap outside to skip"
/// affordance). The content shape is set on the **drawing layer itself** — no full-screen
/// ancestor hit-tests as a rectangle over the hole.
struct TourSpotlight: View {
	/// Cutout rect in the overlay's coordinate space. `nil` dims the whole screen (no hole).
	let cutout: CGRect?
	/// Corner radius of the cutout.
	var cornerRadius: CGFloat = 10
	/// Padding added around the target rect so the control isn't cropped by the hole edge.
	var inset: CGFloat = 6
	/// Invoked when the dimmed (non-cutout) area is tapped.
	var onDimTap: () -> Void = {}

	var body: some View {
		GeometryReader { proxy in
			let full = CGRect(origin: .zero, size: proxy.size)
			let hole = cutout.map { $0.insetBy(dx: -inset, dy: -inset) }
			let path = dimPath(full: full, hole: hole)

			Color.black.opacity(0.55)
				.mask(
					// Reverse mask: keep everything except the hole.
					path.fill(style: FillStyle(eoFill: true))
				)
				// Hit-test the dim-with-hole shape on this very layer. eoFill excludes the
				// cutout, so taps there pass through to the control beneath.
				.contentShape(.interaction, path, eoFill: true)
				.onTapGesture { onDimTap() }
				.ignoresSafeArea()
				.animation(.easeInOut(duration: 0.2), value: cutout)
		}
		.ignoresSafeArea()
	}

	/// Outer rect + inner hole as a single even-odd path: the hole subtracts from the fill.
	private func dimPath(full: CGRect, hole: CGRect?) -> Path {
		var path = Path()
		path.addRect(full)
		if let hole {
			path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
		}
		return path
	}
}
