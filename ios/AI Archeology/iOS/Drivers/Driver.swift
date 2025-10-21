//
//  Driver.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 13.12.23.
//
import Vision

protocol Driver: Actor {
	func metadata() -> [MLModelMetadataKey : Any]?
    // Swift 6: Implementations should use 'nonisolated(unsafe) let id: UUID' to satisfy this requirement
    // The 'unsafe' marker is safe for immutable value types like UUID that are set once during initialization
    nonisolated var id: UUID { get }
	func unload() async
}
