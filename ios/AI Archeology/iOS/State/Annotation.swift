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
}

extension AnnotationSymbol: @unchecked Sendable {}
