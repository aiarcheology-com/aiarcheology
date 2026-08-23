//
//  DeepDriver.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 13.12.23.
//

import UIKit
import SwiftUI
import Vision
import OSLog
import CoreML

public enum DeepDriverType: String, Sendable {
	case detector = "detect"
	case classificator = "classify"
	case invalid = "invalid"

	/// User-facing name. `.invalid` reads as "Disabled" — a model with an undetermined type does
	/// not run until the user picks one (AIA-0402).
	var localizedName: String {
		switch self {
		case .detector: return L10n.Configuration.modelTypeDetection
		case .classificator: return L10n.Configuration.modelTypeClassification
		case .invalid: return L10n.Configuration.modelTypeDisabled
		}
	}
}

/// A per-model request for Core ML placement. It deliberately describes the product choice rather
/// than a converted artifact's numerical-parity metadata: all models default to Core ML's `.all`.
enum ModelComputeUnit: String, CaseIterable, Identifiable, Sendable {
	case automatic
	case neuralEngine
	case graphicsProcessor
	case processorOnly

	enum Accelerator: Hashable, Sendable {
		case graphicsProcessor
		case neuralEngine
	}

	var id: String { rawValue }

	var requestedComputeUnits: MLComputeUnits {
		switch self {
		case .automatic: .all
		case .neuralEngine: .cpuAndNeuralEngine
		case .graphicsProcessor: .cpuAndGPU
		case .processorOnly: .cpuOnly
		}
	}

	var requiredAccelerator: Accelerator? {
		switch self {
		case .automatic, .processorOnly: nil
		case .neuralEngine: .neuralEngine
		case .graphicsProcessor: .graphicsProcessor
		}
	}

	static var availableAccelerators: Set<Accelerator> {
		Set(MLModel.availableComputeDevices.compactMap { device in
			switch device {
			case .gpu: .graphicsProcessor
			case .neuralEngine: .neuralEngine
			case .cpu: nil
			@unknown default: nil
			}
		})
	}

	func isAvailable(in availableAccelerators: Set<Accelerator> = Self.availableAccelerators) -> Bool {
		guard let requiredAccelerator else { return true }
		return availableAccelerators.contains(requiredAccelerator)
	}

	/// A request for unavailable hardware falls back only for this load. The stored choice remains
	/// intact so a configuration moved back to a capable device regains the user's intent.
	func resolvedComputeUnits(in availableAccelerators: Set<Accelerator> = Self.availableAccelerators) -> MLComputeUnits {
		isAvailable(in: availableAccelerators) ? requestedComputeUnits : .all
	}
}

private extension MLComputeUnits {
	var traceLabel: String {
		switch self {
		case .all: "all"
		case .cpuOnly: "cpuOnly"
		case .cpuAndGPU: "cpuAndGPU"
		case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
		@unknown default: "unknown"
		}
	}
}

struct DeepDriverParams: Sendable {
	var annotationColor: Color = .yellow
	var computeUnit: ModelComputeUnit = .automatic
	var entityId: UUID
	/// The model's display name, for per-model attribution in the classification label bubble
	/// (AIA-0472). Deliberately NO default: every construction site must decide what to call the
	/// model — a silently blank name is how attribution rots.
	var modelName: String
	var file: URL?
	var phaseOutTime: Double = 1.0
	var selectedSymbol: AnnotationSymbol = .circle
	var demo: Bool = false
	/// Per-model finding-flash style (AIA-0374; classify models).
	var flashEnabled: Bool = true
	var flashSize: Double = 8.0
}

// Vision result types cross tasks; results are immutable.
extension VNObservation: @unchecked @retroactive Sendable {}
extension VNRecognizedObjectObservation: @unchecked Sendable {}
extension VNClassificationObservation: @unchecked Sendable {}

typealias ObservationParams = (observations: [VNObservation], params: DeepDriverParams)

/// Detect-path result: remapped value-type observations (see `DetectedObject`) per driver.
/// The classify path has its own value-type shape, `ClassificationResult` (AIA-0374).
/// `ObservationParams` above remains only for the legacy `Annotator` view modifier.
typealias DetectionResult = (observations: [DetectedObject], params: DeepDriverParams)

protocol DeepDriver: Driver, Sendable {
	var params: DeepDriverParams { get set }
	var observations: [VNObservation] { get set }
	func updateConfiguration(_ params: DeepDriverParams) async
	func process(image: UIImage) async
	func loadFile() async throws
	func run() async
	func unload() async
}

