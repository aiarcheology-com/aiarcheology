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

    /// The detect path's only entry point: image conversion, the region loop, coordinate
    /// remap, and cross-region dedup happen inside one actor-isolated call, so a concurrent
    /// frame can never swap the handler between processing and detection (the old
    /// `process`/`detect` pair raced exactly that way — magnified 6× by tiling).
    func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject] {
        guard let detectionRequest else {
            LoggingPolicy.debug("Detection skipped: detection request not initialized", logger: .drivers)
            return []
        }
        guard let ciImage = CIImage(image: image) else {
            LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
            return []
        }
        // A thrown perform must not leak a region's ROI into the next frame.
        defer { detectionRequest.regionOfInterest = TileLayout.fullFrame }

        let handler = VNImageRequestHandler(ciImage: ciImage)
        let start = Date.now
        var collected: [DetectedObject] = []
        for (index, region) in regions.enumerated() {
            detectionRequest.regionOfInterest = region
            let regionStart = Date.now
            do {
                try handler.perform([detectionRequest])
            } catch {
                // One failed region must not abort the frame — and its results must not
                // be consumed: VNRequest retains the previous run's results on failure.
                LoggingPolicy.error("Failed to perform detection for region \(index)", error: error, logger: .drivers)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection", "region": "\(index)"])
                continue
            }
            let regionObservations = (detectionRequest.results as? [VNRecognizedObjectObservation]) ?? []
            for observation in regionObservations {
                guard let box = TileLayout.remap(observation.boundingBox, into: region) else { continue }
                collected.append(DetectedObject(
                    uuid: observation.uuid,
                    labels: observation.labels.map { DetectedObject.Label(identifier: $0.identifier, confidence: $0.confidence) },
                    confidence: observation.confidence,
                    boundingBox: box,
                    regionIndex: index
                ))
            }
            LoggingPolicy.debug(
                "Region \(index) detected \(regionObservations.count) objects in \(Date.now.timeIntervalSince(regionStart))s",
                logger: .drivers
            )
        }
        let results = TileLayout.dedupAcrossRegions(collected)
        LoggingPolicy.debug(
            "Detection over \(regions.count) regions completed with \(results.count) objects (\(collected.count) raw) in \(Date.now.timeIntervalSince(start))s",
            logger: .drivers
        )
        return results
    }

    func process(image: UIImage) async {
        // Clear stale state: a new frame must never report the previous frame's
        // detections, and a failed conversion must not leave the old handler around
        // (detect() would silently re-run the previous frame).
        observations = []
        handler = nil
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

        // Without a handler there is no frame to process. Bail out before reading
        // detectionRequest.results — VNRequest retains the previous run's results,
        // so an optional-chained no-op perform would re-report the prior frame.
        guard let handler else {
            LoggingPolicy.debug("Detection skipped: no frame to process", logger: .drivers)
            observations = []
            return
        }

        do {
            try handler.perform([detectionRequest])
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
