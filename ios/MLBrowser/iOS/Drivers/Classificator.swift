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

fileprivate final class ClassificatorVisionRequestProxy: @unchecked Sendable {
    weak var owner: Classificator?
    
    init(owner: Classificator) {
        self.owner = owner
    }
    
    func handleCompletion(request: VNRequest, error: Error?) {
        if let error = error {
            Logger.drivers.logError("Classification request failed: \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "classification"])
            return
        }
        
        guard let observations = request.results as? [VNClassificationObservation] else {
            Logger.drivers.logWarning("Classification request results could not be cast to VNClassificationObservation")
            return
        }
        
        Task {
            guard let owner = self.owner else { return }
            await owner.updateClassificationResults(observations: observations)
            Logger.drivers.logDebug("Classification completed with \(observations.count) observations")
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

	func metadata() -> [MLModelMetadataKey : Any]? {
        mlModel?.modelDescription.metadata
	}

    init(params: DeepDriverParams) {
        self.id = params.entityId
        self.params = params
        Logger.drivers.logDebug("Classificator initialized with ID \(id)")
    }
    
    func updateConfiguration(_ params: DeepDriverParams) async {
        self.params = params
        Logger.drivers.logDebug("Classificator updated with ID \(id)")
    }

	func loadFile() async throws {
        guard let path = self.params.file else {
            Logger.drivers.logError("Classificator loadFile failed: file path is nil")
            throw ClassificatorError.loadError
        }
        
        Logger.drivers.logInfo("Loading classificator model from \(path.absoluteString)")
        
        guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
            Logger.drivers.logError("Failed to load ML model from \(path.absoluteString)")
            throw ClassificatorError.loadError
        }
        
        Logger.drivers.logInfo("Model successfully loaded from \(path.lastPathComponent)")
        self.mlModel = model
        classificationModel = try VNCoreMLModel(for: model)
        
        guard let classificationModel = classificationModel else {
            Logger.drivers.logError("Failed to create VNCoreMLModel from loaded model")
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
        Logger.drivers.logDebug("Classificator unloaded")
	}

	func process(image: UIImage) async {
        ciImage = CIImage(image: image)
        guard let ciImage else {
            Logger.drivers.logWarning("Failed to create CIImage from UIImage")
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
            Logger.drivers.logDebug("Classification skipped: classification request not initialized")
            return
        }
        
        do {
            try handler?.perform([classificationRequest])
        } catch {
            Logger.drivers.logError("Failed to perform classification: \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performClassification"])
        }
	}

	func run() async {
		await classify()
	}
}
