//
//  ControlCoverageTests.swift
//  MLBrowserArchitectureTests
//
//  AIA-1003.
//

import XCTest

/// Headless mode drives the app through actions, not views, so a control added to a screen headless
/// covers can go unnoticed there. This scan closes that gap: every control on a covered view maps to
/// a headless action or says why it has none, and every other part of `UI/` is declared uncovered.
///
/// A control is any `Testability.<Kind>.<id>` literal whose kind is interactive; a new kind counts
/// until it is added to `passiveKinds`. Fails closed on an empty or unreadable scan.
final class ControlCoverageTests: XCTestCase {

	/// Kinds that name something to read, not something to operate.
	private static let passiveKinds: Set<String> = ["Label", "ProgressView", "List", "ImageView", "View", "Checkpoint", "Collection"]

	/// Views with a headless counterpart, relative to `UI/`: `action:<name>` or a reason → the controls it
	/// accounts for, space-separated.
	private static let covered: [String: [String: String]] = [
		"Drawer/DrawerContent.swift": [
			"action:open-findings": "Button.drawerFindings", "action:open-account": "Button.drawerSignIn Button.drawerAccount",
			"action:enable": "Toggle.sideMenuCellEnabled",
			"deferred (#1002): plain Settings and model deletion": "Button.drawerSettings Button.sideMenuDeleteConfiguration "
				+ "Button.sideMenuDeleteConfigurationMenu Button.sideMenuDeleteConfigurationConfirm"
		],
		"Auth/SignInSheet.swift": ["action:sign-in": "Button.authSignIn", "action:close": "Button.signInSheetCancel"],
		"SettingsView/SettingsView.swift": [
			"action:close": "Button.settingsDismiss", "action:set-backup": "Toggle.findingsBackUp",
			"action:remove-all-findings": "Button.settingsRemoveFindings Button.settingsRemoveFindingsConfirm",
			"Clerk's profile, where sign-out lives; headless signs out directly": "NavigationLink.settingsManageAccount",
			"sign-in is offered from the drawer footer": "Button.settingsSignIn",
			"export, purchasing and the tour replay are not automated": "Button.settingsRemoveFindingsExport Button.settingsUpgrade "
				+ "NavigationLink.settingsSubscription Button.settingsReplayOnboarding",
			"preferences and maintenance have no headless screen": "Button.settingsDeleteCache Button.settingsRestoreDefaults "
				+ "Button.settingsKeyboardDone Picker.settingsFrequency TextField.settingsDefaultPage TextField.settingsHistoryLimit "
				+ "Toggle.settingsDisableDetectionAnimations Toggle.settingsFullscreenDetection Toggle.settingsReadMapPositionFromPages "
				+ "Toggle.settingsReopenLastPage Toggle.settingsRunAtLaunch Toggle.settingsShowLabels NavigationLink.settingsAbout "
				+ "NavigationLink.settingsHistory NavigationLink.settingsReset NavigationLink.settingsTiledDetection"
		],
		"MLBrowser.swift": ["action:allow": "Button.analyticsChoiceEnable", "action:deny": "Button.analyticsChoiceNotNow"],
		"ConsentCard.swift": [:],
		"Tour/TourBubble.swift": ["action:skip": "Button.tourSkip", "headless tour steps are out of scope": "Button.tourNext"],
		"Subscription/WelcomeView.swift": ["action:continue": "Button.welcomeContinue"],
		"Subscription/PaywallView.swift": [
			"purchasing, export and external pages are not automatable": "Button.paywallSubscribe Button.paywallSubscribeAnyway "
				+ "Button.paywallRestore Link.paywallManage Button.paywallFindingsExport Button.paywallDeleteAccountExportFindings "
				+ "Button.paywallPrivacyPolicy",
			"account and findings actions on the wall have no headless screen yet": "Button.paywallSignIn Button.paywallSignOut "
				+ "Button.paywallDeleteAccount Button.paywallDeleteAccountConfirm Button.paywallDeleteAccountManage "
				+ "Button.paywallFindingsDelete Button.paywallRemoveFindings",
			"the free window is seeded by launch options; the wall's dismiss needs access": "Button.paywallKeepFreeAccess Button.paywallDismiss"
		],
		"Findings/SaveFindingSheet.swift": [
			"action:save": "Button.saveFindingSave", "action:cancel": "Button.saveFindingCancel",
			"fields are parameters of save": "TextField.saveFindingTitle TextField.saveFindingLabel TextField.saveFindingNote "
				+ "TextField.saveFindingAuthor TextField.saveFindingGps TextField.saveFindingPage Button.saveFindingSuggestion",
			"clipboard and image framing only": "Button.saveFindingCopyGps Button.saveFindingCopyPage Slider.saveFindingZoom "
				+ "Slider.saveFindingHighlightOpacity"
		],
		"Findings/FindingsListView.swift": [
			"action:close": "Button.findingsDismiss", "action:synchronize": "Button.findingsBackUp", "action:delete": "Button.findingsDeleteEntry",
			"detail, sharing, export and import leave the list or the app": "Button.findingsItem Button.findingsShareEntry "
				+ "Button.findingsExport Button.findingsImport Button.findingsDataMenu",
			"help sheet; headless answers the back-up question instead": "Button.findingsSyncHelp Button.findingsBackUpEverything",
			"list presentation only": "Button.findingsFilterLabel Button.findingsSortByDate Button.findingsSortByHost "
				+ "Button.findingsSortByTitle Button.findingsSortOrder Button.findingsSortReverse Picker.findingsTab"
		],
		"Findings/BackupConsentPrompt.swift": ["action:accept": "Button.backupConsentConfirm", "action:decline": "Button.backupConsentDecline"],
		"GlobalToolbar.swift": [
			"action:open-drawer": "Button.globalToolbarSideMenu",
			"live detection and tuning need the web view; headless runs detect-image": "Button.globalToolbarFind "
				+ "Button.globalToolbarAdjustments Button.globalToolbarPlayDetection Button.globalToolbarPauseDetection"
		]
	]

