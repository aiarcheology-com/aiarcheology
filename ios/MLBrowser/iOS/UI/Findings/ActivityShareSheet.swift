//
//  ActivityShareSheet.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import SwiftUI
import UIKit

/// A share payload carried through the imperative presenter. `[Any]` activity
/// items are not `Identifiable`, so this wrapper gives them a stable identity.
struct ActivitySharePayload: Identifiable {
	let id = UUID()
	let items: [Any]
	/// Called after either completing or dismissing the system share sheet.
	let completion: (() -> Void)?

	init(items: [Any], completion: (() -> Void)? = nil) {
		self.items = items
		self.completion = completion
	}
}

extension View {
	/// Presents the system share sheet for `payload` when it becomes non-nil.
	///
	/// `UIActivityViewController` is presented imperatively from a backing
	/// controller rather than wrapped in a SwiftUI `.sheet`: on Mac/iPad the
	/// `.sheet` route collides with the activity controller's own presentation
	/// ("a share sheet is already visible") and provides no popover anchor. This
	/// presenter guards against a double-present and clears `payload` when the
	/// sheet finishes.
	func activityShareSheet(_ payload: Binding<ActivitySharePayload?>) -> some View {
		background(ActivitySharePresenter(payload: payload))
	}
}

/// Backing representable that owns the presentation. Lives in the view hierarchy
/// (via `.background`) so it has a real window/controller to present from and a
/// view to anchor the iPad/Mac popover to.
private struct ActivitySharePresenter: UIViewControllerRepresentable {
	@Binding var payload: ActivitySharePayload?

	func makeUIViewController(context: Context) -> UIViewController {
		UIViewController()
	}

	func updateUIViewController(_ host: UIViewController, context: Context) {
		// Only present when there is a payload and nothing is already up — the
		// guard is what prevents the "already visible" double-present.
		guard let payload, host.presentedViewController == nil else { return }

		// UIActivityViewController crashes with no items; bail and clear instead.
		guard payload.items.isEmpty.not else {
			DispatchQueue.main.async {
				if self.payload?.id == payload.id { self.payload = nil }
			}
			return
		}

		let presentedID = payload.id
		let completion = payload.completion
		let controller = UIActivityViewController(activityItems: payload.items, applicationActivities: nil)
		controller.completionWithItemsHandler = { _, _, _, _ in
			// Clear on the next runloop tick (can't mutate SwiftUI state inside the
			// synchronous update), and only if a newer share hasn't replaced this
			// one — otherwise a second share triggered during dismissal is dropped.
			DispatchQueue.main.async {
				completion?()
				if self.payload?.id == presentedID { self.payload = nil }
			}
		}
		// iPad / Mac present the activity sheet as a popover and require an anchor.
		if let popover = controller.popoverPresentationController {
			popover.sourceView = host.view
			popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
			popover.permittedArrowDirections = []
		}
		host.present(controller, animated: true)
	}
}
