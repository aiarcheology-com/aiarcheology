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

private final class ClassificatorVisionRequestProxy: @unchecked Sendable {
    weak var owner: Classificator?
    
    init(owner: Classificator) {
        self.owner = owner
    }
    
    func handleCompletion(request: VNRequest, error: Error?) {
        if let error = error {
            LoggingPolicy.error("Classification request failed", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "classification"])
            return
        }
        
        guard let observations = request.results as? [VNClassificationObservation] else {
            LoggingPolicy.warning("Classification request results could not be cast to VNClassificationObservation", logger: .drivers)
            return
        }
        
        Task {
            guard let owner = self.owner else { return }
            await owner.updateClassificationResults(observations: observations)
            LoggingPolicy.debug("Classification completed with \(observations.count) observations", logger: .drivers)
        }
    }
}

actor Classificator: DeepDriver {
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
        
        LoggingPolicy.debug("Loading classificator model from \(path.absoluteString)", logger: .drivers)
        
        guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
            LoggingPolicy.error("Failed to load ML model from \(path.absoluteString)", logger: .drivers)
            throw ClassificatorError.loadError
        }
        
        LoggingPolicy.debug("Model successfully loaded from \(path.lastPathComponent)", logger: .drivers)
        self.mlModel = model
        classificationModel = try VNCoreMLModel(for: model)
        
        guard let classificationModel = classificationModel else {
            LoggingPolicy.error("Failed to create VNCoreMLModel from loaded model", logger: .drivers)
            throw ClassificatorError.coreModelLoadError
        }
        
        let proxy = ClassificatorVisionRequestProxy(owner: self)
        classificationRequest = VNCoreMLRequest(model: classificationModel) { [proxy] request, error in
            proxy.handleCompletion(request: request, error: error)
        }
        classificationRequest?.imageCropAndScaleOption = .centerCrop
	}

	func unload() async {
        ciImage = nil
        classificationRequest = nil
        classificationModel = nil
        mlModel = nil
        LoggingPolicy.debug("Classificator unloaded", logger: .drivers)
	}

	func process(image: UIImage) async {
        ciImage = CIImage(image: image)
        guard let ciImage else {
            LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
            return
        }
        handler = VNImageRequestHandler(ciImage: ciImage)
	}
    
    func updateClassificationResults(observations: [VNClassificationObservation] = []) {
        self.ciImage = nil
        self.observations = observations
    }

	func classify() async {
        guard let classificationRequest else {
            LoggingPolicy.debug("Classification skipped: classification request not initialized", logger: .drivers)
            return
        }
        
        do {
            try handler?.perform([classificationRequest])
        } catch {
            LoggingPolicy.error("Failed to perform classification", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performClassification"])
        }
	}

	func run() async {
		await classify()
	}
}
