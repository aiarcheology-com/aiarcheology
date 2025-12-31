//
//  DeepDriver.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 13.12.23.
//

import UIKit
import SwiftUI
import Vision
import OSLog

public enum DeepDriverType: String, Sendable {
	case detector = "detect"
	case classificator = "classify"
	case invalid = "invalid"
}

struct DeepDriverParams: Sendable {
	var annotationColor: Color = .yellow
	var entityId: UUID
	var file: URL?
	var phaseOutTime: Double = 1.0
	var selectedSymbol: AnnotationSymbol = .circle
	var demo: Bool = false
}

// Vision result types cross tasks; results are immutable.
extension VNObservation: @unchecked @retroactive Sendable {}
extension VNRecognizedObjectObservation: @unchecked Sendable {}
extension VNClassificationObservation: @unchecked Sendable {}

actor ResultsCollector<T: VNObservation> {
	var collectedResults = [(observations: [T], params: DeepDriverParams)]()
	
	func append(_ result: (observations: [T], params: DeepDriverParams)) {
		collectedResults.append(result)
	}
}

typealias ObservationParams = (observations: [VNObservation], params: DeepDriverParams)

protocol DeepDriver: Driver, Sendable {
	var params: DeepDriverParams { get set }
	var observations: [VNObservation] { get set }
	func updateConfiguration(_ params: DeepDriverParams) async
	func process(image: UIImage) async
	func loadFile() async throws
	func run() async
	func unload() async
}

extension DeepDriver {
	@discardableResult
	static func loadModel(from path: URL, demo: Bool = false) async throws -> MLModel? {
		let modelConfiguration = MLModelConfiguration()
		// the file is already handled by copying resources in Xcode: -> mlmodelc (compiled)
		let compiledModelURL = demo ? path : try await MLModel.compileModel(at: path)
		
		do {
			LoggingPolicy.debug("Loading MLModel from \(compiledModelURL.lastPathComponent)", logger: .drivers)
			return try await MLModel.load(contentsOf: compiledModelURL, configuration: modelConfiguration)
		} catch {
			LoggingPolicy.error("Error loading MLModel", error: error, logger: .drivers)
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "loadMLModel", "path": compiledModelURL.lastPathComponent])
			return nil
		}
	}
	func updateConfiguration(_ newConfiguration: DeepConfiguration) async {
		self.params = DeepDriverParams(
			annotationColor: newConfiguration.annotationColor,
			entityId: newConfiguration.entityId,
			file: newConfiguration.file,
			phaseOutTime: newConfiguration.phaseOutTime,
			selectedSymbol: newConfiguration.selectedSymbol
		)
		LoggingPolicy.debug("Configuration updated for driver \(newConfiguration.entityId.uuidString)", logger: .drivers)
	}
}

// Drivers factory
@MainActor
class DeepDrivers: ObservableObject {
	@Published var detectors: [DeepDriver] = []
	@Published var classificators: [DeepDriver] = []
	
	func register(driver: DeepDriver, along: DeepDriverType) {
		switch along {
		case .detector:
			let alreadyRegistered = detectors.contains { $0.id == driver.id }
			if !alreadyRegistered {
				detectors.append(driver)
			}
		case .classificator:
			let alreadyRegistered = classificators.contains { $0.id == driver.id }
			if !alreadyRegistered {
				classificators.append(driver)
			}
		case .invalid:
			LoggingPolicy.error("Attempted to register driver with invalid type.", logger: .drivers)
		}
	}
	
	func update(configuration: DeepConfiguration) {
		let entityId = configuration.entityId
		let drivers = (detectors + classificators).filter { $0.id == entityId }
		if drivers.count >= 2 {
			LoggingPolicy.warning("Multiple drivers found with same configuration.entityId: \(entityId.uuidString)", logger: .drivers)
		}
		Task {
			await drivers.first?.updateConfiguration(configuration)
		}
	}
	
	func unregister(driverId: UUID) async {
		await (classificators + detectors).filter { $0.id == driverId }.first?.unload()
		detectors = detectors.filter { $0.id != driverId }
		classificators = classificators.filter { $0.id != driverId }
	}
	
	func unload(_ driver: DeepDriverType) async {
		switch driver {
		case .detector:
			// Snapshot on the main actor
			let snapshot = detectors
			await withTaskGroup(of: Void.self) { group in
				for driver in snapshot {
					group.addTask {
						await driver.unload()
					}
				}
			}
		case .classificator:
			// Snapshot on the main actor
			let snapshot = classificators
			await withTaskGroup(of: Void.self) { group in
				for driver in snapshot {
					group.addTask {
						await driver.unload()
					}
				}
			}
		case .invalid:
			LoggingPolicy.error("Attempted to unload driver with invalid type.", logger: .drivers)
		}
	}
	
	// This is the core function that takes a 2D image and detects objects in the scene.
	// For that functionality, the driver should be already registered and loaded. That is
	// controlled by the driver's related DeepConfiguation instance in CoreData.
	func detect(on image: UIImage, completion: @escaping ([ObservationParams]) -> Void) {
		Task {
			let resultsCollector = ResultsCollector<VNRecognizedObjectObservation>()
			
			for detector in detectors {
				guard let detector = detector as? Detector else {
					continue
				}
				await detector.process(image: image)
				
				await detector.detect()
				let observations = await detector.observations
				
				guard observations.isEmpty.not else { continue }  // TODO: log
				
				guard let observations = observations as? [VNRecognizedObjectObservation] else { continue }
				let result = await (observations: observations, params: detector.params)
				await resultsCollector.append(result)
			}
			
			let results = await resultsCollector.collectedResults
			await MainActor.run {
				completion(results)
			}
		}
	}
	
	func classify(on image: UIImage, completion: @escaping ([ObservationParams]) -> Void) {
		Task {
			let resultsCollector = ResultsCollector<VNClassificationObservation>()
			
			for classificator in classificators {
				guard let classificator = classificator as? Classificator else {
					continue
				}
				await classificator.process(image: image)
				
				await classificator.classify()
				let observations = await classificator.observations
				
				guard observations.isEmpty.not else { continue } // TODO: log
				
				guard let observations = observations as? [VNClassificationObservation] else { continue }
				let result = await (observations: observations, params: classificator.params)
				await resultsCollector.append(result)
			}
			
			let results = await resultsCollector.collectedResults
			await MainActor.run {
				completion(results)
			}
		}
	}
}