extension DeepDriver {
	@discardableResult
	static func loadModel(
		from path: URL,
		demo: Bool = false,
		computeUnit: ModelComputeUnit = .automatic
	) async throws -> MLModel? {
		// the file is already handled by copying resources in Xcode: -> mlmodelc (compiled)
		let compiledModelURL = demo ? path : try await MLModel.compileModel(at: path)

		do {
			LoggingPolicy.debug("Loading MLModel from \(compiledModelURL.lastPathComponent)", logger: .drivers)
			let availableAccelerators = ModelComputeUnit.availableAccelerators
			let requestedComputeUnits = computeUnit.requestedComputeUnits
			let requestedHardwareIsAvailable = computeUnit.isAvailable(in: availableAccelerators)
			let resolvedComputeUnits = computeUnit.resolvedComputeUnits(in: availableAccelerators)
			let configured = MLModelConfiguration()
			configured.computeUnits = resolvedComputeUnits
			LoggingPolicy.debug(
				"[AIA-0695 TRACE] Core ML placement: requested=\(computeUnit.rawValue) (\(requestedComputeUnits.traceLabel)), resolved=\(resolvedComputeUnits.traceLabel), requestedHardwareAvailable=\(requestedHardwareIsAvailable)",
				logger: .drivers
			)
			if requestedHardwareIsAvailable.not {
				LoggingPolicy.info(
					"Requested model hardware is unavailable; loading with Automatic placement instead.",
					logger: .drivers
				)
			}
			return try await MLModel.load(contentsOf: compiledModelURL, configuration: configured)
		} catch {
			LoggingPolicy.error("Error loading MLModel", error: error, logger: .drivers)
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "loadMLModel", "path": compiledModelURL.lastPathComponent])
			return nil
		}
	}
}

// Drivers factory
@MainActor
class DeepDrivers: ObservableObject {
	@Published var detectors: [DeepDriver] = []
	@Published var classificators: [DeepDriver] = []
	/// Bumped when a display-only detection preference changes. Observing views re-filter their
	/// retained frames; no driver is reloaded and no inference is restarted.
	@Published private(set) var detectionPresentationRevision = 0

	/// Runs the detect/classify orchestration loops off the main actor (AIA-0387).
	private let engine = DetectionEngine()

	func register(driver: DeepDriver, along: DeepDriverType) {
		switch along {
		case .detector:
			let alreadyRegistered = detectors.contains { $0.id == driver.id }
			if !alreadyRegistered {
				detectors.append(driver)
			}
		case .classificator:
			let alreadyRegistered = classificators.contains { $0.id == driver.id }
			if !alreadyRegistered {
				classificators.append(driver)
			}
		case .invalid:
			LoggingPolicy.error("Attempted to register driver with invalid type.", logger: .drivers)
		}
	}

	func update(configuration: DeepConfiguration) async {
		let entityId = configuration.entityId
		let drivers = (detectors + classificators).filter { $0.id == entityId }
		if drivers.count >= 2 {
			LoggingPolicy.warning("Multiple drivers found with same configuration.entityId: \(entityId.uuidString)", logger: .drivers)
		}
		// toDriverParams() preserves ALL fields (including `demo`, which the previous
		// manual construction silently reset). Awaiting keeps rapid successive updates
		// ordered — the old fire-and-forget Task could apply an older config last.
		let params = configuration.toDriverParams()
		await drivers.first?.updateConfiguration(params)
	}

	func detectionPresentationDidChange() {
		detectionPresentationRevision &+= 1
	}

    func unregister(driverId: UUID) async {
        // Remove from the published buckets FIRST, then unload. A live type switch keys off these
        // buckets to decide detect↔classify swaps (AIA-0402); leaving the driver visible during the
        // async unload let a concurrent update misread the still-old type and skip the swap.
        let driver = (classificators + detectors).first { $0.id == driverId }
        detectors = detectors.filter { $0.id != driverId }
        classificators = classificators.filter { $0.id != driverId }
        await driver?.unload()
    }

	/// Unloads and removes every registered driver.
	///
	/// Needed after batch deletes (e.g. application reset): NSBatchDeleteRequest bypasses
	/// `NSManagedObjectContextObjectsDidChange`, so per-configuration unregistration never fires.
	func unregisterAll() async {
		// Snapshot on the main actor, clear immediately so no new work targets stale drivers
		let snapshot = detectors + classificators
		detectors = []
		classificators = []
		await withTaskGroup(of: Void.self) { group in
			for driver in snapshot {
				group.addTask {
					await driver.unload()
				}
			}
		}
	}

