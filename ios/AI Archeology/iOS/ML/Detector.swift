//
//  Detector.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 26.09.23.
//

import CoreML
import Vision
import UIKit

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
