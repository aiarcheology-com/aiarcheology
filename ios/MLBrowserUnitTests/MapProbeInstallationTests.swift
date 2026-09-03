//
//  MapProbeInstallationTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: proof that the probe is wired into the SHIPPING web view, not just into tests.
//
//  This exists because it was not. Every probe test built its own `WKWebViewConfiguration` and
//  installed the registry itself, so the whole constructor-capture tier passed its tests while the
//  app installed nothing — the feature was green and inert at the same time. A test that builds its
//  own configuration can never notice that.
//

import WebKit
import XCTest
@testable import ML_Browser

@MainActor
final class MapProbeInstallationTests: XCTestCase {

	/// The user scripts the app actually ships, read from the app's own factory rather than from a
	/// configuration this test assembled.
	private func productionUserScripts() -> [WKUserScript] {
		MLWebView.makeUserContentController().userScripts
	}

	/// The regression this pins: the registry must be in the app's own configuration.
	func testRegistryScript_IsInstalledInTheShippingConfiguration() {
		let scripts = productionUserScripts()
		let registry = scripts.first { $0.source == MapProbeScript.registry }
		XCTAssertNotNil(
			registry,
			"the map registry is missing from the app's web view — the probe would find nothing in production"
		)
	}

	/// At `.atDocumentEnd` every global the registry means to trap has already been assigned, so the
	/// injection time is not a detail — it is the whole mechanism.
	func testRegistryScript_RunsBeforeThePagesOwnScripts() {
		let registry = productionUserScripts().first { $0.source == MapProbeScript.registry }
		XCTAssertEqual(registry?.injectionTime, .atDocumentStart)
	}

	/// Portals routinely put the map in an iframe.
	func testRegistryScript_RunsInEveryFrame() {
		let registry = productionUserScripts().first { $0.source == MapProbeScript.registry }
		XCTAssertEqual(registry?.isForMainFrameOnly, false)
	}

	/// The app's own configuration must carry the script that announces a frame, or every iframed
	/// map is unreachable.
	///
	/// This shipped inert once already: the script posted the message and the coordinator returned
	/// early for any name but `interactionHandler`, so nothing ever recorded a frame.
	///
	/// **Named for what it proves.** `WKUserContentController` exposes no list of registered handler
	/// names and `add(_:name:)` raises an Objective-C exception on a duplicate, which XCTest cannot
	/// catch — so the *native* half of that pair is not assertable through public API, and the
	/// previous name claimed it was (raised in review). The half that is assertable is the half that
	/// was actually broken.
	func testFrameAnnounceScript_IsInstalledByTheApp() {
		let controller = MLWebView.makeUserContentController()
		XCTAssertTrue(
			controller.userScripts.contains { $0.source.contains("aiaMapFrame") },
			"the registry script must announce its frame, or no WKFrameInfo can ever be obtained"
		)
	}

	/// The pre-existing interaction script must survive alongside it.
	func testTouchDetectionScript_IsStillInstalled() {
		let scripts = productionUserScripts()
		XCTAssertTrue(
			scripts.contains { $0.source.contains("interactionHandler") },
			"the touch-detection script was displaced"
		)
	}
}
