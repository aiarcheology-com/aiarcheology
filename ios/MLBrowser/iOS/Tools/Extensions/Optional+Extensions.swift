//
//  Optional+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 04.11.23.
//

import Foundation

extension Optional {
	var isNil: Bool {
		return self == nil
	}
	
	var isNotNil: Bool {
		return self != nil
	}
}

extension Optional where Wrapped == String {
	var isNotBlank: Bool {
		if let a = self, a.isEmpty.not {
			return true
		} else {
			return false
		}
	}

	var isBlank: Bool {
		return !isNotBlank
	}
}

extension Optional where Wrapped: Collection {
	var isEmptyOrNil: Bool {
		return self?.isEmpty ?? true
	}
}
