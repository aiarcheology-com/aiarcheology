//
//  FeatureFlagUITests.swift
//  MLBrowserUITests
//
//  Remote feature flags (AIA-0350): proves the UI-test override seam actually reaches
//  the view layer.
//

import XCTest

/// Locks the `featureFlagOverrides` launch-config path end to end.
///
/// This exists because the seam was silently dead once. `DependencyContainer` gated the
/// static provider on `isRunningUnderAnyTests` alone, but the app under test is a separate
/// process from the UI-test runner, so `XCTestConfigurationFilePath` is absent there — the
/// app took the ConfigCat path, answered from the live CDN, and ignored every override.
/// Nothing failed, because the remote values happened to match the defaults. Asserting on
/// the *overridden* value (not the default) is what makes this test able to fail.
final class FeatureFlagUITests: UITestCase {

	private func openModelImportSheet() {
		openDrawer()
		let addModel = app.buttons["Add Model"]
		XCTAssertTrue(addModel.waitForExistence(timeout: 10), "Add Model toolbar button missing")
		addModel.tap()
	}

	/// The override must win over the compiled default (`true`). If the app ever resolves
	/// flags from the network during a UI test, this fails — which is the point.
	func testCatalogEntry_hiddenWhenOverriddenOff() {
		launch(LaunchConfig(featureFlagOverrides: ["isModelCatalogEnabled": false]))
		openModelImportSheet()

		let catalog = app.buttons[AID.newConfigurationOpenCatalog]
		XCTAssertFalse(
			catalog.waitForExistence(timeout: 3),
			"Catalog entry point must be hidden when isModelCatalogEnabled is overridden off"
		)
	}

	/// The paired positive case: with the flag on, the same entry point is present — so the
	/// negative test above cannot pass merely because the button never renders.
	func testCatalogEntry_shownWhenOverriddenOn() {
		launch(LaunchConfig(featureFlagOverrides: ["isModelCatalogEnabled": true]))
		openModelImportSheet()

		let catalog = app.buttons[AID.newConfigurationOpenCatalog]
		XCTAssertTrue(
			catalog.waitForExistence(timeout: 10),
			"Catalog entry point must be present when isModelCatalogEnabled is on"
		)
	}

	/// Headless mode is a launch mode of this same Debug app (AIA-0991), and its options are parsed
	/// only in headless mode. A UI launch that still carries them — a scheme argument left on, say —
	/// must reach the app, not trap on them: each of these stops a headless launch.
	func testStaleHeadlessOptions_doNotStopAUILaunch() {
		launch(additionalArguments: [
			"-headlessFlag", "bogus",
			"-headlessStagedImage", "../x",
			"-headlessFreeAccessEndsIn", "1"
		])
		openDrawer()
	}
}
