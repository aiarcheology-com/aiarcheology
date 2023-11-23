//
//  Detector.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 26.09.23.
//

import CoreML
import Vision
import UIKit
import SwiftUI

protocol Driver: Actor {
	func metadata() -> [MLModelMetadataKey : Any]?
	func id() -> UUID?
	func load(from configuration: DeepConfiguration) async
	func unload() async
}

protocol DeepDriver: Driver {
	init(configuration: DeepConfiguration)
	func process(image: UIImage) async
	func run() async -> (error: Error?, observations: [VNObservation])
}

extension DeepDriver {
	@discardableResult
	static func loadModel(from path: URL) async -> MLModel? {
		do {
			let modelConfiguration = MLModelConfiguration()
			let compiledModelURL = try await MLModel.compileModel(at: path)
			return try MLModel(contentsOf: compiledModelURL, configuration: modelConfiguration)
		} catch {
			assert(false, "Failed to load model from file: \(error)")
			return nil
		}
	}
}

enum DetectorError: Error {
	case loadError
}

actor Detector: DeepDriver {
	private var internalId: UUID?
	private var objectDetectionModel: VNCoreMLModel?
	private var handler: VNImageRequestHandler?
	private var ciImage: CIImage?
	private var mlModel: MLModel?
	
	func id() -> UUID? {
		internalId
	}

	init(configuration: DeepConfiguration) {
		guard let entityId = configuration.entityId else {
			assert(false, "configuration.entityId should not be nil.")
		}
		self.internalId = entityId

		Task {
			await self.load(from: configuration)
		}
	}

	func metadata() -> [MLModelMetadataKey : Any]? {
		mlModel?.modelDescription.metadata
	}

	func load(from path: URL) async {
		do {
			guard let model = await Self.loadModel(from: path) else {
				throw DetectorError.loadError
			}
			objectDetectionModel = try VNCoreMLModel(for: model)
		} catch {
			assert(false, "Failed to load model from file: \(error)")
		}
	}

	func load(from configuration: DeepConfiguration) async {
		guard let path = configuration.file else { return }
		await load(from: path)
	}

	func unload() async {
		ciImage = nil
		objectDetectionModel = nil
	}

	func process(image: UIImage) async {
		ciImage = CIImage(image: image)
		guard let ciImage else {  return }
		handler = VNImageRequestHandler(ciImage: ciImage)
	}

	func detect() async -> (error: Error?, observations: [VNRecognizedObjectObservation]) {
		await withCheckedContinuation { continuation in
			guard let detectionModel = objectDetectionModel else {
				continuation.resume(returning: (nil, [])) // TODO: tidy up the returns
				return
			}
			let detectionRequest = VNCoreMLRequest(model: detectionModel, completionHandler: { request, error in
				if let error = error {
					assert(false, "Object detection failed: \(error)")
					continuation.resume(returning: (error, []))
					return
				}
				guard let observations = request.results as? [VNRecognizedObjectObservation] else {
					continuation.resume(returning: (error, []))
					return
				}

				continuation.resume(returning: (nil, observations))
				return
			})

			do {
				try handler?.perform([detectionRequest])
			} catch {
				assert(false, "Failed to perform detection: \(error)")
				continuation.resume(returning: (nil, []))
				return
			}
		}
	}

	func run() async -> (error: Error?, observations: [VNObservation]) {
		 await detect()
	}
}

// The application does not support the classification yet.
actor Classificator: DeepDriver {
	private var internalId: UUID?

	func metadata() -> [MLModelMetadataKey : Any]? {
		[:]
	}
	
	func id() -> UUID? {
		UUID()
	}
	
	init(configuration: DeepConfiguration) {
		guard let entityId = configuration.entityId else {
			assert(false, "configuration.entityId should not be nil.")
		}

		self.internalId = entityId

		Task {
			await self.load(from: configuration)
		}
	}

	func load(from configuration: DeepConfiguration) async {
	}
	
	func load() async {
	}

	func unload() async {
	}

	func process(image: UIImage) async {
	}

	func classify() async -> (error: Error?, observations: [VNClassificationObservation]) {
		// TODO: TBD
		return (nil, [])
	}

	func run() async -> (error: Error?, observations: [VNObservation]) {
		await classify()
	}
}

public enum DeepDriverType: String {
	case detector = "detect"
	case classificator = "classify"
}

actor ResultsCollector<T: VNRequestRevisionProviding> {
	var collectedResults = [T]()

	func append(_ results: [T]) {
		collectedResults.append(contentsOf: results)
	}
}

