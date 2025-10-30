//
//  WebHistory.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import UIKit

extension WebHistoryEntry: CoreDataManageable {
	// TODO: there are multiple issues with relationships in SwiftUI
	//	public var tagsArray: [Tag] {
	//		guard let tags else {
	//			return []
	//		}
	//		return Array(_immutableCocoaArray: tags)
	//	}
}

extension WebHistoryEntry {
	public override func validateForInsert() throws {
		try super.validateForInsert()
		try validateCommon()
	}

	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		try validateCommon()
	}

	private func validateCommon() throws {
		guard entityId != nil else {
			throw ValidationError.entityIdNil
		}

		guard creationDate_ != nil else {
			throw ValidationError.creationDateNil
		}

		guard let pageURL = page, WebHistoryEntry.isValidPageURL(pageURL) else {
			throw ValidationError.invalidPageURL
		}
	}
    
    // Pure validation: avoid main-actor-only APIs here.
    private static func isValidPageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return (url.host?.isEmpty == false)
        case "file":
            return url.isFileURL
        default:
            return false
        }
    }
}

extension WebHistoryEntry: Comparable {
	public static func < (lhs: WebHistoryEntry, rhs: WebHistoryEntry) -> Bool {
		switch (lhs.creationDate_, rhs.creationDate_) {
			case (let date1?, let date2?):
				return date1 < date2
			case (nil, _):
				return true
			default:
				return false
		}
	}
}

extension WebHistoryEntry {
	enum ValidationError: LocalizedError {
		case entityIdNil
		case creationDateNil
		case invalidPageURL

		var errorDescription: String? {
			switch self {
				case .entityIdNil:
					return "Entity ID is nil."
				case .creationDateNil:
					return "Creation date is nil."
				case .invalidPageURL:
					return "Invalid page URL."
			}
		}
	}
}
