//
//  Classifying.swift
//  AI Archeology
//
//  Created by Agent on 2026-07-02.
//

import UIKit
import Vision

/// A classified whole-image label — the classification counterpart of `DetectedObject`
/// (AIA-0374). A value type so results cross actor boundaries freely and tests/mocks can
/// construct them (`VNClassificationObservation` has no public initializer).
struct ClassifiedLabel: Sendable, Equatable {
	let identifier: String
	let confidence: Float
}

/// One classify pass's output for a single driver: its labels plus the driver's
/// presentation params (color etc.), mirroring `DetectionResult`.
typealias ClassificationResult = (labels: [ClassifiedLabel], params: DeepDriverParams)

/// Atomic classification API (AIA-0374): one call = process + classify + remap.
/// Deliberately NOT the stateful `process()` → `classify()` → `observations` triple —
/// the detect path abandoned that split-phase shape because it raced (see the note in
/// `Detector.detect(image:regions:)`); this transposes the same fix, and gives mocks a
/// single function to implement.
protocol Classifying: DeepDriver {
	func classify(image: UIImage) async -> [ClassifiedLabel]
}
