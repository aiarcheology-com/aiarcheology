//
//  ModelProvider.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.12.23.
//

import Foundation

enum ModelProviderError: Error {
	case importSucceeded
	case importFailed
}

protocol ModelProvider {
	func result(_ error: ModelProviderError, id: UUID)
}
