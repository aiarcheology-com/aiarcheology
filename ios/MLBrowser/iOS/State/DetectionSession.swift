//
//  DetectionSession.swift
//  AI Archeology
//
//  AIA-0390: the detection feature grouped into one injectable, independently-testable session.
//  Owns the derived detection state (snapshot adjustment, renderers, guide) and is built by
//  `DependencyContainer.makeAppState()`. `AppState` holds it and forwards `guide`/`snapAdjustment`/
//  `renderer`/`webViewRenderer` to it, so it no longer constructs these feature internals itself.
//

import Foundation
import SwiftUI

@MainActor
final class DetectionSession {
	// MARK: - Injected shared services (owned by DependencyContainer), used to build `guide`.
	//
	// INVARIANT (AIA-0390): `init` stores these injected refs ONLY and must NEVER touch a
	// `lazy var` below. Reading an owned lazy var here would force the feature state earlier
	// than today (the AIA-0385 DeepState eager-construction trap) — a behavior change.
	private let snap: SnapState
	private let deep: DeepState
	private let settings: Settings
	private let dataController: DataController
	private let demoDataManager: DemoDataManager

	// MARK: - Owned detection feature state (lazy → forced on first access, exactly as before).
	//
	// OWNERSHIP INVARIANT (from SnapshotRendering.swift / AIA-0389 + `Guide.snapAdjustment`
	// being `unowned`): `snapAdjustment` is the STRONG owner; `guide` borrows it `unowned` and
	// `webViewRenderer` holds it strong. All three MUST stay co-owned in this session so the
	// `unowned` edge can never dangle — do NOT separate `snapAdjustment` from `guide`
	// (e.g. in #391's Guide split).
	// `private(set)`: external callers read these (via AppState's forwarding accessors) but must not
	// reassign them — reassigning `snapAdjustment` would drop the only strong ref and dangle
	// `guide`'s `unowned` edge. Lazy-force timing is unchanged.
	private(set) lazy var snapAdjustment = SnapAdjustment()
	private(set) lazy var renderer = DefaultRenderer()
	private(set) lazy var webViewRenderer = WebSnapshotRenderer(adjustment: self.snapAdjustment)
	private(set) lazy var guide = Guide(
		snap: self.snap,
		deep: self.deep,
		settings: self.settings,
		dataController: self.dataController,
		demoDataManager: self.demoDataManager,
		snapAdjustment: self.snapAdjustment
	)

	init(
		snap: SnapState,
		deep: DeepState,
		settings: Settings,
		dataController: DataController,
		demoDataManager: DemoDataManager
	) {
		self.snap = snap
		self.deep = deep
		self.settings = settings
		self.dataController = dataController
		self.demoDataManager = demoDataManager
	}
}
