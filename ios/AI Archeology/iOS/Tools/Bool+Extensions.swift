//
//  Bool+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.09.23.
//

import Foundation

public extension Bool {
    @inlinable var not: Bool {
        !self
    }

	@inlinable var enabled: Bool {
		self
	}

	@inlinable var disabled: Bool {
		!self
	}
}
