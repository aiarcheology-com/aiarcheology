//
//  Annotation.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import Foundation

public enum AnnotationSymbol: String, CaseIterable, Identifiable {
	case point = "Point"
	case square = "Square"
	case circle = "Circle"

	public var id: String { self.rawValue }

	/// Localized display name for the symbol type
	public var localizedName: String {
		switch self {
		case .point: return L10n.Symbol.point
		case .square: return L10n.Symbol.square
		case .circle: return L10n.Symbol.circle
		}
	}
}

// Custom symbol crosses tasks via params; assert it is safe in this app.
extension AnnotationSymbol: @unchecked Sendable {}
