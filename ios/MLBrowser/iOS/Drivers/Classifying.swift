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

#if DEBUG
/// UI-test classificator (AIA-0374): registered by `DeepState` only under the
/// `-mockClassification` launch argument during UI tests. Alternates one qualifying
/// label ↔ none per pass, so flash transitions (0→1) recur deterministically — a
/// constant result would flash exactly once and make the disable-case test vacuous.
/// Lives here beside its protocol (not in UI/) per the MockAuthProvider-beside-
/// ClerkAuthProvider precedent: State must not depend on UI-layer types.
actor MockClassificator: Classifying {
	let id: UUID
	var params: DeepDriverParams
	var observations: [VNObservation] = []
	private var pass = 0

	init() {
		let entityId = UUID()
		self.id = entityId
		self.params = DeepDriverParams(entityId: entityId)
	}

	func classify(image: UIImage) async -> [ClassifiedLabel] {
		pass += 1
		guard pass.isMultiple(of: 2).not else { return [] }
		return [ClassifiedLabel(identifier: "mock-object", confidence: 0.99)]
	}

	func metadata() -> [MLModelMetadataKey: Any]? { nil }
	func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
	func process(image: UIImage) async {}
	func loadFile() async throws {}
	func run() async {}
	func unload() async {}
}
#endif
