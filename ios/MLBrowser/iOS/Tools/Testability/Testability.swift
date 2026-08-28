//
//  Testability.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 26.11.25.
//

import Foundation
import SwiftUI

// MARK: - SwiftUI Extension

extension View {
	@ViewBuilder
	func testability(_ identification: any TestabilityIdentification, section: Int? = nil, index: Int? = nil, parent: String? = nil, label: String? = nil) -> some View {
		let identifier = identification(section: section, index: index, parent: parent, label: label)
		if AppEnvironment.isRunningUITests {
			self.accessibilityIdentifier(identifier).accessibilityLabel(identifier)
		} else {
			self.accessibilityIdentifier(identifier)
		}
	}
}

// MARK: - Identification Protocol

protocol TestabilityIdentification: RawRepresentable where RawValue == String {
	func callAsFunction(section: Int?, index: Int?, parent: String?, label: String?) -> String
}

extension TestabilityIdentification {
	func callAsFunction(section: Int? = nil, index: Int? = nil, parent: String? = nil, label: String? = nil) -> String {
		let prefix = "\(String(describing: type(of: self)))"
		let labelString = label.map { "#\($0)" } ?? ""
		let indexString = index.map { "#\($0)" } ?? ""
		let sectionString = section.map { "#\($0)" } ?? ""
		let parentString = parent.map { "_in\($0)" } ?? ""
		let element = self.rawValue.prefix(1).uppercased() + String(self.rawValue.dropFirst())
		
		let identifier = Testability.aia + ":" + prefix + "." + labelString + element
		+ sectionString + indexString + parentString
		
		return identifier
	}
}

// MARK: - Testability Constants & Enums

@objc class Testability: NSObject {
	/// The constansts are part of contract with the QA. The values are checked in the UI tests.
	@objc static let valueTrue = "true"
	@objc static let valueFalse = "false"
	
	static let aia = "_AIA"
	
	static func isValid(_ identifier: String?) -> Bool {
		identifier.map { $0.hasPrefix(aia + ":") } ?? false
	}
	