// Drivers factory
class DeepDrivers: ObservableObject {
	@Published var detectors: [DeepDriver] = []
	@Published var classificators: [DeepDriver] = []

	func register(driver: DeepDriver, along: DeepDriverType) {
		Task {
			guard let driverId = await driver.id() else { return }

			switch along {
				case .detector:
					let alreadyRegistered = await containsDriver(with: driverId, in: detectors)
					if !alreadyRegistered {
						await MainActor.run { detectors.append(driver) }
					}
				case .classificator:
					let alreadyRegistered = await containsDriver(with: driverId, in: classificators)
					if !alreadyRegistered {
						await MainActor.run { classificators.append(driver) }
					}
			}
		}
	}

	func unregister(driverId: UUID) {
		Task {
			let updatedDetectors = await filterDrivers(detectors, excluding: driverId)
			let updatedClassificators = await filterDrivers(classificators, excluding: driverId)

			await MainActor.run {
				detectors = updatedDetectors
				classificators = updatedClassificators
			}
		}
	}

	private func filterDrivers(_ drivers: [any DeepDriver], excluding id: UUID) async -> [any DeepDriver] {
		var updatedDrivers = [any DeepDriver]()

		for driver in drivers {
			let driverId = await driver.id()
			if driverId == id {
				await driver.unload()
			} else {
				updatedDrivers.append(driver)
			}
		}

		return updatedDrivers
	}

	private func containsDriver(with id: UUID, in drivers: [DeepDriver]) async -> Bool {
		for driver in drivers {
			let driverId = await driver.id()
			if driverId == id {
				return true
			}
		}
		return false
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
	func detect(on image: UIImage, completion: @escaping ([VNRecognizedObjectObservation]) -> Void) {
		Task { // consider explicit detached, in case of issues
			let resultsCollector = ResultsCollector<VNRecognizedObjectObservation>()

			for detector in detectors {
				guard let detector = detector as? Detector else {
					continue
				}
				await detector.process(image: image)

				let detectionResults = await detector.detect()
				let observations = detectionResults.observations

				guard
					detectionResults.error.isNil,
					observations.isEmpty.not else { continue }  // TODO: log

				await resultsCollector.append(observations)
			}

			let results = await resultsCollector.collectedResults

			await MainActor.run {
				completion(results)
			}
		}
	}

	func classify(on image: UIImage, completion: @escaping ([VNClassificationObservation]) -> Void) {
		Task { // consider explicit detached, in case of issues
			let resultsCollector = ResultsCollector<VNClassificationObservation>()

			for classificator in classificators {
				guard let classificator = classificator as? Classificator else {
					continue
				}
				await classificator.process(image: image)
				
				let classificationResults = await classificator.classify()
				let observations = classificationResults.observations

				guard
					classificationResults.error.isNil,
					observations.isEmpty.not else { continue } // TODO: log

				await resultsCollector.append(observations)
			}

			let results = await resultsCollector.collectedResults

			await MainActor.run {
				completion(results)
			}
		}
	}
}

class ObjectDetector {
    private var objectDetectionModel: VNCoreMLModel?

    init() {
        do {
            // "YourMLModel" is the name of the imported .mlmodel file
            if let coreMLModel = try? AIArcheology(configuration: MLModelConfiguration()).model {
                objectDetectionModel = try VNCoreMLModel(for: coreMLModel)
            }
        } catch {
            print("Failed to load Vision ML model: \(error)")
        }
    }

    func detectObjects(in image: UIImage, completion: @escaping ([VNRecognizedObjectObservation]?) -> Void) {
        guard let detectionModel = objectDetectionModel else { return }
        let objectDetectionRequest = VNCoreMLRequest(model: detectionModel, completionHandler: { request, error in
            self.handleDetection(request: request, error: error, completion: completion)
        })

        guard let ciImage = CIImage(image: image) else { return }
        let handler = VNImageRequestHandler(ciImage: ciImage)

        do {
            try handler.perform([objectDetectionRequest])
        } catch {
            print("Failed to perform detection: \(error)")
            completion(nil)
        }
    }

    private func handleDetection(request: VNRequest, error: Error?, completion: ([VNRecognizedObjectObservation]?) -> Void) {
        if let error = error {
            print("Object detection failed: \(error)")
            completion(nil)
            return
        }

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            completion(nil)
            return
        }

        completion(observations)
    }
}
