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
		case downloadDetailClear
		case downloadDetailDone
		case downloadDetailHelp
		case downloadDetailState
		case downloadDetailCancel
		case downloadDetailDismiss
		case downloadDetailImport
	}
	
	enum CheckBox: String, TestabilityIdentification {
		case aCheckBox
	}
	
	enum SegmentedControl: String, TestabilityIdentification {
		case aSegmentedControl
	}
	
	enum Label: String, TestabilityIdentification {
		case downloadDetailProgressWritten
		case downloadDetailProgressExpected
	}
	
	enum TextField: String, TestabilityIdentification {
		case downloadDetailUrl
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
	
	enum SegmentedItem: String, TestabilityIdentification {
		case aSegmentedItem
		
		static func idForSegment(in segmentedControl: SegmentedControl, index: Int) -> SegmentedItem? {
			switch segmentedControl {
			case .aSegmentedControl:
				let items: [SegmentedItem] = [
					.aSegmentedItem,
				]
				return items.indices.contains(index) ? items[index] : nil
			}
		}
	}
}
