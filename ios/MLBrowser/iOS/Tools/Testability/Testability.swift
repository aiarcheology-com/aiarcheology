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
		case configurationFormDone
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
		case globalToolbarSettings
		// Snap Adjustment
		case snapAdjustmentReset
		case snapAdjustmentOverlayDismiss
		// Content View
		case contentViewAddressBarCancel
		case contentViewAddressBarHistoryItem
		// Slideshow
		case slideshowSwipeLeft
		case slideshowSwipeRight
		// Grid View
		case gridViewRemoveItem
		// Dismiss
		case slideShowDismiss
		case appDescriptionDismiss
	}
	
	enum Toggle: String, TestabilityIdentification {
		// Settings
		case settingsRunAtLaunch
		case settingsShowLabels
		case settingsReopenLastPage
		// Slideshow
		case slideshowShowNextTime
		// Side Menu Cell
		case sideMenuCellEnabled
	}
	
	enum Picker: String, TestabilityIdentification {
		// Settings
		case settingsFrequency
		// Configuration Form
		case configurationFormSymbol
	}
	
	enum Slider: String, TestabilityIdentification {
		// Configuration Form
		case configurationFormFadeOutTime
		// Snap Adjustment
		case snapAdjustmentBrightness
		case snapAdjustmentContrast
		case snapAdjustmentSaturation
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
		case settingsIntroduction
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
		// Web Screen
		case webScreenAddressBar
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
