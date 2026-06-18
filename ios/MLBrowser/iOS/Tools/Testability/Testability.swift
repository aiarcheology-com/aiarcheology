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
		case configurationFormDismiss
		case configurationFormCancel
		case configurationExapandableRow
		// New Configuration
		case newConfigurationPickDocument
		case newConfigurationPickUrl
		// Settings
		case settingsDismiss
		case settingsDeleteCache
		case settingsRestoreDefaults
		case settingsKeyboardDone
		case settingsReplayOnboarding
		// Browsing History
		case browsingHistoryClear
		case browsingHistoryDismiss
		case browsingHistoryCopyUrl
		case browsingHistoryDeleteEntry
		case browsingHistorySetDefaultPage
		// App Description
		case appDescriptionEmailContact
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
		case settingsTiledDetection
		// Side Menu Cell
		case sideMenuCellEnabled
	}
	
	enum Picker: String, TestabilityIdentification {
		// Settings
		case settingsFrequency
		// Configuration Form
		case configurationFormSymbol
		// Finding Share Composer
		case findingShareTheme
		case findingShareLayout
	}
	
	enum Slider: String, TestabilityIdentification {
		// Configuration Form
		case configurationFormFadeOutTime
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
	}
	
	enum NavigationLink: String, TestabilityIdentification {
		// Settings
		case settingsHistory
		case settingsAbout
		// App Description
		case appDescriptionPrivacyPolicy
		// Downloader
		case downloaderListItem
		// Grid View
		case gridViewDetailItem
	}
	
	enum Label: String, TestabilityIdentification {
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
	}
	
	enum TextField: String, TestabilityIdentification {
		case downloadDetailUrl
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
	}
	
	enum ImageView: String, TestabilityIdentification {
		case anImageView
	}
	
	enum View: String, TestabilityIdentification {
		case aView
		// Onboarding tour coach-mark bubble.
		case tourBubble
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
		/// The active onboarding-tour step's target id (e.g. `addressBar`); absent when no tour runs (AIA-0333).
		case tourStep
		/// `true` once a detection cycle has applied a frame, so a manual finding pick uses that
		/// frame synchronously instead of the fragile fresh-snapshot fallback. Lets UI tests wait
		/// for detection to warm up before tapping the map, de-flaking the tour happy path on slow
		/// CI runners (AIA-0333).
		case detectionFrameApplied
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
