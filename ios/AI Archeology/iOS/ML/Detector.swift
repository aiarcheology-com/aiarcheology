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
	func unload() async
}

protocol DeepDriver: Driver {
	var params: DeepDriverParams { get set }
	var observations: [VNObservation] { get set }
	func updateConfiguration(_ newConfiguration: DeepConfiguration) async
	init(configuration: DeepConfiguration, entityId: UUID) throws // Configuration arg. also contains UUID. But bcs of CoreData it is optional. We want to create a new driver only if the DeepConfiguration is complete, with UUID.
	func process(image: UIImage) async
	func run() async
}

extension DeepDriver {
	@discardableResult
	static func loadModel(from path: URL, demo: Bool = false) async throws -> MLModel? {
		let modelConfiguration = MLModelConfiguration()
		// the file is already handled by copying resources in Xcode: -> mlmodelc (compiled)
		let compiledModelURL = demo ? path : try await MLModel.compileModel(at: path)

		do {
			return try MLModel(contentsOf: compiledModelURL, configuration: modelConfiguration)
		}
		catch let error {
			print("Error while loading the MLModel: \(error)")
		}

		return nil
	}
	func updateConfiguration(_ newConfiguration: DeepConfiguration) async {
		self.params = DeepDriverParams(
			annotationColor: newConfiguration.annotationColor,
			entityId: newConfiguration.entityId,
			file: newConfiguration.file,
			phaseOutTime: newConfiguration.phaseOutTime,
			selectedSymbol: newConfiguration.selectedSymbol
			)
	}
}

enum DetectorError: Error {
	case loadError
	case coreModelLoadError
}

struct DeepDriverParams {
	var annotationColor: Color = .yellow
	var entityId: UUID?
	var file: URL?
	var phaseOutTime: Double = 1.0
	var selectedSymbol: AnnotationSymbol = .circle
	var demo: Bool = false
}

actor Detector: DeepDriver {
	private let internalId: UUID
	private var objectDetectionModel: VNCoreMLModel?
	private var detectionRequest: VNCoreMLRequest?
	internal var observations: [VNObservation] = []
	private var handler: VNImageRequestHandler?
	private var ciImage: CIImage?
	private var mlModel: MLModel?

	internal var params: DeepDriverParams

	nonisolated func id() -> UUID? {
		internalId
	}

	init(configuration: DeepConfiguration, entityId: UUID) throws {
		self.internalId = entityId
		self.params = DeepDriverParams(
			annotationColor: configuration.annotationColor,
			entityId: configuration.entityId,
			file: configuration.file_,
			phaseOutTime: configuration.phaseOutTime,
			selectedSymbol: configuration.selectedSymbol,
			demo: configuration.demo
		)

		guard let modelFile = configuration.file else {
			assert(false, "The DeeepConfiguration.file is not initialised or can not infer the completePath.")
			return
		}

		Task {
			try await self.load(from: modelFile)
		}
	}

	func metadata() -> [MLModelMetadataKey : Any]? {
		mlModel?.modelDescription.metadata
	}

	func load(from path: URL) async throws {
		guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
			throw DetectorError.loadError
		}
		print("Model loaded from: \(path)")
		objectDetectionModel = try VNCoreMLModel(for: model)
		print("objectDetectionModel created from: \(model)")
		guard let detecionModel = objectDetectionModel else {
			throw DetectorError.coreModelLoadError
		}
		detectionRequest = VNCoreMLRequest(model: detecionModel, completionHandler: { [weak self] request, error in
			guard let self = self else { return }
			Task {
				if let error = error {
					assert(false, "Object detection request ened up with error \(error)")
					return
				}
				guard let observations = request.results as? [VNRecognizedObjectObservation] else {
					assert(false, "Can not cast the results to expected VNRecognizedObjectObservation")
					return
				}
				await self.updateDetectionResults(observations: observations)
			}
		})
		print("detectionRequest created from: \(detecionModel)")
	}

	private func updateDetectionResults(observations: [VNRecognizedObjectObservation] = []) {
		self.ciImage = nil
		self.observations = observations
	}

	func unload() async {
		ciImage = nil
		detectionRequest = nil
		objectDetectionModel = nil
	}

	func process(image: UIImage) async {
		ciImage = CIImage(image: image)
		guard let ciImage else {  return }
		handler = VNImageRequestHandler(ciImage: ciImage)
	}

	func detect() async {
		guard let detectionRequest else {
			// Possibly no bug, just ignore the detection, when the engine is not ready to do it.
			// assert(false, "The detection request has not been initialised.")
			return
		}

		do {
			try handler?.perform([detectionRequest])
		} catch {
			assert(false, "Failed to perform detection: \(error)")
			return
		}
	}

	func run() async {
		 await detect()
	}
}

// The application does not support the classification yet.
actor Classificator: DeepDriver {
	internal var params: DeepDriverParams
	private let internalId: UUID
	internal var observations: [VNObservation] = []

	func metadata() -> [MLModelMetadataKey : Any]? {
		[:]
	}
	
	nonisolated func id() -> UUID? {
		UUID()
	}
	
	init(configuration: DeepConfiguration, entityId: UUID) throws {
		self.internalId = entityId
		self.params = DeepDriverParams()

		let detectorFileIsDirectory = false
		guard let file = try? self.params.file?.completePath(to: DeepConfiguration.rootDirectory, isDirectory: detectorFileIsDirectory) else {
			assert(false, "The DeeepConfiguration.file is not initialised.")
			return
		}

		Task {
			try await self.load(from: file)
		}
	}

	func load() async {
	}

	func load(from path: URL) async throws {
	}

	func unload() async {
	}

	func process(image: UIImage) async {
	}

	func classify() async {
		// TODO: TBD
	}

	func run() async {
		await classify()
	}
}

public enum DeepDriverType: String {
	case detector = "detect"
	case classificator = "classify"
}

actor ResultsCollector<T: VNObservation> {
	var collectedResults = [(observations: [T], params: DeepDriverParams)]()

	func append(_ result: (observations: [T], params: DeepDriverParams)) {
		collectedResults.append(result)
	}
}

typealias ObservationParams = (observations: [VNObservation], params: DeepDriverParams)

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
