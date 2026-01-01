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

private final class DetectorVisionRequestProxy: @unchecked Sendable {
    weak var owner: Detector?
    
    init(owner: Detector) {
        self.owner = owner
    }
    
    func handleCompletion(request: VNRequest, error: Error?) {
        if let error = error {
            LoggingPolicy.error("Object detection request failed", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "detection"])
            return
        }
        
        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            LoggingPolicy.warning("Detection request results could not be cast to VNRecognizedObjectObservation", logger: .drivers)
            return
        }
        
        Task {
            guard let owner = self.owner else { return }
            await owner.updateDetectionResults(observations: observations)
            LoggingPolicy.debug("Detection completed with \(observations.count) observations", logger: .drivers)
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
        LoggingPolicy.debug("Detector initialized with ID \(id)", logger: .drivers)
    }
    
    func updateConfiguration(_ params: DeepDriverParams) async {
        self.params = params
        LoggingPolicy.debug("Detector updated with ID \(id)", logger: .drivers)
    }
    
    func metadata() -> [MLModelMetadataKey: Any]? {
        mlModel?.modelDescription.metadata
    }
    
    func loadFile() async throws {
        guard let path = self.params.file else {
            LoggingPolicy.error("Detector loadFile failed: file path is nil", logger: .drivers)
            throw DetectorError.loadError
        }
        
        LoggingPolicy.debug("Loading detector model from \(path.absoluteString)", logger: .drivers)
        
        guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
            LoggingPolicy.error("Failed to load ML model from \(path.absoluteString)", logger: .drivers)
            throw DetectorError.loadError
        }
        
        LoggingPolicy.debug("Model successfully loaded from \(path.lastPathComponent)", logger: .drivers)
        
        objectDetectionModel = try VNCoreMLModel(for: model)
        
        guard let detecionModel = objectDetectionModel else {
            LoggingPolicy.error("Failed to create VNCoreMLModel from loaded model", logger: .drivers)
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
        LoggingPolicy.debug("Detector unloaded", logger: .drivers)
    }
    
    func process(image: UIImage) async {
        ciImage = CIImage(image: image)
        guard let ciImage else {
            LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
            return
        }
        handler = VNImageRequestHandler(ciImage: ciImage)
    }
    
    func detect() async {
        guard let detectionRequest else {
            LoggingPolicy.debug("Detection skipped: detection request not initialized", logger: .drivers)
            return
        }
        
        do {
            try handler?.perform([detectionRequest])
        } catch {
            LoggingPolicy.error("Failed to perform detection", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection"])
        }
    }
    
    func run() async {
        await detect()
    }
}
