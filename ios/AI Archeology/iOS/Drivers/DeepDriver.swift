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

public enum DeepDriverType: String {
	case detector = "detect"
	case classificator = "classify"
}

struct DeepDriverParams {
	var annotationColor: Color = .yellow
	var entityId: UUID?
	var file: URL?
	var phaseOutTime: Double = 1.0
	var selectedSymbol: AnnotationSymbol = .circle
	var demo: Bool = false
}

typealias ObservationParams = (observations: [VNObservation], params: DeepDriverParams)

protocol DeepDriver: Driver {
	var params: DeepDriverParams { get set }
	var observations: [VNObservation] { get set }
	func updateConfiguration(_ newConfiguration: DeepConfiguration) async
	init(configuration: DeepConfiguration, entityId: UUID) // Configuration arg. also contains UUID. But bcs of CoreData it is optional. We want to create a new driver only if the DeepConfiguration is complete, with UUID.
	func process(image: UIImage) async
	func loadFile() async throws
	func run() async
}

extension DeepDriver {
	@discardableResult
	static func loadModel(from path: URL, demo: Bool = false) async throws -> MLModel? {
		let modelConfiguration = MLModelConfiguration()
			// the file is already handled by copying resources in Xcode: -> mlmodelc (compiled)
		let compiledModelURL = demo ? path : try await MLModel.compileModel(at: path)

		do {
			Logger.drivers.logDebug("Loading MLModel from \(compiledModelURL.lastPathComponent, privacy: .public)")
			return try MLModel(contentsOf: compiledModelURL, configuration: modelConfiguration)
		}
		catch {
			Logger.drivers.logError("Error loading MLModel: \(error.localizedDescription, privacy: .public)")
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
		Logger.drivers.logDebug("Configuration updated for driver \(newConfiguration.entityId?.uuidString ?? "unknown", privacy: .public)")
	}
}

// Drivers factory
class DeepDrivers: ObservableObject {
	@Published var detectors: [DeepDriver] = []
	@Published var classificators: [DeepDriver] = []

    func register(driver: DeepDriver, along: DeepDriverType) {
        Task {
            switch along {
            case .detector:
                let alreadyRegistered = detectors.contains { $0.id == driver.id }
                if !alreadyRegistered {
                    await MainActor.run {
                        detectors.append(driver)
                    }
                }
            case .classificator:
                let alreadyRegistered = classificators.contains { $0.id == driver.id }
                if !alreadyRegistered {
                    await MainActor.run {
                        classificators.append(driver)
                    }
                }
            }
        }
	}

	func update(configuration: DeepConfiguration) {
        guard let entityId = configuration.entityId else {
            Logger.drivers.logError("Cannot update driver: Configuration.entityId is nil")
            return
        }
		let drivers = (detectors + classificators).filter { $0.id == entityId }
		if drivers.count >= 2 {
			Logger.drivers.logWarning("Multiple drivers found with same configuration.entityId: \(entityId.uuidString, privacy: .public)")
		}
		Task {
			await drivers.first?.updateConfiguration(configuration)
		}
	}


	func unregister(driverId: UUID) {
		Task {
			await (classificators + detectors).filter { $0.id == driverId }.first?.unload()
            await MainActor.run {
                detectors = detectors.filter { $0.id != driverId }
                classificators = classificators.filter { $0.id != driverId }
            }
		}
	}

	func unload(_ driver: DeepDriverType) async {
		switch driver {
			case .detector:
				await detectors.concurrentForEach { driver in
					await driver.unload()
				}
			case .classificator:
				await classificators.concurrentForEach { driver in
					await driver.unload()
				}
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
