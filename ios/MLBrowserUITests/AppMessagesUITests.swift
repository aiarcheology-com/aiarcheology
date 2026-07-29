//
//  AppMessagesUITests.swift
//  MLBrowserUITests
//
//  AIA-0115: remote in-app messaging surfaces. Drives deterministic message payloads through
//  the launch config's `appMessagesJSON` (served by `StaticFeatureFlagProvider` under UI tests)
//  and the mock auth / subscription gates, so every surface — login, paywall, in-app, About,
//  Settings — and the seen/replied persistence can be asserted with no ConfigCat, Clerk, or
//  StoreKit involved.
//

import XCTest

final class AppMessagesUITests: UITestCase {

	// MARK: - Fixtures
	//
	// Payloads matching the `AppMessage` wire schema, kept as raw JSON so the exact contract
	// (surfaces, buttons) is visible at the test site. Every id carries a per-test-invocation
	// token: seen/replied marks persist in the simulator's UserDefaults across *runs* (by design —
	// tests 1 and 4 rely on it across their in-test relaunch), so reusing a static id would let a
	// previous run's marks hide the banner from this one.
	private let runToken = UUID().uuidString.prefix(8)

	private var infoInAppID: String { "info-inapp-\(runToken)" }
	private var interactiveID: String { "interactive-\(runToken)" }
	private var infoAboutID: String { "info-about-\(runToken)" }
	private var infoSettingsID: String { "info-settings-\(runToken)" }

	/// Info message on `inApp` (no buttons) — dismissed with the explicit close control.
	private var infoInApp: String {
		"""
		[{"id":"\(infoInAppID)","title":"Welcome aboard","body":"Thanks for installing.","surfaces":["inApp"]}]
		"""
	}
	/// Interactive message with yes/no buttons on `paywall` + `inApp`.
	private var interactivePaywallInApp: String {
		"""
		[{"id":"\(interactiveID)","title":"Enjoying the app?","body":"Tell us what you think.","surfaces":["paywall","inApp"],"buttons":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}]}]
		"""
	}
	/// Info message on `login` — display-only over the sign-in screen.
	private var infoLogin: String {
		"""
		[{"id":"info-login-\(runToken)","title":"Welcome back","body":"Sign in to continue.","surfaces":["login"]}]
		"""
	}
	/// Interactive message targeting `login` (and `inApp`). Interactive messages are hidden on the
	/// pre-auth login surface, so this must never render a banner there.
	private var interactiveLogin: String {
		"""
		[{"id":"interactive-login-\(runToken)","title":"Rate us","body":"Please rate the app.","surfaces":["login","inApp"],"buttons":[{"id":"ok","label":"OK"}]}]
		"""
	}
	/// Info message on `aboutApp` — rendered inline inside the About screen.
	private var infoAbout: String {
		"""
		[{"id":"\(infoAboutID)","title":"What's new","body":"New models are available.","surfaces":["aboutApp"]}]
		"""
	}
	/// Info message on `settings` — rendered inline atop the Settings form.
	private var infoSettings: String {
		"""
		[{"id":"\(infoSettingsID)","title":"Heads up","body":"Settings moved around a bit.","surfaces":["settings"]}]
		"""
	}
	/// Styled message whose body carries inline Markdown (bold + a link).
	private var markdownStyled: String {
		"""
		[{"id":"markdown-\(runToken)","title":"Formatted","body":"Read **the** [docs](https://example.com) today.","surfaces":["inApp"],"style":"info"}]
		"""
	}

	/// A launch config that turns messaging on and serves `json` as the remote payload.
	private func messagingConfig(_ json: String) -> LaunchConfig {
		LaunchConfig(featureFlagOverrides: ["isAppMessagingEnabled": true], appMessagesJSON: json)
	}

	// MARK: - Tests

	/// In-app informational banner shows, dismisses, and stays gone after a relaunch with the same
	/// config (the "seen" mark persists in UserDefaults, which the launch baseline never clears).
	func test_inApp_informational_bannerShowsAndDismissPersists() {
		let config = messagingConfig(infoInApp)
		launch(config)

		assertExists(AID.cpu, true)                 // app proper is mounted (inApp surface)
		assertExists(AID.appMessageBanner, true)
		assertExists(AID.appMessageTitle, true)

		let dismiss = app.buttons[AID.appMessageDismiss]
		XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "Informational dismiss control missing")
		dismiss.tap()
		XCTAssertTrue(waitForDisappearance(of: element(AID.appMessageBanner)), "Banner did not dismiss")

