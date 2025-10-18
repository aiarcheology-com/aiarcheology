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
	}

	func metadata() -> [MLModelMetadataKey : Any]? {
		mlModel?.modelDescription.metadata
	}

	func loadFile() async throws {
		print("Model to be loaded from \(self.params.file?.absoluteString ?? "")")
		guard let path = self.params.file else {
			assert(false, "The DeeepConfiguration.file is not initialised or can not infer the completePath.")
			return
		}

		guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
			throw DetectorError.loadError
		}
		print("Model loaded from: \(path)")
		objectDetectionModel = try VNCoreMLModel(for: model)

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

actor ResultsCollector<T: VNObservation> {
	var collectedResults = [(observations: [T], params: DeepDriverParams)]()

	func append(_ result: (observations: [T], params: DeepDriverParams)) {
		collectedResults.append(result)
	}
}
