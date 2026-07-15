//
//  DetectionSession.swift
//  AI Archeology
//
//  AIA-0390: the detection feature grouped into one injectable, independently-testable session.
//  Owns the derived detection state (snapshot adjustment, renderers, detection-session state) and
//  is built by `DependencyContainer.makeAppState()`. `AppState` holds it and forwards
//  `detectionState`/`snapAdjustment`/`renderer`/`webViewRenderer` to it, so it no longer constructs
//  these feature internals itself.
//  AIA-0391: the former `Guide` became `DetectionSessionState`; `deep`/`dataController`/
//  `demoDataManager` are no longer needed here (they moved to `AppChromeState` for the app reset).
//

import Foundation
import SwiftUI

@MainActor
final class DetectionSession {
	// MARK: - Injected shared services (owned by DependencyContainer), used to build `detectionState`.
	//
	// INVARIANT (AIA-0390): `init` stores these injected refs ONLY and must NEVER touch a
	// `lazy var` below. Reading an owned lazy var here would force the feature state earlier
	// than today (the AIA-0385 DeepState eager-construction trap) — a behavior change.
	private let snap: SnapState
	private let settings: Settings
	private let analytics: AnalyticsState?

	// MARK: - Owned detection feature state (lazy → forced on first access, exactly as before).
	//
	// OWNERSHIP INVARIANT (from SnapshotRendering.swift / AIA-0389 + `DetectionSessionState`'s
	// `snapAdjustment` being `unowned`): `snapAdjustment` is the STRONG owner; `detectionState`
	// borrows it `unowned` and `webViewRenderer` holds it strong. All three MUST stay co-owned in
	// this session so the `unowned` edge can never dangle — do NOT separate `snapAdjustment` from
	// `detectionState`.
	// `private(set)`: external callers read these (via AppState's forwarding accessors) but must not
	// reassign them — reassigning `snapAdjustment` would drop the only strong ref and dangle
	// `detectionState`'s `unowned` edge. Lazy-force timing is unchanged.
	private(set) lazy var snapAdjustment = SnapAdjustment()
	private(set) lazy var renderer = DefaultRenderer()
	private(set) lazy var webViewRenderer = WebSnapshotRenderer(adjustment: self.snapAdjustment)
	private(set) lazy var detectionState = DetectionSessionState(
		snap: self.snap,
		settings: self.settings,
		snapAdjustment: self.snapAdjustment,
		analytics: self.analytics
	)

	init(
		snap: SnapState,
		settings: Settings,
		analytics: AnalyticsState? = nil
	) {
		self.snap = snap
		self.settings = settings
		self.analytics = analytics
	}
}
