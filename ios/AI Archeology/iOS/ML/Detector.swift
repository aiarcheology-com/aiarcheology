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

protocol Driver {
	func load() async
	func unload() async
}

protocol DeepDriver: Driver {
	func load(image: UIImage) async
	func run() async -> (error: Error?, observations: [VNObservation])
}

actor Detector: DeepDriver {
	private var objectDetectionModel: VNCoreMLModel?
	private var handler: VNImageRequestHandler?
	private var ciImage: CIImage?
	private var detectionRequest: VNCoreMLRequest?

	func load() async {
		do {
			if let coreMLModel = try? AIArcheology(configuration: MLModelConfiguration()).model {
				objectDetectionModel = try VNCoreMLModel(for: coreMLModel)
			}
		} catch {
			print("Failed to load Vision ML model: \(error)")
		}
	}

	func unload() async {
		ciImage = nil
		objectDetectionModel = nil
	}

	func load(image: UIImage) async {
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
			detectionRequest = detectionRequest ?? VNCoreMLRequest(model: detectionModel, completionHandler: { request, error in
				if let error = error {
					print("Object detection failed: \(error)")
					continuation.resume(returning: (error, []))
					return
				}
				guard let observations = request.results as? [VNRecognizedObjectObservation] else {
					continuation.resume(returning: (error, []))
					return
				}

				continuation.resume(returning: (nil, observations))
			})

			guard let detectionRequest else {
				continuation.resume(returning: (nil, []))
				return
			}

			do {
				try handler?.perform([detectionRequest])
			} catch {
				print("Failed to perform detection: \(error)")
				continuation.resume(returning: (nil, []))
			}
		}
	}

	func run() async -> (error: Error?, observations: [VNObservation]) {
		 await detect()
	}
}

actor Classificator: DeepDriver {
	func load() async {
	}

	func unload() async {
	}

	func load(image: UIImage) async {
	}

	func classify() async -> (error: Error?, observations: [VNClassificationObservation]) {
		// TODO: TBD
		return (nil, [])
	}

	func run() async -> (error: Error?, observations: [VNObservation]) {
		await classify()
	}
}

enum DeepDriverType {
	case detector
	case classificator
}

actor ResultsCollector<T: VNRequestRevisionProviding> {
	var collectedResults = [T]()

	func append(_ results: [T]) {
		collectedResults.append(contentsOf: results)
	}
}

// Drivers factory
class DeepDrivers {
	var detectors: [DeepDriver] = []
	var classificators: [DeepDriver] = []

	func register(driver: DeepDriver, along: DeepDriverType) {
		switch along {
			case .detector:
				detectors.append(driver)
			case .classificator:
				classificators.append(driver)
		}
	}

	func detect(on image: UIImage, completion: @escaping ([VNRecognizedObjectObservation]) -> Void) {
		Task { // consider explicit detached, in case of issues
			let resultsCollector = ResultsCollector<VNRecognizedObjectObservation>()

			for detector in detectors {
				guard let detector = detector as? Detector else {
					continue
				}
				await detector.load(image: image)

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
				await classificator.load(image: image)
				
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