	func unload(_ driver: DeepDriverType) async {
		switch driver {
		case .detector:
			// Snapshot on the main actor
			let snapshot = detectors
			await withTaskGroup(of: Void.self) { group in
				for driver in snapshot {
					group.addTask {
						await driver.unload()
					}
				}
			}
		case .classificator:
			// Snapshot on the main actor
			let snapshot = classificators
			await withTaskGroup(of: Void.self) { group in
				for driver in snapshot {
					group.addTask {
						await driver.unload()
					}
				}
			}
		case .invalid:
			LoggingPolicy.error("Attempted to unload driver with invalid type.", logger: .drivers)
		}
	}

	// This is the core function that takes a 2D image and detects objects in the scene.
	// For that functionality, the driver should be already registered and loaded. That is
	// controlled by the driver's related DeepConfiguation instance in CoreData.
	func detect(on image: UIImage, tiling: TilingScheme) async -> [DetectionResult] {
		await detect(on: image, tiling: tiling, onPartialResults: { _ in })
	}

	/// Runs detection and forwards each production detector's deduplicated per-tile aggregate.
	/// The final return remains the complete pass so non-progressive drivers and one-shot callers
	/// retain their existing semantics.
	func detect(
		on image: UIImage,
		tiling: TilingScheme,
		onPartialResults: @escaping @MainActor @Sendable ([DetectionResult]) -> Void
	) async -> [DetectionResult] {
		// Snapshot the driver list on the main actor, then run the serial loop off it in
		// the engine actor (AIA-0387).
		let snapshot = detectors
		return await engine.detect(
			on: image,
			in: snapshot,
			tiling: tiling,
			onPartialResults: onPartialResults
		)
	}

	// Classification counterpart of detect(): each registered classificator runs one
	// atomic pass (AIA-0374 — the split-phase process/classify orchestration moved into
	// `Classifying.classify(image:)`, the same fix detect() got).
	func classify(on image: UIImage) async -> [ClassificationResult] {
		let snapshot = classificators
		return await engine.classify(on: image, in: snapshot)
	}
}

/// Runs the detect/classify orchestration loops OFF the main actor (AIA-0387). Stateless —
/// each call builds a function-local result array, so actor reentrancy across concurrent
/// passes is harmless and per-pass order is preserved. The heavy Vision work stays on the
/// individual `Detector`/`Classificator` actors; this actor owns only the lightweight loop.
/// Cancellation is cooperative: a cancelled pass stops before dispatching the next driver
/// (a driver already in flight finishes; its result is discarded caller-side).
actor DetectionEngine {
	// The image is detected over the regions of the enabled tiling scheme(s) (AIA-0217, AIA-0426):
	// pyramid = 6, 3x3 = 10, both = their 15-region union; empty = full frame only.
	func detect(
		on image: UIImage,
		in detectors: [DeepDriver],
		tiling: TilingScheme,
		onPartialResults: @escaping @MainActor @Sendable ([DetectionResult]) -> Void = { _ in }
	) async -> [DetectionResult] {
		let regions = TileLayout.regions(for: tiling)
		// The loop is serial — a plain array suffices.
		var results: [DetectionResult] = []
		for detector in detectors {
			if Task.isCancelled { break }
			guard let detector = detector as? Detecting else { continue }
			let params = await detector.params
			let completedResults = results
			let observations: [DetectedObject]
			if let incrementalDetector = detector as? IncrementalDetecting {
				observations = await incrementalDetector.detect(
					image: image,
					regions: regions,
					onPartialResult: { partialObservations in
						var partialResults = completedResults
						if partialObservations.isEmpty.not {
							partialResults.append((observations: partialObservations, params: params))
						}
						onPartialResults(partialResults)
					}
				)
			} else {
				observations = await detector.detect(image: image, regions: regions)
			}
			guard observations.isEmpty.not else { continue }
			results.append((observations: observations, params: params))
		}
		return results
	}

	func classify(on image: UIImage, in classificators: [DeepDriver]) async -> [ClassificationResult] {
		var results: [ClassificationResult] = []
		for classificator in classificators {
			if Task.isCancelled { break }
			guard let classifying = classificator as? Classifying else { continue }
			let labels = await classifying.classify(image: image)
			guard labels.isEmpty.not else { continue }
			let params = await classifying.params
			results.append((labels: labels, params: params))
		}
		return results
	}
}
