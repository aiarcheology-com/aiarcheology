//
//  Annotation.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import Foundation

/// The shape drawn around a detection.
///
/// **The raw values are persisted, so they are not free to rename** (AIA-0620).
/// `DeepConfiguration.selectedSymbol` reads them straight out of the Core Data attribute
/// `selectedSymbol_` and falls back to `.circle` on any value it does not recognise. Renaming
/// `"Square"` would therefore not fail loudly — it would silently reset every existing user's
/// annotation shape to a circle, on a preference they chose deliberately.
///
/// `.square` is consequently a **storage name, not a label**: it has always drawn
/// `ObservationRectangleView` — a bounding rectangle, never a square — and since AIA-0620 it says
/// so. Only the user-facing string changed; the stored value is untouched.
public enum AnnotationSymbol: String, CaseIterable, Identifiable {
	case point = "Point"
	case square = "Square"
	case circle = "Circle"

	public var id: String { self.rawValue }

	/// Localized display name for the symbol type
	public var localizedName: String {
		switch self {
		case .point: return L10n.Symbol.point
		case .square: return L10n.Symbol.rectangle
		case .circle: return L10n.Symbol.circle
		}
	}
}

// Custom symbol crosses tasks via params; assert it is safe in this app.
extension AnnotationSymbol: @unchecked Sendable {}
