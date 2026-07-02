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

typealias ObservationParams = (observations: [VNObservation], params: DeepDriverParams)

/// Detect-path result: remapped value-type observations (see `DetectedObject`) per driver.
/// The classify path has its own value-type shape, `ClassificationResult` (AIA-0374).
/// `ObservationParams` above remains only for the legacy `Annotator` view modifier.
typealias DetectionResult = (observations: [DetectedObject], params: DeepDriverParams)

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
	
	func update(configuration: DeepConfiguration) async {
		let entityId = configuration.entityId
		let drivers = (detectors + classificators).filter { $0.id == entityId }
		if drivers.count >= 2 {
			LoggingPolicy.warning("Multiple drivers found with same configuration.entityId: \(entityId.uuidString)", logger: .drivers)
		}
		// toDriverParams() preserves ALL fields (including `demo`, which the previous
		// manual construction silently reset). Awaiting keeps rapid successive updates
		// ordered — the old fire-and-forget Task could apply an older config last.
		let params = configuration.toDriverParams()
		await drivers.first?.updateConfiguration(params)
	}
	
    func unregister(driverId: UUID) async {
        await (classificators + detectors).first { $0.id == driverId }?.unload()
        detectors = detectors.filter { $0.id != driverId }
        classificators = classificators.filter { $0.id != driverId }
    }

	/// Unloads and removes every registered driver.
	///
	/// Needed after batch deletes (e.g. application reset): NSBatchDeleteRequest bypasses
	/// `NSManagedObjectContextObjectsDidChange`, so per-configuration unregistration never fires.
	func unregisterAll() async {
		// Snapshot on the main actor, clear immediately so no new work targets stale drivers
		let snapshot = detectors + classificators
		detectors = []
		classificators = []
		await withTaskGroup(of: Void.self) { group in
			for driver in snapshot {
				group.addTask {
					await driver.unload()
				}
			}
		}
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
	// With tiledDetection the image is detected over 6 regions (4 quadrants + center +
	// full frame, AIA-0217); otherwise over the full frame only.
	func detect(on image: UIImage, tiledDetection: Bool, completion: @escaping ([DetectionResult]) -> Void) {
		Task {
			let regions = TileLayout.regions(tiled: tiledDetection)
			// The loop is serial inside one task — a plain array suffices.
			var results: [DetectionResult] = []

			for detector in detectors {
				guard let detector = detector as? Detector else {
					continue
				}
				let observations = await detector.detect(image: image, regions: regions)

				guard observations.isEmpty.not else { continue }  // TODO: log

				let result = await (observations: observations, params: detector.params)
				results.append(result)
			}

			await MainActor.run {
				completion(results)
			}
		}
	}
	
	// Classification counterpart of detect(): each registered classificator runs one
	// atomic pass (AIA-0374 — the split-phase process/classify orchestration moved into
	// `Classifying.classify(image:)`, the same fix detect() got). The loop is serial
	// inside one task — a plain array suffices.
	func classify(on image: UIImage, completion: @escaping ([ClassificationResult]) -> Void) {
		Task {
			var results: [ClassificationResult] = []

			for classificator in classificators {
				guard let classifying = classificator as? Classifying else {
					continue
				}
				let labels = await classifying.classify(image: image)

				guard labels.isEmpty.not else { continue }

				let result = await (labels: labels, params: classifying.params)
				results.append(result)
			}

			await MainActor.run {
				completion(results)
			}
		}
	}
}