	enum Button: String, TestabilityIdentification {
		// Download Detail
		case downloadDetailClear
		case downloadDetailDone
		case downloadDetailHelp
		case downloadDetailState
		case downloadDetailCancel
		case downloadDetailDismiss
		case downloadDetailImport
		case downloadDetailCopyUrl
		// Downloader
		case downloaderDone
		case downloaderAddDownload
		case downloaderListItemDelete
		// Side Menu
		case sideMenuAddConfiguration
		case sideMenuClose
		case sideMenuConfigurationCell
		case sideMenuDeleteConfiguration
		// Configuration Form
		case configurationFormConversionLog
		case configurationFormExport
		case configurationFormDismiss
		case configurationFormCancel
		case configurationFormSoundChoice
		case configurationExapandableRow
		// New Configuration
		case newConfigurationPickDocument
		case newConfigurationPickUrl
		case newConfigurationOpenCatalog
		// Model Catalog
		case catalogDownloads
		case catalogResult
		case catalogProviderFilter
		case catalogTaskFilter
		case catalogFamilyFilter
		case catalogClearFilters
		// Settings
		case settingsDismiss
		case settingsDeleteCache
		case settingsRestoreDefaults
		case settingsKeyboardDone
		case settingsReplayOnboarding
		// AIA-0303: Settings → Reset → Remove Findings (row, export-first action, delete confirm)
		case settingsRemoveFindings
		case settingsRemoveFindingsExport
		case settingsRemoveFindingsConfirm
		// Sign-in, offered contextually (AIA-0340, moved out of the root gate by AIA-0536)
		case authSignIn
		case signInSheetCancel
		case settingsSignIn
		case drawerSignIn
		case drawerAccount
		// Paywall / subscriptions (AIA-0343)
		/// Settings → Account → Subscription, while payments are on and nothing is owned. The row
		/// used to be inert; it opens the paywall from AIA-0556 on, which is the only place a
		/// free-window user can subscribe without waiting to be walled.
		case settingsUpgrade
		case paywallSubscribe
		/// The two choices in the free-days confirmation alert (AIA-0623), shown when Subscribe is
		/// tapped while an app-managed window is still open. Identified rather than matched by text
		/// so a future test does not depend on localized copy.
		///
		/// **Neither identifier is proven to work, for two independent reasons.** No automated test
		/// can reach them today: the mock subscription provider exposes no `Product`, so the button
		/// that raises the alert is never rendered under UI testing. And SwiftUI bridges alert
		/// actions to `UIAlertController`, which is not documented to carry a button's
		/// accessibility identifier across — check the AX inspector before writing a test that
		/// depends on either of these rather than assuming they are hooks.
		case paywallKeepFreeAccess
		case paywallSubscribeAnyway
		case paywallRestore
		/// Closes the paywall when it is an *offer* rather than a wall (AIA-0616) — present only
		/// when `isDeadEnd` is false, i.e. never on the root gate.
		case paywallDismiss
		/// The Privacy Policy link in the paywall's legal footer. Schedule 2 §3.8(b) requires it to
		/// be *functional*, which is why a test taps it and checks the sheet has content (AIA-0616).
		case paywallPrivacyPolicy
		/// Manage Subscription offered from the delete-account confirmation (AIA-0528), so the
		/// warning that billing continues comes with a way to act on it. A `Button`, not a `Link`:
		/// a confirmation dialog omits any action whose label is not `Text`.
		case paywallDeleteAccountManage
		case paywallSignIn
		case paywallSignOut
		/// Delete Account on the root paywall — the other half of the Apple 5.1.1(v) escape, so a
		/// test can drive it without depending on localized button text.
		case paywallDeleteAccount
		/// The destructive action inside the delete-account confirmation dialog. It shares its
		/// label with the button that opens it, so a test cannot tell them apart by text alone.
		case paywallDeleteAccountConfirm
		/// The findings escape hatch on the hard wall (AIA-0556) and the two choices inside its
		/// confirmation. Present only where the paywall is a dead end, so its absence is itself the
		/// assertion that an informational free-access paywall — not the wall — is showing.
		case paywallRemoveFindings
		case paywallFindingsExport
		case paywallFindingsDelete
		/// Continue past the day-0 welcome screen (AIA-0567). The welcome screen's *only* action, so
		/// a test that finds it knows the user was shown the zero-pressure screen rather than a
		/// purchase screen — there is no Subscribe or Restore beside it to disambiguate.
		case welcomeContinue
		// Optional analytics first-run choice
		case analyticsChoiceEnable
		case analyticsChoiceNotNow
		/// The back-up question raised over any screen once findings exist that this account has
		/// never agreed to send (AIA-727).
		case backupConsentConfirm
		case backupConsentDecline
		/// The always-visible back-up button at the bottom of the findings sheet (AIA-740).
		case findingsBackUp
		// App Messages (AIA-0115)
		case appMessageDismiss
		case appMessageReply
		// Browsing History
		case browsingHistoryClear
		case browsingHistoryDismiss
		case browsingHistoryCopyUrl
		case browsingHistoryDeleteEntry
		case browsingHistorySetDefaultPage
		// App Description
		case appDescriptionEmailContact
		case supportSettingsSendEmail
		// Support Request — share the application log outside email (AIA-0602)
		case supportRequestShareApplicationLog
		// Global Toolbar
		case globalToolbarSideMenu
		case globalToolbarPlayDetection
		case globalToolbarPauseDetection
		case globalToolbarAdjustments
		case globalToolbarFind
		// Floating Chrome Button
		case floatingChromeToggle
		// Floating Nav Bar
		case floatingNavBack
		case floatingNavForward
		case floatingNavReload
		case floatingNavFind
		// Web Screen
		case webScreenAddressBar
		case webScreenAddressClear
		case webToolbarBack
		case webToolbarForward
		case webToolbarReload
		// Location Sheet
		case locationSheetOpen
		case locationSheetDismiss
		case locationSheetHistoryItem
		case locationSheetSortOrder
		case locationSheetFullUrls
		case locationSheetVisitTrail
		case locationSheetCopyUrl
		case locationSheetDeleteEntry
		case locationSheetSetHomePage
		case visitTrailData
		case visitTrailDeleteSite
		case dataSheetDeleteCookies
		case visitTrailItem
		case visitTrailCopyUrl
		case visitTrailDeleteEntry
		// Drawer
		case drawerSettings
		case drawerFindings
		// Save Finding
		case saveFindingSave
		case saveFindingCancel
		case saveFindingSuggestion
		case findPickCancel
		// Findings
		case findingsDismiss
		case findingsImport
		case findingsItem
		case findingsFilterLabel
		case findingsDeleteEntry
		case findingsOpenPage
		case findingsExport
		case findingsSortOrder
		case findingsShareEntry
		case findingDetailSave
		case findingDetailShare
		case findingShareConfirm
		case findingShareCancel
		/// Copies the exact address the link will carry. Present only while an address travels, so its
		/// absence asserts that nothing is being disclosed rather than that copying merely failed.
		case findingShareCopyAddress
		// Shared finding links (AIA-0650) — the read-only screen a recipient sees.
		/// Closes the shared-finding screen. The ONLY control that clears the pending link, so a test
		/// that taps it is exercising the one dismissal path the buffer recognises.
		case sharedFindingDismiss
		/// Browses to the page the link says the finding was captured on. Present only when the link
		/// carried one, so its absence is itself the assertion that no page travelled.
		case sharedFindingOpenPage
		/// Shown instead of the unverified card when the id in the link matches a finding this device
		/// already stores — it opens the findings inventory rather than the link's copy of the work.
		case sharedFindingOpenOwn
		/// Loads the map for the link's coordinate. Its presence is the assertion that no map was
		/// mounted on arrival — tiles are only fetched for a sender-chosen point once tapped.
		case sharedFindingShowMap
		/// Copies the full address a received link would open. Present whenever the link carried a
		/// page, so a recipient can inspect the destination outside the app before trusting it.
		case sharedFindingCopyAddress
		// Snap Adjustment
		case snapAdjustmentReset
		case snapAdjustmentOverlayDismiss
		// Onboarding Tour
		case tourSkip
		case tourNext
		// Grid View
		case gridViewRemoveItem
		// Dismiss
		case appDescriptionDismiss
	}
	
