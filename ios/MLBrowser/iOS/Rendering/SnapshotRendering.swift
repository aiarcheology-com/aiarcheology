//
//  SnapshotRendering.swift
//  AI Archeology
//
//  Created by Agent on 2026-07-10.
//

import WebKit
import SwiftUI

/// Port for producing a snapshot of the current web content (AIA-0389). Class-bound so
/// `SnapableGroup` can hold it `unowned`; the single requirement is `async` so a `@MainActor`
/// implementation can witness it (the actor hop is absorbed at the `await`) while the protocol
/// itself stays nonisolated — which is what lets a test fake run OFF the main actor (usable off
/// MainActor in tests/CI, AC2).
protocol SnapshotRendering: AnyObject {
	func snapshot() async -> UIImage?
}

/// Snapshots the live `WKWebView` and applies the user's Core Image adjustment. Replaces the old
/// `WebViewRenderer: DefaultRenderer` ObservableObject (AIA-0389): a `@MainActor` renderer (the WK
/// snapshot and `webView` are main-bound) that holds a STRONG `SnapAdjustment` — AppState owns
/// both and the edge is acyclic, so this retires the old `unowned var snapAdjustment` lifetime
/// coupling. The only off-main work is the Core Image render, kept in `Task.detached` as before.
@MainActor
final class WebSnapshotRenderer: SnapshotRendering {
	private weak var webView: WKWebView?
	private let adjustment: SnapAdjustment

	init(adjustment: SnapAdjustment) {
		self.adjustment = adjustment
	}

	/// The WebView representable hands off the live `WKWebView` here (and `nil`s it on teardown).
	/// Deliberately NOT a `SnapshotRendering` requirement: a synchronous nonisolated requirement
	/// cannot be witnessed by a `@MainActor` method under Swift 6, so it stays a concrete
	/// `@MainActor` method called only from the already-main `makeUIView`/`dismantleUIView`.
	func attach(_ webView: WKWebView?) {
		self.webView = webView
	}

	func snapshot() async -> UIImage? {
		guard let webView else { return nil }

		// Capture adjustment values on the main actor before hopping off it.
		let brightness = adjustment.brightness
		let contrast = adjustment.contrast
		let saturation = adjustment.saturation

		let config = WKSnapshotConfiguration()
		return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
			webView.takeSnapshot(with: config) { image, error in
				guard let image else {
					// Preserve the Sentry signal the manual-pick path logged before this move.
					LoggingPolicy.error("Web snapshot failed", error: error, logger: .ui)
					continuation.resume(returning: nil)
					return
				}
				// The Core Image render is expensive — run it off the main thread, as the old
				// renderer did. `takeSnapshot`/`webView` above cannot leave the main actor.
				Task.detached(priority: .userInitiated) {
					let adjusted = image.adjusted(brightness: brightness,
												  contrast: contrast,
												  saturation: saturation)
					continuation.resume(returning: adjusted)
				}
			}
		}
	}
}
