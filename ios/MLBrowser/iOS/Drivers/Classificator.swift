//
//  Classificator.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import Vision
import SwiftUI
import UIKit
import OSLog

enum ClassificatorError: Error {
	case loadError
	case coreModelLoadError
}

actor Classificator: Classifying {
	/// How many of Vision's best-first class labels a pass keeps (AIA-0374).
	static let topLabelCount = 5

    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []
    
    private var classificationModel: VNCoreMLModel?
    private var classificationRequest: VNCoreMLRequest?
    private var handler: VNImageRequestHandler?
    private var ciImage: CIImage?
    private var mlModel: MLModel?

	func metadata() -> [MLModelMetadataKey: Any]? {
        mlModel?.modelDescription.metadata
	}

    init(params: DeepDriverParams) {
        self.id = params.entityId
        self.params = params
        LoggingPolicy.debug("Classificator initialized with ID \(id)", logger: .drivers)
    }
    
    func updateConfiguration(_ params: DeepDriverParams) async {
        self.params = params
        LoggingPolicy.debug("Classificator updated with ID \(id)", logger: .drivers)
    }

	func loadFile() async throws {
        guard let path = self.params.file else {
            LoggingPolicy.error("Classificator loadFile failed: file path is nil", logger: .drivers)
            throw ClassificatorError.loadError
        }

        // Log file name only: container paths can embed user data (see LOGGING_GUIDE.md).
        LoggingPolicy.debug("Loading classificator model from \(path.lastPathComponent)", logger: .drivers)

        guard let model = try await Self.loadModel(from: path, demo: params.demo, computeUnit: params.computeUnit) else {
            LoggingPolicy.error("Failed to load ML model from \(path.lastPathComponent)", logger: .drivers)
            throw ClassificatorError.loadError
        }

        LoggingPolicy.debug("Model successfully loaded from \(path.lastPathComponent)", logger: .drivers)
        self.mlModel = model
        classificationModel = try VNCoreMLModel(for: model)

        guard let classificationModel = classificationModel else {
            LoggingPolicy.error("Failed to create VNCoreMLModel from loaded model", logger: .drivers)
            throw ClassificatorError.coreModelLoadError
        }

        classificationRequest = VNCoreMLRequest(model: classificationModel)
        classificationRequest?.imageCropAndScaleOption = .centerCrop
	}

	func unload() async {
        ciImage = nil
        handler = nil
        classificationRequest = nil
        classificationModel = nil
        mlModel = nil
        observations = []
        LoggingPolicy.debug("Classificator unloaded", logger: .drivers)
	}

	func process(image: UIImage) async {
        // Clear stale state: a new frame must never report the previous frame's
        // classifications, and a failed conversion must not leave the old handler
        // around (classify() would silently re-run the previous frame).
        observations = []
        handler = nil
        ciImage = CIImage(image: image)
        guard let ciImage else {
            LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
            return
        }
        handler = VNImageRequestHandler(ciImage: ciImage)
	}

	func classify() async {
        guard let classificationRequest else {
            LoggingPolicy.debug("Classification skipped: classification request not initialized", logger: .drivers)
            return
        }

        // Without a handler there is no frame to process. Bail out before reading
        // classificationRequest.results — VNRequest retains the previous run's results,
        // so an optional-chained no-op perform would re-report the prior frame.
        guard let handler else {
            LoggingPolicy.debug("Classification skipped: no frame to process", logger: .drivers)
            observations = []
            return
        }

        do {
            try handler.perform([classificationRequest])
            // perform() completes synchronously, so results can be read directly here.
            // The previous Task-based completion proxy raced with readers and could
            // deliver the prior frame's observations.
            observations = (classificationRequest.results as? [VNClassificationObservation]) ?? []
            LoggingPolicy.debug("Classification completed with \(observations.count) observations", logger: .drivers)
        } catch {
            LoggingPolicy.error("Failed to perform classification", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performClassification"])
            observations = []
        }
        ciImage = nil
	}

	func run() async {
		await classify()
	}

	// MARK: - Classifying (AIA-0374)

	/// Atomic pass on LOCAL state only: no touch of the shared `handler`/`ciImage`/
	/// `observations` triple and no suspension points in the body, so actor
	/// reentrancy can never interleave two passes or remap the wrong frame
	/// (P4 review — awaiting the split-phase members left a reentrancy window).
	func classify(image: UIImage) async -> [ClassifiedLabel] {
		guard let classificationRequest else {
			LoggingPolicy.debug("Classification skipped: classification request not initialized", logger: .drivers)
			return []
		}
		guard let ciImage = CIImage(image: image) else {
			LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
			return []
		}
		let handler = VNImageRequestHandler(ciImage: ciImage)
		do {
			try handler.perform([classificationRequest])
			// Vision reports the FULL class distribution (e.g. all 1000 ImageNet
			// classes), best-first. Only the head is meaningful — keep the top few
			// so downstream consumers never iterate hundreds of noise labels.
			let results = (classificationRequest.results as? [VNClassificationObservation]) ?? []
			let top = results.prefix(Self.topLabelCount)
			LoggingPolicy.debug("Classification completed: \(results.count) observations, keeping top \(top.count)", logger: .drivers)
			return top.map { ClassifiedLabel(identifier: $0.identifier, confidence: $0.confidence) }
		} catch {
			LoggingPolicy.error("Failed to perform classification", error: error, logger: .drivers)
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "performClassification"])
			return []
		}
	}
}
