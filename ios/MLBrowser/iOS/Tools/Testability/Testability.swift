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
		// Auth gate (AIA-0340)
		case authSignIn
		case authOfflineRetry
		case signInSheetCancel
		case settingsSignIn
		case drawerSignIn
		case drawerAccount
		// Paywall / subscriptions (AIA-0343)
		case settingsUpgrade
		case paywallSubscribe
		case paywallRestore
		/// Continue past the paywall on the app-managed free-access window (AIA-0556). Present only
		/// where there is something to continue past, so its absence is itself the assertion that a
		/// gate or a Settings sheet is showing.
		case paywallContinue
		case paywallRequestRefund
		// AIA-0461: the Settings → Subscription "Request a Refund" row (feature-flag gated)
		case settingsRequestRefund
		case paywallSignIn
		case paywallSignOut
		/// Delete Account on the root paywall — the other half of the Apple 5.1.1(v) escape, so a
		/// test can drive it without depending on localized button text.
		case paywallDeleteAccount
		/// The destructive action inside the delete-account confirmation dialog. It shares its
		/// label with the button that opens it, so a test cannot tell them apart by text alone.
		case paywallDeleteAccountConfirm
		// Optional analytics first-run choice
		case analyticsChoiceEnable
		case analyticsChoiceNotNow
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
		case findingsItem
		case findingsFilterLabel
		case findingsDeleteEntry
		case findingsOpenPage
		case findingsExport
		case findingsShareEntry
		case findingDetailSave
		case findingDetailShare
		case findingShareConfirm
		case findingShareCancel
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
		case supportSettingsDetectScreenshots
		case supportRequestIncludeApplicationLog
		case supportRequestSendUnredactedData
		// Configuration Form — per-model finding flash (AIA-0374)
		case configurationFormFlashOnFinding
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
		// Finding Share Composer
		case findingShareTheme
		case findingShareLayout
	}
	
	enum Slider: String, TestabilityIdentification {
		// Configuration Form
		case configurationFormFadeOutTime
		case configurationFormFlashSize
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
		/// The paywall's free-access headline (AIA-0556) — "14 days free" on day 0, "7 days left" at
		/// the reminder. Identified so a test can tell the two informational paywalls apart without
		/// matching localized copy.
		case paywallFreeAccessHeadline
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
		case saveFindingGps
		// Finding Detail
		case findingDetailTitle
		case findingDetailLabel
		case findingDetailNote
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
