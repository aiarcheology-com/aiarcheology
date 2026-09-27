//
//  SaveFindingPresentation.swift
//  AI Archeology
//
//  AIA-0984.
//

import Observation

/// The save-finding sheet's presentation: the picked detection it shows.
///
/// One model shared by the web screen, which binds its save sheet to it, and the headless build,
/// which reports and drives the same capture (AIA-0984). It used to be `@State` in `WebScreenView`,
/// with a headless copy in `StagedImageCapture`; one owner means the two builds cannot drift.
///
/// Owned app-wide by `AppChromeState` rather than per view: the app has a single window
/// (`UIApplicationSupportsMultipleScenes = false`) and one web screen, so one instance matches the
/// per-view state it replaces. The web screen clears it in its `onDisappear`, where the `@State`
/// used to be dropped with the view.
@MainActor
@Observable
final class SaveFindingPresentation {
	/// The picked detection being saved. Non-nil means the save sheet is up.
	var capture: FindingCapture?

	/// Whether the save sheet is up.
	var isPresented: Bool {
		capture != nil
	}
}