	enum Toggle: String, TestabilityIdentification {
		/// The cloud back-up switch in Settings (AIA-744).
		case findingsBackUp
		// Settings
		case settingsRunAtLaunch
		case settingsShowLabels
		case settingsReopenLastPage
		case settingsFullscreenDetection
		case settingsDisableDetectionAnimations
		case settingsAnalytics
		// AIA-0426: Tiled Detection submenu + Debug tiled-border overlay
		case settingsPyramidTiling
		case settingsGrid3x3Tiling
		case settingsTiledBorders
		// AIA-0602: detailed application log, kept across launches
		case settingsDetailedLogging
		case supportSettingsDetectScreenshots
		case supportRequestIncludeApplicationLog
		case supportRequestSendUnredactedData
		// Configuration Form — per-model finding flash (AIA-0374)
		case configurationFormFlashOnFinding
		// Configuration Form — per-model annotation sound (AIA-0716)
		case configurationFormSoundEnabled
		// Finding Share Composer — attach an openable link (AIA-0650)
		case findingShareIncludeLink
		// Finding Share Composer — carry the page's whole address, or only its site (AIA-0657)
		case findingShareFullAddress
		// Side Menu Cell
		case sideMenuCellEnabled
	}
	
	enum Picker: String, TestabilityIdentification {
		// Settings
		case settingsFrequency
		// Model Catalog
		case catalogProvider
		// Configuration Form
		case configurationFormSymbol
		case configurationFormModelType
		case configurationFormComputeUnits
		// Finding Share Composer
		case findingShareTheme
		case findingShareLayout
	}
	
	enum Slider: String, TestabilityIdentification {
		// Configuration Form
		case configurationFormFadeOutTime
		case configurationFormFlashSize
		case configurationFormDetectionConfidence
		case configurationFormSoundVolume
		// Snap Adjustment
		case snapAdjustmentBrightness
		case snapAdjustmentContrast
		case snapAdjustmentSaturation
		// Save Finding
		case saveFindingHighlightOpacity
		case saveFindingZoom
		case findingDetailHighlightOpacity
		case findingDetailZoom
		case findingShareZoom
	}

	enum ColorPicker: String, TestabilityIdentification {
		case configurationFormAnnotationColor
	}
	
