//
//  MapFrameRegistry.swift
//  AI Archeology
//
//  Remembering which frames announced a map, so the probe can ask them (AIA-0817).
//

import Foundation
import WebKit

/// The frames that have announced themselves as candidates for map probing.
///
/// ## Why this is needed at all
/// A great many map pages put the map in an `<iframe>` — documentation examples, portal embeds,
/// VertiGIS and Lizmap viewers. `WKWebView` has no API to enumerate frames, so the only way to
/// reach one is to hold a `WKFrameInfo` that WebKit handed us. The registry script runs in every
/// frame and posts a message on load; this keeps the `WKFrameInfo` that arrives with it.
///
/// ## Staleness
/// A `WKFrameInfo` belongs to a particular document. When a frame navigates, the old handle stops
/// working and `callAsyncJavaScript` fails for it — which the probe treats as "no answer", the same
/// as any other failure. Entries are cleared whenever the main frame commits a new document, so the
/// list cannot grow across a browsing session.
@MainActor
final class MapFrameRegistry {

	/// Bounded: a page with an unreasonable number of frames must not make capture unreasonable.
	private static let limit = 8

	private var frames: [WKFrameInfo] = []

	/// Child frames worth probing, in the order they announced themselves.
	///
	/// The main frame is excluded — the probe always asks it directly, and asking twice would just
	/// double the cost of the common case.
	var childFrames: [WKFrameInfo] {
		frames.filter { $0.isMainFrame.not }
	}

	func record(_ frame: WKFrameInfo) {
		guard frame.isMainFrame.not else { return }
		// `===`, not `==`. Both compile — `WKFrameInfo` is an `NSObject`, whose `==` forwards to
		// `isEqual:` and therefore to identity here — but the intent is that we already hold *this
		// handle*, and stating it in the operator means a future `isEqual:` override cannot quietly
		// change what this guard means (raised in review).
		guard frames.contains(where: { $0 === frame }).not else { return }

		// A frame that navigates announces itself again with a NEW handle, and the old one belongs to
		// a document that is gone. Superseding the entry for the same origin and address keeps that
		// churn from filling the list with dead handles — the case where the live map iframe is the
		// very frame the cap turns away (raised in review). Origin plus address is the most identity
		// `WKFrameInfo` exposes publicly.
		if let stale = frames.firstIndex(where: { $0.supersededBy(frame) }) {
			frames[stale] = frame
			return
		}

		// Drops the NEWEST arrival once full, keeping the earliest frames. A page's own content
		// frames announce themselves first; advertising and analytics frames arrive later, and
		// evicting the oldest would let them push the map's frame out of the list.
		guard frames.count < Self.limit else { return }
		frames.append(frame)
	}

	/// Called when the main frame commits a new document: every previous frame handle belongs to a
	/// page that is gone.
	func reset() {
		frames.removeAll()
	}
}

private extension WKFrameInfo {

	/// Whether `newer` is this same frame having navigated — same origin, same address, different
	/// handle.
	func supersededBy(_ newer: WKFrameInfo) -> Bool {
		guard self !== newer else { return false }
		return request.url == newer.request.url
			&& securityOrigin.protocol == newer.securityOrigin.protocol
			&& securityOrigin.host == newer.securityOrigin.host
			&& securityOrigin.port == newer.securityOrigin.port
	}
}
