//
//  Driver.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 13.12.23.
//
import Vision

protocol Driver: Actor {
	func metadata() -> [MLModelMetadataKey: Any]?
    nonisolated var id: UUID { get }
	func unload() async
}