	enum Link: String, TestabilityIdentification {
		// New Configuration
		case newConfigurationAppleDocumentation
		case newConfigurationCoreMLConverters
		// App Description
		case appDescriptionWebsite
		case appDescriptionTwitter
		// Paywall / subscriptions (AIA-0343)
		case paywallManage
	}
	
	enum NavigationLink: String, TestabilityIdentification {
		// Settings
		case settingsTiledDetection
		case configurationFormSound
		case settingsHistory
		case settingsAbout
		case settingsReset
		case settingsManageAccount
		case settingsSubscription
		// App Description
		case appDescriptionPrivacyPolicy
		case appDescriptionReportProblem
		// Downloader
		case downloaderListItem
		// Grid View
		case gridViewDetailItem
	}
	
	enum Label: String, TestabilityIdentification {
		case drawerAccountOffline
		case settingsAccountOffline
		/// The note under Settings → Manage Account saying deletion does not stop billing
		/// (AIA-0528). Shown only while subscribed.
		case settingsDeleteBillingNote
		case downloadDetailProgressWritten
		case downloadDetailProgressExpected
		// Side Menu Cell
		case sideMenuCellDescription
		// Browsing History row
		case browsingHistoryItem
		// List Item
		case listItemFileName
		case listItemState
		// Snap Adjustment
		case snapAdjustmentBrightnessValue
		case snapAdjustmentContrastValue
		case snapAdjustmentSaturationValue
		// App Messages (AIA-0115)
		case appMessageTitle
		case appMessageAboutRow
		case appMessageSettingsRow
		/// The welcome screen's free-access headline (AIA-0567) — "Explore everything free for 14
		/// days". Identified so a test can read back the granted length the screen actually rendered,
		/// which is remote-configurable, without matching localized copy.
		case welcomeHeadline
		/// The annotation sound screen's standing note that playback follows Silent mode
		/// (AIA-0720). Always present; iOS exposes no API for the Silent switch, so this note is
		/// the only coverage that case can have.
		case configurationFormSoundOutputNote
		/// The annotation sound screen's warning that device media volume is zero (AIA-0720).
		/// Unlike the note above this one is detectable, so it is shown conditionally.
		case configurationFormSoundOutputMuted
	}

	enum TextField: String, TestabilityIdentification {
		case downloadDetailUrl
		// Model Catalog
		case catalogSearch
		// Settings
		case settingsDefaultPage
		case settingsHistoryLimit
		// Location Sheet
		case locationSheetInput
		// Save Finding
		case saveFindingTitle
		case saveFindingLabel
		case saveFindingNote
		case saveFindingAuthor
		case saveFindingGps
		// Finding Detail
		case findingDetailTitle
		case findingDetailLabel
		case findingDetailNote
		case findingDetailAuthor
		case findingDetailGps
	}
	
	enum Stepper: String, TestabilityIdentification {
		case gridViewColumnStepper
	}
	
	enum ProgressView: String, TestabilityIdentification {
		case downloadDetailProgress
		case listItemProgress
	}
	
	enum List: String, TestabilityIdentification {
		case sideMenuConfigurationList
		case downloaderList
		case browsingHistoryList
		case gridViewList
		case catalogResults
	}
	
	enum ImageView: String, TestabilityIdentification {
		case anImageView
	}
	
	enum View: String, TestabilityIdentification {
		case aView
		/// The vertically scrollable paywall content (AIA-0564). Identified so the landscape
		/// regression test can prove every required purchase and account control remains reachable.
		case paywallContent
		/// The vertically scrollable welcome content (AIA-0567). Identified for the same reason its
		/// paywall sibling is: the landscape test needs a scroll view to drive before it can prove
		/// the footer bullets and the price note stay reachable on a short viewport.
		case welcomeContent
		/// The provenance banner on a shared finding (AIA-0650) — "this came from a link and has not
		/// been verified". Identified because that sentence is the whole security posture of the
		/// screen: Associated Domains authenticates the domain, never the fields, so a test must be
		/// able to prove the warning is on screen without matching localized copy.
		case sharedFindingProvenance
		/// The "we could not read this link" screen (AIA-0650). Identified so a test can prove the app
		/// says *something* when a damaged link opens it — the association matches on path alone, so
		/// iOS routes a truncated link here instead of to the landing page that explains it.
		case sharedFindingUnreadable
		/// The exact address a shared link will carry, shown to the sender before they post it
		/// (AIA-0657). Identified because it is the mechanism behind the ticket's credential
		/// criterion: a test must be able to read what is on screen without matching localized copy.
		case findingShareAddressPreview
		/// The full address a received link will open, shown beside its button (AIA-0659). Identified
		/// because the disclosure IS the phishing mitigation: a test must be able to prove the whole
		/// address is on screen — not the host that a lookalike domain imitates — without matching
		/// localized copy.
		case sharedFindingAddress
		/// The page diagram on a received link (AIA-0657): where on the captured page the detection
		/// sat. Identified because it is the visible half of the ticket's first criterion, and the
		/// half no localized string can stand in for.
		case sharedFindingBoxDiagram
		// Onboarding tour coach-mark bubble.
		case tourBubble
		// App Messages banner container (AIA-0115)
		case appMessageBanner
	}

