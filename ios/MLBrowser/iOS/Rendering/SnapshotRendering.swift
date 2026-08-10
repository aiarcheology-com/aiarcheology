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
/// MainActor in tests/CI, AC2). `Sendable` so a `@MainActor` caller (`SnapableGroup`) can invoke
/// the nonisolated `async snapshot()` on an `any SnapshotRendering` receiver without tripping
/// Swift 6 region isolation; every conformer already qualifies (the `@MainActor` impl is
/// implicitly Sendable, the fake is immutable).
protocol SnapshotRendering: AnyObject, Sendable {
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
	private var traceSnapshotSequence: UInt64 = 0

	init(adjustment: SnapAdjustment) {
		self.adjustment = adjustment
	}

	/// The WebView representable hands off the live `WKWebView` here from its `@MainActor`
	/// `makeUIView`. Teardown deliberately does NOT detach it — clearing it on a transient
	/// rebuild would break `takeSnapshot` mid-detection; the `weak` ref auto-nils when the web
	/// view is truly gone. Deliberately NOT a `SnapshotRendering` requirement: a synchronous
	/// nonisolated requirement cannot be witnessed by a `@MainActor` method under Swift 6, so it
	/// stays a concrete `@MainActor` method.
	func attach(_ webView: WKWebView?) {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] WebSnapshotRenderer attach previous=\(self.webView != nil) new=\(webView != nil) bounds=\(webView?.bounds.width ?? 0)x\(webView?.bounds.height ?? 0) windowAttached=\(webView?.window != nil)",
			logger: .rendering
		)
		self.webView = webView
	}

	func snapshot() async -> UIImage? {
		traceSnapshotSequence &+= 1
		let request = traceSnapshotSequence
		guard let webView else {
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] WebSnapshotRenderer snapshot rejected request=\(request) reason=noWebView",
				logger: .rendering
			)
			return nil
		}

		LoggingPolicy.debug(
			"[AIA-0587 TRACE] WebSnapshotRenderer snapshot started request=\(request) bounds=\(webView.bounds.width)x\(webView.bounds.height) windowAttached=\(webView.window != nil) loading=\(webView.isLoading) zoom=\(webView.scrollView.zoomScale) content=\(webView.scrollView.contentSize.width)x\(webView.scrollView.contentSize.height) offset=\(webView.scrollView.contentOffset.x),\(webView.scrollView.contentOffset.y)",
			logger: .rendering
		)

		// Capture adjustment values on the main actor before hopping off it.
		let brightness = adjustment.brightness
		let contrast = adjustment.contrast
		let saturation = adjustment.saturation
		let startedAt = Date()

		let config = WKSnapshotConfiguration()
		return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
			webView.takeSnapshot(with: config) { image, error in
				guard let image else {
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] WebSnapshotRenderer WebKit capture returned nil request=\(request) elapsed=\(Date().timeIntervalSince(startedAt))",
						logger: .rendering
					)
					// Preserve the Sentry signal the manual-pick path logged before this move.
					LoggingPolicy.error("Web snapshot failed", error: error, logger: .ui)
					continuation.resume(returning: nil)
					return
				}
				LoggingPolicy.debug(
					"[AIA-0587 TRACE] WebSnapshotRenderer WebKit capture completed request=\(request) pixels=\(image.size.width)x\(image.size.height) scale=\(image.scale) elapsed=\(Date().timeIntervalSince(startedAt))",
					logger: .rendering
				)
				// The Core Image render is expensive — run it off the main thread, as the old
				// renderer did. `takeSnapshot`/`webView` above cannot leave the main actor.
				Task.detached(priority: .userInitiated) {
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] WebSnapshotRenderer adjustment started request=\(request)",
						logger: .rendering
					)
					let adjusted = image.adjusted(brightness: brightness,
												  contrast: contrast,
												  saturation: saturation)
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] WebSnapshotRenderer adjustment completed request=\(request) pixels=\(adjusted.size.width)x\(adjusted.size.height) elapsed=\(Date().timeIntervalSince(startedAt))",
						logger: .rendering
					)
					continuation.resume(returning: adjusted)
				}
			}
		}
	}
}
