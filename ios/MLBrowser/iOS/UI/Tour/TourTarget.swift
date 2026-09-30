//
//  TourTarget.swift
//  AI Archeology
//
//  AIA-1014: measure across native toolbar / SwiftUI hosting boundaries through the window.
//

import SwiftUI

/// A weak marker in the native view tree. SwiftUI bounds anchors do not reliably cross the
/// separate hosting roots used by navigation toolbar items on Mac (Designed for iPad).
/// UIKit conversion includes those hosts' positions, safe areas and window transforms.
@MainActor
final class TourTargetReference {
	weak var view: UIView?

	func rect(in destination: TourTargetReference) -> CGRect? {
		guard let view, let container = destination.view,
			let window = view.window, window === container.window,
			Self.isVisible(view), Self.isVisible(container) else { return nil }
		let rect = view.convert(view.bounds, to: container)
		guard rect.origin.x.isFinite, rect.origin.y.isFinite,
			rect.width.isFinite, rect.height.isFinite,
			rect.width > 0, rect.height > 0,
			container.bounds.contains(rect) else { return nil }
		return rect.offsetBy(dx: -container.bounds.minX, dy: -container.bounds.minY)
	}

	private static func isVisible(_ view: UIView) -> Bool {
		var ancestor: UIView? = view
		while let current = ancestor {
			if current.isHidden { return false }
			ancestor = current.superview
		}
		return true
	}
}

/// Preferences carry identities, not a snapshot of a rectangle that can outlive its layout.
struct TourTargetPreferenceKey: PreferenceKey {
	static let defaultValue: [TourAnchorID: TourTargetReference] = [:]

	static func reduce(
		value: inout [TourAnchorID: TourTargetReference],
		nextValue: () -> [TourAnchorID: TourTargetReference]
	) {
		value.merge(nextValue()) { _, new in new }
	}
}

/// A transparent, noninteractive marker whose bounds match its SwiftUI background's bounds.
/// The hierarchy owns the UIView; the preference's weak reference cannot retain a dismissed UI.
struct TourGeometryMarker: UIViewRepresentable {
	let reference: TourTargetReference

	func makeUIView(context: Context) -> UIView {
		let view = UIView()
		view.isUserInteractionEnabled = false
		view.isAccessibilityElement = false
		reference.view = view
		return view
	}

	func updateUIView(_ uiView: UIView, context: Context) {
		reference.view = uiView
	}
}

private struct TourTargetModifier: ViewModifier {
	let id: TourAnchorID
	@State private var reference = TourTargetReference()

	func body(content: Content) -> some View {
		content
			.background(TourGeometryMarker(reference: reference))
			.preference(key: TourTargetPreferenceKey.self, value: [id: reference])
	}
}

extension View {
	/// Marks the native bounds of a spotlight target, including targets hosted by a toolbar.
	func tourTarget(_ id: TourAnchorID) -> some View {
		modifier(TourTargetModifier(id: id))
	}
}