	/// State-introspection probes for UI tests. A `.checkpoint(_:value:)` modifier
	/// publishes the current value of one of these as a hidden accessibility element
	/// (`_AIA:Checkpoint.<Case>`), so a UI test can assert internal state that is not
	/// otherwise reachable through the visible accessibility tree. Inert outside UI tests.
	enum Checkpoint: String, TestabilityIdentification {
		/// Which page the browser decided to load at launch: `home` / `last` / `blank`.
		case intendedPageKind
		/// `compact` / `regular` — the active horizontal size class.
		case horizontalSizeClass
		/// `true` / `false` — whether fullscreen detection is enabled in settings.
		case fullscreenFeatureEnabled
		/// The current `AppMode` raw value.
		case appMode
		/// `phone` / `pad` — the device idiom that drives chrome layout (AIA-0294).
		case deviceIdiom
		/// Last path component of the live web view URL (e.g. `uitest_page.html`). Lets UI tests
		/// confirm which page is actually loaded — including host-less `file://` fixtures (AIA-0316).
		case currentPageFile
		/// Count of currently rendered detection annotations (AIA-0317). Lets UI tests assert
		/// `>= 1` after a detection run; `0` when none are drawn.
		case detectionCount
		/// Number of snapshots admitted past DetectableView's interaction/capture guards. Used to
		/// prove navigation cannot strand the web surface in `.interacting` (AIA-0587).
		case snapshotDeliveryCount
		/// Count of tile-border outlines the "Tiled Borders" overlay is drawing (AIA-0426):
		/// `regions(for:)` count when on, `0` when off. Lets UI tests assert the overlay renders.
		case tiledBorderCount
		/// The active onboarding-tour step's target id (e.g. `addressBar`); absent when no tour runs (AIA-0333).
		case tourStep
		/// `true` once a detection cycle has applied a frame, so a manual finding pick uses that
		/// frame synchronously instead of the fragile fresh-snapshot fallback. Lets UI tests wait
		/// for detection to warm up before tapping the map, de-flaking the tour happy path on slow
		/// CI runners (AIA-0333).
		case detectionFrameApplied
		/// Monotonic count of qualifying classification passes (AIA-0374). A counter,
		/// not a bool — checkpoint polling can never miss a transient.
		case flashCount
		/// Number of flash-participating classificators whose top-1 label currently
		/// qualifies (AIA-0374) — drives the pulse overlay's `active` state.
		case classificationCount
		/// The current top display label as "identifier=confidence" (AIA-0375) — turns
		/// "why didn't it qualify" from a guess into a read.
		case topClassification
	}

	enum MenuItem: String, TestabilityIdentification {
		case aMenuItem
	}
	
	enum Collection: String, TestabilityIdentification {
		case aCollection
	}
	
	enum SegmentedControl: String, TestabilityIdentification {
		case aSegmentedControl
	}
	
	enum SegmentedItem: String, TestabilityIdentification {
		case aSegmentedItem
		
		static func idForSegment(in segmentedControl: SegmentedControl, index: Int) -> SegmentedItem? {
			switch segmentedControl {
			case .aSegmentedControl:
				let items: [SegmentedItem] = [
					.aSegmentedItem
				]
				return items.indices.contains(index) ? items[index] : nil
			}
		}
	}
}
