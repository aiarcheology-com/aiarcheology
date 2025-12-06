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

fileprivate final class DetectorVisionRequestProxy: @unchecked Sendable {
    weak var owner: Detector?
    
    init(owner: Detector) {
        self.owner = owner
    }
    
    func handleCompletion(request: VNRequest, error: Error?) {
        if let error = error {
            Logger.drivers.logError("Object detection request failed: \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "detection"])
            return
        }
        
        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            Logger.drivers.logWarning("Detection request results could not be cast to VNRecognizedObjectObservation")
            return
        }
        
        Task {
            guard let owner = self.owner else { return }
            await owner.updateDetectionResults(observations: observations)
            Logger.drivers.logDebug("Detection completed with \(observations.count) observations")
        }
    }
}

actor Detector: DeepDriver {
    let id: UUID
    var params: DeepDriverParams
    private var objectDetectionModel: VNCoreMLModel?
    private var detectionRequest: VNCoreMLRequest?
    internal var observations: [VNObservation] = []
    private var handler: VNImageRequestHandler?
    private var ciImage: CIImage?
    private var mlModel: MLModel?
    
    init(params: DeepDriverParams) {
        self.id = params.entityId
        self.params = params
        Logger.drivers.logDebug("Detector initialized with ID \(id)")
    }
    
    func updateConfiguration(_ params: DeepDriverParams) async {
        self.params = params
        Logger.drivers.logDebug("Detector updated with ID \(id)")
    }
    
    
    func metadata() -> [MLModelMetadataKey : Any]? {
        mlModel?.modelDescription.metadata
    }
    
    func loadFile() async throws {
        guard let path = self.params.file else {
            Logger.drivers.logError("Detector loadFile failed: file path is nil")
            throw DetectorError.loadError
        }
        
        Logger.drivers.logInfo("Loading detector model from \(path.absoluteString)")
        
        guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
            Logger.drivers.logError("Failed to load ML model from \(path.absoluteString)")
            throw DetectorError.loadError
        }
        
        Logger.drivers.logInfo("Model successfully loaded from \(path.lastPathComponent)")
        objectDetectionModel = try VNCoreMLModel(for: model)
        
        guard let detecionModel = objectDetectionModel else {
            Logger.drivers.logError("Failed to create VNCoreMLModel from loaded model")
            throw DetectorError.coreModelLoadError
        }
        
        let proxy = DetectorVisionRequestProxy(owner: self)
        detectionRequest = VNCoreMLRequest(model: detecionModel) { [proxy] request, error in
            proxy.handleCompletion(request: request, error: error)
        }
        detectionRequest?.imageCropAndScaleOption = .scaleFit
    }
    
    // Made internal so the proxy can call it.
    func updateDetectionResults(observations: [VNRecognizedObjectObservation] = []) {
        self.ciImage = nil
        self.observations = observations
    }
    
    func unload() async {
        ciImage = nil
        detectionRequest = nil
        objectDetectionModel = nil
        Logger.drivers.logDebug("Detector unloaded")
    }
    
    func process(image: UIImage) async {
        ciImage = CIImage(image: image)
        guard let ciImage else {
            Logger.drivers.logWarning("Failed to create CIImage from UIImage")
            return
        }
        handler = VNImageRequestHandler(ciImage: ciImage)
    }
    
    func detect() async {
        guard let detectionRequest else {
            Logger.drivers.logDebug("Detection skipped: detection request not initialized")
            return
        }
        
        do {
            try handler?.perform([detectionRequest])
        } catch {
            Logger.drivers.logError("Failed to perform detection: \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection"])
        }
    }
    
    func run() async {
        await detect()
    }
}
