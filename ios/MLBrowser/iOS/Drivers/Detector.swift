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

        // Log file name only: container paths can embed user data (see LOGGING_GUIDE.md).
        LoggingPolicy.debug("Loading detector model from \(path.lastPathComponent)", logger: .drivers)

        guard let model = try await Self.loadModel(from: path, demo: params.demo) else {
            LoggingPolicy.error("Failed to load ML model from \(path.lastPathComponent)", logger: .drivers)
            throw DetectorError.loadError
        }

        LoggingPolicy.debug("Model successfully loaded from \(path.lastPathComponent)", logger: .drivers)

        mlModel = model
        objectDetectionModel = try VNCoreMLModel(for: model)

        guard let detecionModel = objectDetectionModel else {
            LoggingPolicy.error("Failed to create VNCoreMLModel from loaded model", logger: .drivers)
            throw DetectorError.coreModelLoadError
        }

        detectionRequest = VNCoreMLRequest(model: detecionModel)
        detectionRequest?.imageCropAndScaleOption = .scaleFit
    }

    func unload() async {
        ciImage = nil
        handler = nil
        detectionRequest = nil
        objectDetectionModel = nil
        mlModel = nil
        observations = []
        LoggingPolicy.debug("Detector unloaded", logger: .drivers)
    }

    func process(image: UIImage) async {
        // Clear stale results: a new frame must never report the previous frame's detections.
        observations = []
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
            // perform() completes synchronously, so results can be read directly here.
            // The previous Task-based completion proxy raced with readers and could
            // deliver the prior frame's observations.
            observations = (detectionRequest.results as? [VNRecognizedObjectObservation]) ?? []
            LoggingPolicy.debug("Detection completed with \(observations.count) observations", logger: .drivers)
        } catch {
            LoggingPolicy.error("Failed to perform detection", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection"])
            observations = []
        }
        ciImage = nil
    }
    
    func run() async {
        await detect()
    }
}
