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
import OSLog

enum DetectorError: Error {
	case loadError
	case coreModelLoadError
}

actor Detector: DeepDriver {
    nonisolated let id: UUID
	private var objectDetectionModel: VNCoreMLModel?
	private var detectionRequest: VNCoreMLRequest?
	internal var observations: [VNObservation] = []
	private var handler: VNImageRequestHandler?
	private var ciImage: CIImage?
	private var mlModel: MLModel?

	internal var params: DeepDriverParams

	init(configuration: DeepConfiguration, entityId: UUID) {
        self.id = entityId
		self.params = DeepDriverParams(
			annotationColor: configuration.annotationColor,
			entityId: configuration.entityId,
			file: configuration.file,
			phaseOutTime: configuration.phaseOutTime,
			selectedSymbol: configuration.selectedSymbol,
			demo: configuration.demo
		)
		Logger.drivers.debug("Detector initialized with ID \(entityId.uuidString, privacy: .public)")
	}

	func metadata() -> [MLModelMetadataKey : Any]? {
		mlModel?.modelDescription.metadata
	}

	func loadFile() async throws {
		guard let path = self.params.file else {
			Logger.drivers.error("Detector loadFile failed: file path is nil")
			throw DetectorError.loadError
		}
		
		Logger.drivers.info("Loading detector model from \(path.absoluteString, privacy: .public)")

		guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
			Logger.drivers.error("Failed to load ML model from \(path.absoluteString, privacy: .public)")
			throw DetectorError.loadError
		}
		
		Logger.drivers.info("Model successfully loaded from \(path.lastPathComponent, privacy: .public)")
		objectDetectionModel = try VNCoreMLModel(for: model)

		guard let detecionModel = objectDetectionModel else {
			Logger.drivers.error("Failed to create VNCoreMLModel from loaded model")
			throw DetectorError.coreModelLoadError
		}
		detectionRequest = VNCoreMLRequest(model: detecionModel, completionHandler: { [weak self] request, error in
			guard let self = self else { return }
			Task {
				if let error = error {
					Logger.drivers.error("Object detection request failed: \(error.localizedDescription, privacy: .public)")
					DefaultCrashReporter.shared.recordError(error, context: ["operation": "detection"])
					return
				}
				guard let observations = request.results as? [VNRecognizedObjectObservation] else {
					Logger.drivers.warning("Detection request results could not be cast to VNRecognizedObjectObservation")
					return
				}
				await self.updateDetectionResults(observations: observations)
				Logger.drivers.debug("Detection completed with \(observations.count) observations")
			}
		})
		detectionRequest?.imageCropAndScaleOption = .scaleFit
	}

	private func updateDetectionResults(observations: [VNRecognizedObjectObservation] = []) {
		self.ciImage = nil
		self.observations = observations
	}

	func unload() async {
		ciImage = nil
		detectionRequest = nil
		objectDetectionModel = nil
		Logger.drivers.debug("Detector unloaded")
	}

	func process(image: UIImage) async {
		ciImage = CIImage(image: image)
		guard let ciImage else {
			Logger.drivers.warning("Failed to create CIImage from UIImage")
			return
		}
		handler = VNImageRequestHandler(ciImage: ciImage)
	}

	func detect() async {
		guard let detectionRequest else {
			// Possibly no bug, just ignore the detection, when the engine is not ready to do it.
			Logger.drivers.debug("Detection skipped: detection request not initialized")
			return
		}

		do {
			try handler?.perform([detectionRequest])
		} catch {
			Logger.drivers.error("Failed to perform detection: \(error.localizedDescription, privacy: .public)")
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection"])
		}
	}

	func run() async {
		 await detect()
	}
}

actor ResultsCollector<T: VNObservation> {
	var collectedResults = [(observations: [T], params: DeepDriverParams)]()

	func append(_ result: (observations: [T], params: DeepDriverParams)) {
		collectedResults.append(result)
	}
}
