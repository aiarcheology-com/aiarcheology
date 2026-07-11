//
//  DetectionSession.swift
//  AI Archeology
//
//  AIA-0390: the detection feature grouped into one injectable, isolately-testable session.
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
	lazy var snapAdjustment = SnapAdjustment()
	lazy var renderer = DefaultRenderer()
	lazy var webViewRenderer = WebSnapshotRenderer(adjustment: self.snapAdjustment)
	lazy var guide = Guide(
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
