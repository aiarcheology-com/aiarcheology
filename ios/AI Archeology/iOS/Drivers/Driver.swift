//
//  Driver.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 13.12.23.
//
import Vision

protocol Driver: Actor {
	func metadata() -> [MLModelMetadataKey : Any]?
	nonisolated func id() -> UUID?
	func unload() async
}