		// Relaunch with the SAME config: dismissing marked the message seen, so it must not return.
		launch(config)
		assertExists(AID.cpu, true)
		assertExists(AID.appMessageBanner, false)
	}

	/// **Removed by AIA-0536: there is no login surface to render on.**
	///
	/// `.signedOut` used to be a whole root screen, so a banner could sit on it and `.login` was a
	/// resolvable surface. Sign-in is a transient sheet now — a signed-out user is looking at the
	/// paywall or at the app — so `MessageSurfaceResolver` never returns `.login` and a message
	/// targeting it is undeliverable. This asserts the consequence rather than leaving it as a
	/// silently-missing case: a signed-out entitled user sees the app, and a login-targeted message
	/// produces no banner anywhere.
	func test_loginTargetedMessage_isUndeliverableAfterTheCutOver() {
		launch(messagingConfig(infoLogin), mockAuthGate: "signedOut", mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
		assertExists(AID.authSignIn, false)
		assertExists(AID.appMessageBanner, false)
	}

	/// A message targeting `paywall` renders over the paywall root.
	func test_paywall_surface_showsMessage() {
		launch(messagingConfig(interactivePaywallInApp), mockAuthGate: "ready", mockSubscription: "notSubscribed")
		assertExists(AID.paywallSignOut, true)      // paywall-as-root proof (see SubscriptionGateUITests)
		assertExists(AID.appMessageBanner, true)
		assertExists(AID.appMessageTitle, true)
	}

	/// An interactive message renders its reply buttons; replying dismisses the banner and the reply
	/// persists across a relaunch with the same config (local replied mark + NoOp writer).
	func test_interactive_buttonsRenderAndReplyDismisses() {
		let config = messagingConfig(interactivePaywallInApp)
		launch(config)

		assertExists(AID.cpu, true)
		assertExists(AID.appMessageReply("yes"), true)
		assertExists(AID.appMessageReply("no"), true)

		app.buttons[AID.appMessageReply("yes")].tap()
		XCTAssertTrue(waitForDisappearance(of: element(AID.appMessageBanner)), "Banner did not dismiss after reply")

		// Relaunch same config: the reply persisted, so the interactive banner must not return.
		launch(config)
		assertExists(AID.cpu, true)
		assertExists(AID.appMessageBanner, false)
	}

	/// The About screen lists an `aboutApp` message inline (reached via drawer → Settings → About).
	func test_aboutApp_sectionListsMessage() {
		launch(messagingConfig(infoAbout))
		openSettings()
		XCTAssertTrue(scrollTo(AID.settingsAbout), "About row missing from Settings")
		element(AID.settingsAbout).tap()
		assertExists(AID.appMessageAboutRow(infoAboutID), true)
	}

	/// The Settings form lists a `settings` message inline, pinned above the regular sections
	/// (reached directly via drawer → Settings, no further navigation needed).
	func test_settings_sectionListsMessage() {
		launch(messagingConfig(infoSettings))
		openSettings()
		assertExists(AID.appMessageSettingsRow(infoSettingsID), true)
	}

	/// Interactive messages still require a signed-in account — that rule survives the cut-over, but
	/// the surface it applies on has changed. A signed-out user now reaches the app itself, so this
	/// checks the `.inApp` surface rather than a sign-in screen that no longer exists.
	func test_signedOut_interactiveHiddenInApp() {
		launch(messagingConfig(interactiveLogin), mockAuthGate: "signedOut", mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
		assertExists(AID.appMessageBanner, false)
	}

	/// A styled message with inline Markdown renders the PARSED body — the link/bold syntax is
	/// consumed, not shown literally. (The tint itself is visual-only; this guards the parsing.)
	func test_markdownBody_rendersParsed_onStyledCard() {
		launch(messagingConfig(markdownStyled))
		assertExists(AID.appMessageBanner, true)

		let parsedBody = app.staticTexts["Read the docs today."]
		XCTAssertTrue(parsedBody.waitForExistence(timeout: 10), "Markdown body did not render parsed")
		XCTAssertFalse(
			app.staticTexts["Read **the** [docs](https://example.com) today."].exists,
			"Raw markdown syntax leaked into the rendered banner"
		)
	}
}