	/// Everything else under `UI/`: a directory (trailing `/`) or a top-level file, with the reason.
	private static let uncovered: [String: String] = [
		"Annotation/": "detection overlays", "AppMessages/": "remote messages are not asserted headlessly",
		"Auth/": "account deletion and Clerk wrappers; the sign-in sheet is covered", "Catalog/": "model catalog",
		"Configuration/": "model settings (deferred, #1002)", "Downloder/": "downloads", "Drawer/": "drawer chrome; its content is covered",
		"FileImporter/": "model import", "Findings/": "finding detail, sharing and received links; list, save and back-up are covered",
		"Modifiers/": "view modifiers", "Screens/": "the web screen needs a WKWebView",
		"SettingsView/": "preference sub-screens; Settings itself is covered", "Subscription/": "subscription status and helpers",
		"Support/": "support requests", "Tour/": "tour overlay drawing; the bubble is covered",
		"AlertItem.swift": "model", "Appearance.swift": "styling", "AppEntry.swift": "entry point", "ContentView.swift": "root layout",
		"EmailController.swift": "mail composer", "FloatingChromeButton.swift": "chrome", "FloatingNavBar.swift": "chrome",
		"LocationSheetView.swift": "map location capture", "NavigationBarItems.swift": "chrome",
		"SnapAdjustmentOverlay.swift": "detection tuning", "SnapAdjustmentView.swift": "detection tuning",
		"ViewContainer.swift": "layout", "WebLoadFailureOverlay.swift": "the web screen needs a WKWebView", "WebView.swift": "the web screen needs a WKWebView"
	]

	func test_everyControlOnACoveredView_isMappedOrExplained_andEveryViewIsDeclared() throws {
		let iOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("MLBrowser/iOS")
		let views = try Self.swiftFiles(under: iOS.appendingPathComponent("UI"))
		let headless = try Self.swiftFiles(under: iOS.appendingPathComponent("Headless"))
		XCTAssertFalse(views.isEmpty || headless.isEmpty, "the scan found no sources; it is broken, not clean")
		let actionNames = try Set(headless.values.flatMap { try Self.matches(#""([a-z]+(?:-[a-z]+)*)""#, in: Self.source($0)) })

		for (path, url) in views {
			if let entries = Self.covered[path] {
				let mapped = Set(entries.values.flatMap { $0.split(separator: " ").map(String.init) })
				let found = try Set(Self.matches(#"Testability\.([A-Za-z]+\.[A-Za-z0-9_]+)"#, in: Self.source(url))
					.filter { Self.passiveKinds.contains(String($0.prefix { $0 != "." })) == false })
				for control in found.subtracting(mapped).sorted() {
					XCTFail("\(path): \(control) has no headless action and no reason — add it to `covered`")
				}
				for control in mapped.subtracting(found).sorted() {
					XCTFail("\(path): \(control) is mapped but no longer used — remove it from `covered`")
				}
				for action in Set(entries.keys.filter { $0.hasPrefix("action:") }.map { String($0.dropFirst(7)) })
				where actionNames.contains(action) == false {
					XCTFail("\(path): headless action '\(action)' does not exist under Headless/")
				}
			} else if Self.uncovered.keys.contains(where: { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }) == false {
				XCTFail("UI/\(path) is neither a covered view nor in a declared uncovered area — add it to `covered` or `uncovered`")
			}
		}
		for entry in Set(Self.covered.keys).union(Self.uncovered.keys).sorted()
		where views.keys.contains(where: { entry.hasSuffix("/") ? $0.hasPrefix(entry) : $0 == entry }) == false {
			XCTFail("UI/\(entry) is declared but no longer exists")
		}
	}

	/// `*.swift` under `root`, keyed by path relative to it.
	private static func swiftFiles(under root: URL) throws -> [String: URL] {
		let paths = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root.path) as [String]?)
		return Dictionary(uniqueKeysWithValues: paths.filter { $0.hasSuffix(".swift") }.map { ($0, root.appendingPathComponent($0)) })
	}

	/// The file without its `//` comment lines; throws when unreadable.
	private static func source(_ url: URL) throws -> String {
		try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
			.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") == false }.joined(separator: "\n")
	}

	private static func matches(_ pattern: String, in text: String) throws -> [String] {
		try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
			.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
	}
}
