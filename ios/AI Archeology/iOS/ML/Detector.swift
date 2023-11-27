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
	nonisolated func id() -> UUID?
	func load(from configuration: DeepConfiguration) async throws
	func unload() async
}

protocol DeepDriver: Driver {
	var configuration: DeepConfiguration { get set }
	func updateConfiguration(_ newConfiguration: DeepConfiguration) async
	init(configuration: DeepConfiguration, entityId: UUID) throws // Configuration arg. also contains UUID. But bcs of CoreData it is optional. We want to create a new driver only if the DeepConfiguration is complete, with UUID.
	func process(image: UIImage) async
	func run() async -> (error: Error?, observations: [VNObservation])
}

extension DeepDriver {
	@discardableResult
	static func loadModel(from path: URL) async throws -> MLModel? {
		let modelConfiguration = MLModelConfiguration()
		let compiledModelURL = try await MLModel.compileModel(at: path)
		return try MLModel(contentsOf: compiledModelURL, configuration: modelConfiguration)
	}
	func updateConfiguration(_ newConfiguration: DeepConfiguration) async {
		self.configuration = newConfiguration
	}
}

enum DetectorError: Error {
	case loadError
}

actor Detector: DeepDriver {
	unowned var configuration: DeepConfiguration
	private let internalId: UUID
	private var objectDetectionModel: VNCoreMLModel?
	private var handler: VNImageRequestHandler?
	private var ciImage: CIImage?
	private var mlModel: MLModel?
	
	nonisolated func id() -> UUID? {
		internalId
	}

	init(configuration: DeepConfiguration, entityId: UUID) throws {
		self.internalId = entityId
		self.configuration = configuration

		Task {
			try await self.load(from: configuration)
		}
	}

	func metadata() -> [MLModelMetadataKey : Any]? {
		mlModel?.modelDescription.metadata
	}

	func load(from path: URL) async throws {
		guard let model = try await Self.loadModel(from: path) else {
			throw DetectorError.loadError
		}
		objectDetectionModel = try VNCoreMLModel(for: model)
	}

	func load(from configuration: DeepConfiguration) async throws {
		guard let path = configuration.file else { return }
		try await load(from: path)
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
	var configuration: DeepConfiguration
	private let internalId: UUID

	func metadata() -> [MLModelMetadataKey : Any]? {
		[:]
	}
	
	nonisolated func id() -> UUID? {
		UUID()
	}
	
	init(configuration: DeepConfiguration, entityId: UUID) throws {
		self.internalId = entityId
		self.configuration = configuration

		Task {
			try await self.load(from: configuration)
		}
	}

	func load(from configuration: DeepConfiguration) async throws {
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

actor ResultsCollector<T: VNObservation> {
	var collectedResults = [(observations: [T], configuration: DeepConfiguration)]()

	func append(_ result: (observations: [T], configuration: DeepConfiguration)) {
		collectedResults.append(result)
	}
}

// Drivers factory
class DeepDrivers: ObservableObject {
	@Published var detectors: [DeepDriver] = []
	@Published var classificators: [DeepDriver] = []

	func register(driver: DeepDriver, along: DeepDriverType) {
		guard let driverId = driver.id() else { return }

		switch along {
		case .detector:
			let alreadyRegistered = detectors.contains { $0.id() == driverId }
			if !alreadyRegistered {
				detectors.append(driver)
			}
		case .classificator:
			let alreadyRegistered = classificators.contains { $0.id() == driverId }
			if !alreadyRegistered {
				classificators.append(driver)
			}
		}
	}

	func update(driverId: UUID, configuration: DeepConfiguration) {
		let drivers = (detectors + classificators).filter { $0.id() == configuration.entityId }
		assert(drivers.count < 2, "There are more drivers to update with the same configuration.entityId.")
		Task {
			await drivers.first?.updateConfiguration(configuration)
		}
	}


	func unregister(driverId: UUID) {
		Task {
			await (classificators + detectors).filter { $0.id() == driverId }.first?.unload()
			detectors = detectors.filter { $0.id() != driverId }
			classificators = classificators.filter { $0.id() != driverId }
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
	func detect(on image: UIImage, completion: @escaping ([(observations: [VNRecognizedObjectObservation], configuration: DeepConfiguration)]) -> Void) {
		Task {
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

				let result = await (observations: observations, configuration: detector.configuration)
				await resultsCollector.append(result)
			}

			let results = await resultsCollector.collectedResults
			await MainActor.run {
				completion(results)
			}
		}
	}

	func classify(on image: UIImage, completion: @escaping ([(observations: [VNClassificationObservation], configuration: DeepConfiguration)]) -> Void) {
		Task {
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

				let result = await (observations: observations, configuration: classificator.configuration)
				await resultsCollector.append(result)
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
