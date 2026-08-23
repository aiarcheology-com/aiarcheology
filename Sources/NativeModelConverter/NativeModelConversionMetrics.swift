//
//  NativeModelConversionMetrics.swift
//  NativeModelConverter
//
//  Measured conversion timings and exact artifact sizes.
//

import Foundation
import OSLog

/// Exact byte counts of the files accepted as a native-model graph package.
///
/// These values describe files, not process memory. In particular, they must not be treated as a
/// peak-memory estimate: the reader and the protobuf writer may temporarily hold more than one
/// representation of the weights. Use an XCTest `XCTMemoryMetric` run on a physical device to
/// measure that value.
public struct NativeModelPackageFootprint: Codable, Equatable, Sendable {
	public let manifestByteCount: UInt64
	public let graphByteCount: UInt64
	public let weightsByteCount: UInt64
	public let metadataByteCount: UInt64

	public init(
		manifestByteCount: UInt64,
		graphByteCount: UInt64,
		weightsByteCount: UInt64,
		metadataByteCount: UInt64
	) {
		self.manifestByteCount = manifestByteCount
		self.graphByteCount = graphByteCount
		self.weightsByteCount = weightsByteCount
		self.metadataByteCount = metadataByteCount
	}

	public var totalByteCount: UInt64 {
		manifestByteCount + graphByteCount + weightsByteCount + metadataByteCount
	}
}

/// Metrics for the native emitter after it receives a verified package.
///
/// `emissionDurationNanoseconds` is monotonic elapsed time around graph validation, protobuf
/// serialization, atomic model writing, and metadata-sidecar writing. It deliberately excludes
/// Core ML compilation: compilation is a separate Core ML operation and is measured separately by
/// the device benchmark harness.
public struct NativeModelEmissionMetrics: Codable, Equatable, Sendable {
	public let sourceFootprint: NativeModelPackageFootprint
	public let operationCount: Int
	public let outputModelByteCount: UInt64
	public let outputMetadataSidecarByteCount: UInt64
	public let emissionDurationNanoseconds: UInt64

	public init(
		sourceFootprint: NativeModelPackageFootprint,
		operationCount: Int,
		outputModelByteCount: UInt64,
		outputMetadataSidecarByteCount: UInt64,
		emissionDurationNanoseconds: UInt64
	) {
		self.sourceFootprint = sourceFootprint
		self.operationCount = operationCount
		self.outputModelByteCount = outputModelByteCount
		self.outputMetadataSidecarByteCount = outputMetadataSidecarByteCount
		self.emissionDurationNanoseconds = emissionDurationNanoseconds
	}
}

/// End-to-end metrics for native package reading and emission.
///
/// The metrics have no peak-memory field because reporting one from inside the process would be
/// platform-specific and would not be an XCTest-equivalent measurement. The companion device test
/// uses `XCTMemoryMetric` for that purpose.
public struct NativeModelConversionMetrics: Codable, Equatable, Sendable {
	public let sourceFootprint: NativeModelPackageFootprint
	public let packageReadDurationNanoseconds: UInt64
	public let emission: NativeModelEmissionMetrics
	/// The last process-level memory observation captured during this conversion, if available.
	///
	/// It is an observed whole-process value, not a library-only or guaranteed peak measurement.
	public let processMemoryUsage: NativeModelConversionProcessMemoryUsage?

	public init(
		sourceFootprint: NativeModelPackageFootprint,
		packageReadDurationNanoseconds: UInt64,
		emission: NativeModelEmissionMetrics,
		processMemoryUsage: NativeModelConversionProcessMemoryUsage? = nil
	) {
		self.sourceFootprint = sourceFootprint
		self.packageReadDurationNanoseconds = packageReadDurationNanoseconds
		self.emission = emission
		self.processMemoryUsage = processMemoryUsage
	}

	public var totalConversionDurationNanoseconds: UInt64 {
		packageReadDurationNanoseconds + emission.emissionDurationNanoseconds
	}
}

/// Reads and emits a package while returning comparable timing and artifact-size evidence.
///
/// This is the high-level API for command-line, benchmark, and UI harnesses. It exposes typed
/// progress, stable error diagnostics, unified-log messages, and Instruments signposts. Apps that
/// need to inspect the verified graph before emission may continue to use
/// ``NativeModelGraphPackageReader`` and ``NativeModelCoreMLEmitter`` directly.
public struct NativeModelConverter: Sendable {
	private let reader: NativeModelGraphPackageReader
	private let emitter: NativeModelCoreMLEmitter
	private static let executionGate = NativeModelConversionExecutionGate()

	#if DEBUG
	/// How many conversions are queued behind the running one — test support only.
	///
	/// A test that wants to assert the queue's *order* has to know a job is actually in the queue,
	/// and the `.waitingForExclusiveAccess` progress report cannot tell it: that fires before
	/// ``NativeModelConversionExecutionGate/acquire()`` is awaited, leaving a suspension point in
	/// which a later-launched job can reach the actor first. Sleeping does not close that window and
	/// neither does a longer timeout — only observing the queue does.
	static func queuedJobCountForTesting() async -> Int {
		await executionGate.queuedJobCount
	}
	#endif

	public init(limits: NativeModelGraphPackageLimits = .default) {
		reader = NativeModelGraphPackageReader(limits: limits)
		emitter = NativeModelCoreMLEmitter()
	}

	public func convert(
		from packageURL: URL,
		to outputURL: URL,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
		reporting progress: NativeModelConversionProgressHandler? = nil
	) async throws -> NativeModelConversionMetrics {
		progress?(NativeModelConversionProgress(phase: .waitingForExclusiveAccess))
		do {
			try await Self.executionGate.acquire()
		} catch is CancellationError {
			progress?(NativeModelConversionProgress(phase: .cancelled))
			throw NativeModelConversionError.cancelled(phase: .waitingForExclusiveAccess)
		}

		do {
			let metrics = try await convertReserved(
				from: packageURL,
				to: outputURL,
				sourceProvenance: sourceProvenance?.settingSourcePackageFilename(packageURL.lastPathComponent)
					?? NativeModelConversionSourceProvenance(sourcePackageFilename: packageURL.lastPathComponent),
				reporting: progress
			)
			await Self.executionGate.release()
			return metrics
		} catch {
			await Self.executionGate.release()
			throw error
		}
	}

	/// Converts a self-contained ONNX model file to Core ML on-device, with no Python and no
	/// intermediate package. Reuses the process-global FIFO gate so ONNX and package conversions do
	/// not run concurrently.
	public func convert(
		onnx onnxURL: URL,
		to outputURL: URL,
		reporting progress: NativeModelConversionProgressHandler? = nil
	) async throws -> NativeModelConversionMetrics {
		progress?(NativeModelConversionProgress(phase: .waitingForExclusiveAccess))
		do {
			try await Self.executionGate.acquire()
		} catch is CancellationError {
			progress?(NativeModelConversionProgress(phase: .cancelled))
			throw NativeModelConversionError.cancelled(phase: .waitingForExclusiveAccess)
		}
		do {
			let metrics = try await convertONNXReserved(from: onnxURL, to: outputURL, reporting: progress)
			await Self.executionGate.release()
			return metrics
		} catch {
			await Self.executionGate.release()
			throw error
		}
	}

	/// Converts one of the pinned ADAF Faster R-CNN checkpoints to Core ML on-device.
	///
	/// This is deliberately a separate high-level entry point rather than treating the checkpoint
	/// as a graph package: a PyTorch checkpoint carries tensor storage, not an `.aiagraph` manifest
	/// and graph. The exact registry and emitter contract matches `adaf-detector-parity-runner`, so
	/// an app-imported artifact carries the same detector interface and parity provenance as the CLI
	/// artifact. Compute-unit selection belongs to the loading app, not the converted artifact.
	public func convert(
		adafDetector checkpointURL: URL,
		to outputURL: URL,
		reporting progress: NativeModelConversionProgressHandler? = nil
	) async throws -> NativeModelConversionMetrics {
		progress?(NativeModelConversionProgress(phase: .waitingForExclusiveAccess))
		do {
			try await Self.executionGate.acquire()
		} catch is CancellationError {
			progress?(NativeModelConversionProgress(phase: .cancelled))
			throw NativeModelConversionError.cancelled(phase: .waitingForExclusiveAccess)
		}
		do {
			let metrics = try convertADAFDetectorReserved(
				from: checkpointURL,
				to: outputURL,
				reporting: progress
			)
			await Self.executionGate.release()
			return metrics
		} catch {
			await Self.executionGate.release()
			throw error
		}
	}

	private func convertONNXReserved(
		from onnxURL: URL,
		to outputURL: URL,
		reporting progress: NativeModelConversionProgressHandler?
	) async throws -> NativeModelConversionMetrics {
		let memoryTracker = NativeModelConversionMemoryTracker()
		let report: NativeModelConversionProgressHandler = { update in
			NativeModelConversionInstrumentation.event(update.phase)
			let observedUpdate = update.withProcessMemoryUsage(memoryTracker.sample())
			progress?(observedUpdate)
		}
		do {
			report(NativeModelConversionProgress(phase: .preparing))
			try Task.checkCancellation()
			report(NativeModelConversionProgress(phase: .readingGraph))
			let readStartedAt = DispatchTime.now().uptimeNanoseconds
			let conversion = try ONNXModelReader().read(from: onnxURL)
			let readDuration = elapsedNanoseconds(since: readStartedAt)
			report(NativeModelConversionProgress(phase: .validatingGraph, completedUnitCount: 1, totalUnitCount: 1))
			try Task.checkCancellation()

			let emissionStartedAt = DispatchTime.now().uptimeNanoseconds
			// A standard ONNX model carries no labels, anchors, or preprocessing constants, so both
			// interfaces rest on recognized output signatures. A raw grid matching a catalogued
			// detector head gets the synthesized decode and a detector pipeline; otherwise, when the
			// single output has one unit per ImageNet-1k class, the emitter applies the ImageNet
			// labels and RGB normalization; otherwise the graph is emitted as a plain neural network.
			let detection = try NativeModelDetectorCatalog.detectionConversion(of: conversion)
			let operationCount = (detection?.graph ?? conversion.graph).operations.count
			report(NativeModelConversionProgress(phase: .emittingModel, completedUnitCount: 0, totalUnitCount: operationCount))
				// Attribution carried from the source ONNX file (AIA-0473): description/author/version/
				// license plus a provenance mirror, so the converted model credits the original author
				// and records that it is a conversion. The original filename is the one provenance fact
				// available here (no remote URL at this layer).
				let sourceProvenance = NativeModelConversionSourceProvenance(
					originalModelFilename: onnxURL.lastPathComponent
				)
				if let detection {
					try emitter.emit(
						graph: detection.graph,
						weights: detection.weights,
						to: outputURL,
						detection: detection.interface,
						detectionTarget: detection.targetInfo,
						imagePreprocessing: detection.imagePreprocessing,
						targetSemanticsIntent: detection.targetSemanticsIntent,
						sourceMetadata: conversion.metadata,
						sourceProvenance: sourceProvenance
					)
				} else {
					try emitter.emit(
						graph: conversion.graph,
						weights: conversion.weights,
						to: outputURL,
						classifierLabels: ImageNet1000Labels.categories,
						imagePreprocessing: .imageNetRGB,
						targetSemanticsIntent: NativeModelTargetSemanticsIntent(
							labelProfile: .imageNet1K,
							preprocessingProfile: .imageNetRGB
						),
						sourceMetadata: conversion.metadata,
						sourceProvenance: sourceProvenance
					)
				}
			report(NativeModelConversionProgress(phase: .emittingModel, completedUnitCount: operationCount, totalUnitCount: operationCount))
			report(NativeModelConversionProgress(phase: .writingModel, completedUnitCount: 1, totalUnitCount: 1))

			// A missing size would silently report 0 and hide a write failure; fail with a typed error.
			guard let outputByteCount = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.uint64Value else {
				throw NativeModelCoreMLEmissionError.outputFileSizeUnavailable(outputURL.lastPathComponent)
			}
			let footprint = NativeModelPackageFootprint(
				manifestByteCount: 0,
				graphByteCount: 0,
				weightsByteCount: UInt64(conversion.weights.count),
				metadataByteCount: 0
			)
			let emission = NativeModelEmissionMetrics(
				sourceFootprint: footprint,
				operationCount: operationCount,
				outputModelByteCount: outputByteCount,
				outputMetadataSidecarByteCount: 0,
				emissionDurationNanoseconds: elapsedNanoseconds(since: emissionStartedAt)
			)
			report(NativeModelConversionProgress(phase: .completed, completedUnitCount: 1, totalUnitCount: 1))
			return NativeModelConversionMetrics(
				sourceFootprint: footprint,
				packageReadDurationNanoseconds: readDuration,
				emission: emission,
				processMemoryUsage: memoryTracker.sample()
			)
		} catch is CancellationError {
			report(NativeModelConversionProgress(phase: .cancelled))
			throw NativeModelConversionError.cancelled(phase: .preparing)
		} catch let error as ONNXModelReaderError {
			// ONNX reader diagnostics name the offending operator/tensor and contain no file paths, so
			// they are safe to surface. Foundation file-read failures are a different type and fall
			// through to the masked generic message below.
			report(NativeModelConversionProgress(phase: .failed))
			throw NativeModelConversionError.unexpected(
				phase: .readingGraph,
				message: error.errorDescription ?? NativeModelConversionError.unexpectedMessage
			)
		} catch {
			let conversionError = conversionError(from: error, defaultPhase: .emittingModel)
			report(NativeModelConversionProgress(phase: .failed))
			throw conversionError
		}
	}

	private func convertADAFDetectorReserved(
		from checkpointURL: URL,
		to outputURL: URL,
		reporting progress: NativeModelConversionProgressHandler?
	) throws -> NativeModelConversionMetrics {
		let memoryTracker = NativeModelConversionMemoryTracker()
		let report: NativeModelConversionProgressHandler = { update in
			NativeModelConversionInstrumentation.event(update.phase)
			let observedUpdate = update.withProcessMemoryUsage(memoryTracker.sample())
			progress?(observedUpdate)
		}
		let cancellationCheck: NativeModelConversionCancellationHandler = {
			try Task.checkCancellation()
		}
		var phase = NativeModelConversionPhase.preparing
		report(NativeModelConversionProgress(phase: phase))

		do {
			try cancellationCheck()
			phase = .readingGraph
			report(NativeModelConversionProgress(phase: phase, completedUnitCount: 0, totalUnitCount: 1))
			let readingStartedAt = DispatchTime.now().uptimeNanoseconds
			let checkpoint = try PyTorchCheckpointReader.read(contentsOf: checkpointURL)
			report(NativeModelConversionProgress(phase: phase, completedUnitCount: 1, totalUnitCount: 1))

			phase = .validatingGraph
			report(NativeModelConversionProgress(phase: phase, completedUnitCount: 0, totalUnitCount: 1))
			try cancellationCheck()
			report(NativeModelConversionProgress(phase: phase, completedUnitCount: 1, totalUnitCount: 1))

			// A process termination cannot run this method's defer. Keep the extractor's disposable
			// scratch file out of the app-owned configuration directory, whose recovery protocol knows
			// only the durable source, report and emitted model artifacts.
			let weightsURL = FileManager.default.temporaryDirectory
				.appendingPathComponent(".adaf-weights-\(UUID().uuidString).bin", isDirectory: false)
			defer { try? FileManager.default.removeItem(at: weightsURL) }

			phase = .readingWeights
			let extraction = try PyTorchWeightExtractor.extract(
				checkpoint,
				from: checkpointURL,
				to: weightsURL,
				reporting: report,
				checkingCancellation: cancellationCheck
			)
			phase = .validatingWeights
			report(NativeModelConversionProgress(phase: phase, completedUnitCount: 0, totalUnitCount: 1))
			try cancellationCheck()
			let conversion = try NativeModelFasterRCNNRegistry.conversion(
				checkpoint: checkpoint,
				extraction: extraction,
				weightData: try Data(contentsOf: weightsURL, options: .mappedIfSafe),
				checkingCancellation: cancellationCheck
			)
			report(NativeModelConversionProgress(phase: phase, completedUnitCount: 1, totalUnitCount: 1))

			let readDuration = elapsedNanoseconds(since: readingStartedAt)
			let sourceFootprint = NativeModelPackageFootprint(
				manifestByteCount: 0,
				graphByteCount: 0,
				weightsByteCount: extraction.sourceByteCount,
				metadataByteCount: 0
			)
			let emissionStartedAt = DispatchTime.now().uptimeNanoseconds
			try emitter.emit(
				graph: conversion.graph,
				weights: conversion.weights,
				to: outputURL,
				detection: conversion.interface,
				detectionTarget: conversion.targetInfo,
				imagePreprocessing: .imageNetRGB,
				imageSizingContract: .adafFasterRCNN,
				targetSemanticsIntent: conversion.targetSemanticsIntent,
				parityEvidence: .structurallyMatched,
				reporting: report,
				checkingCancellation: cancellationCheck
			)
			let emission = NativeModelEmissionMetrics(
				sourceFootprint: sourceFootprint,
				operationCount: conversion.graph.operations.count,
				outputModelByteCount: try outputFileByteCount(at: outputURL),
				outputMetadataSidecarByteCount: 0,
				emissionDurationNanoseconds: elapsedNanoseconds(since: emissionStartedAt)
			)
			report(NativeModelConversionProgress(phase: .completed, completedUnitCount: 1, totalUnitCount: 1))
			return NativeModelConversionMetrics(
				sourceFootprint: sourceFootprint,
				packageReadDurationNanoseconds: readDuration,
				emission: emission,
				processMemoryUsage: memoryTracker.sample()
			)
		} catch is CancellationError {
			report(NativeModelConversionProgress(phase: .cancelled))
			throw NativeModelConversionError.cancelled(phase: phase)
		} catch {
			let conversionError = conversionError(from: error, defaultPhase: phase)
			report(NativeModelConversionProgress(phase: .failed))
			throw conversionError
		}
	}

	private func outputFileByteCount(at url: URL) throws -> UInt64 {
		guard let byteCount = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
			throw NativeModelCoreMLEmissionError.outputFileSizeUnavailable(url.lastPathComponent)
		}
		return byteCount.uint64Value
	}

	private func convertReserved(
		from packageURL: URL,
		to outputURL: URL,
		sourceProvenance: NativeModelConversionSourceProvenance,
		reporting progress: NativeModelConversionProgressHandler?
	) async throws -> NativeModelConversionMetrics {
		let conversionSignpostID = OSSignpostID(log: NativeModelConversionInstrumentation.log)
		NativeModelConversionInstrumentation.begin("Native model conversion", signpostID: conversionSignpostID)
		let processMemoryTracker = NativeModelConversionMemoryTracker()
		let report: NativeModelConversionProgressHandler = { update in
			NativeModelConversionInstrumentation.event(update.phase)
			let observedUpdate = update.withProcessMemoryUsage(processMemoryTracker.sample())
			progress?(observedUpdate)
		}
		report(NativeModelConversionProgress(phase: .preparing))
		let cancellationCheck: NativeModelConversionCancellationHandler = {
			try Task.checkCancellation()
		}

		do {
			try cancellationCheck()
			let readSignpostID = OSSignpostID(log: NativeModelConversionInstrumentation.log)
			NativeModelConversionInstrumentation.begin("Read native model package", signpostID: readSignpostID)
		let readStartedAt = DispatchTime.now().uptimeNanoseconds
			let package: NativeModelGraphPackage
			do {
				package = try await reader.read(
					from: packageURL,
					reporting: report,
					checkingCancellation: cancellationCheck
				)
			} catch {
				NativeModelConversionInstrumentation.end("Read native model package", signpostID: readSignpostID)
				throw conversionError(from: error, defaultPhase: .readingManifest)
			}
		let readDuration = elapsedNanoseconds(since: readStartedAt)
			NativeModelConversionInstrumentation.end("Read native model package", signpostID: readSignpostID)
			NativeModelConversionInstrumentation.packageRead(
				inputByteCount: package.sourceFootprint.totalByteCount,
				operationCount: package.graph.operations.count
			)

			let emissionSignpostID = OSSignpostID(log: NativeModelConversionInstrumentation.log)
			NativeModelConversionInstrumentation.begin("Emit Core ML model", signpostID: emissionSignpostID)
			let emission: NativeModelEmissionMetrics
			do {
				emission = try emitter.emit(
					package: package,
					to: outputURL,
					sourceProvenance: sourceProvenance,
					reporting: report,
					checkingCancellation: cancellationCheck
				)
			} catch {
				NativeModelConversionInstrumentation.end("Emit Core ML model", signpostID: emissionSignpostID)
				throw conversionError(from: error, defaultPhase: .emittingModel)
			}
			NativeModelConversionInstrumentation.end("Emit Core ML model", signpostID: emissionSignpostID)
			NativeModelConversionInstrumentation.modelEmitted(
				outputByteCount: emission.outputModelByteCount,
				operationCount: emission.operationCount
			)

			let metrics = NativeModelConversionMetrics(
				sourceFootprint: package.sourceFootprint,
				packageReadDurationNanoseconds: readDuration,
				emission: emission,
				processMemoryUsage: processMemoryTracker.sample()
			)
			report(NativeModelConversionProgress(phase: .completed, completedUnitCount: 1, totalUnitCount: 1))
			NativeModelConversionInstrumentation.end("Native model conversion", signpostID: conversionSignpostID)
			return metrics
		} catch is CancellationError {
			let conversionError = NativeModelConversionError.cancelled(phase: .preparing)
			report(NativeModelConversionProgress(phase: .cancelled))
			NativeModelConversionInstrumentation.error(code: conversionError.diagnostic.code, phase: conversionError.diagnostic.phase)
			NativeModelConversionInstrumentation.end("Native model conversion", signpostID: conversionSignpostID)
			throw conversionError
		} catch let error as NativeModelConversionError {
			let terminalPhase: NativeModelConversionPhase
			switch error {
			case .cancelled:
				terminalPhase = .cancelled
			case .package, .emission, .unexpected:
				terminalPhase = .failed
			}
			report(NativeModelConversionProgress(phase: terminalPhase))
			NativeModelConversionInstrumentation.error(code: error.diagnostic.code, phase: error.diagnostic.phase)
			NativeModelConversionInstrumentation.end("Native model conversion", signpostID: conversionSignpostID)
			throw error
		} catch {
			NativeModelConversionInstrumentation.unexpected(rawDescription: error.localizedDescription)
			let conversionError = NativeModelConversionError.unexpected(
				phase: .preparing,
				message: NativeModelConversionError.unexpectedMessage
			)
			report(NativeModelConversionProgress(phase: .failed))
			NativeModelConversionInstrumentation.error(code: conversionError.diagnostic.code, phase: conversionError.diagnostic.phase)
			NativeModelConversionInstrumentation.end("Native model conversion", signpostID: conversionSignpostID)
			throw conversionError
		}
	}

	private func conversionError(from error: Error, defaultPhase: NativeModelConversionPhase) -> NativeModelConversionError {
		if let error = error as? NativeModelConversionError {
			return error
		}
		if let error = error as? NativeModelGraphPackageError {
			return .package(error)
		}
		if let error = error as? NativeModelCoreMLEmissionError {
			return .emission(error)
		}
		if error is CancellationError {
			return .cancelled(phase: defaultPhase)
		}
		NativeModelConversionInstrumentation.unexpected(rawDescription: error.localizedDescription)
		return .unexpected(phase: defaultPhase, message: NativeModelConversionError.unexpectedMessage)
	}
}

/// A process-wide FIFO gate for high-level conversion jobs.
///
/// Conversions materialize the source weights and target protobuf in memory. Serializing complete
/// jobs makes that working-set cost predictable on iPhone and iPad, and prevents multiple imports
/// from competing for file I/O or Core ML conversion resources. This gate applies to every
/// ``NativeModelConverter/convert(from:to:reporting:)`` call in the process.
private actor NativeModelConversionExecutionGate {
	private struct Waiter {
		let id: UUID
		let continuation: CheckedContinuation<Void, Error>
	}

	private var isExecuting = false
	private var waiters: [Waiter] = []

	/// How many jobs are queued behind the running one.
	///
	/// Exists for tests, and for a reason worth stating: a caller reports
	/// ``NativeModelConversionPhase/waitingForExclusiveAccess`` *before* it awaits ``acquire()``, so
	/// that progress callback is not evidence that the job holds a queue slot yet. A test that
	/// treats it as evidence — and then launches the next job — is racing the actor hop between the
	/// two, and Swift gives no ordering guarantee for contending hops from different tasks. This is
	/// the only observable that answers "is it actually enqueued".
	var queuedJobCount: Int { waiters.count }

	func acquire() async throws {
		try Task.checkCancellation()
		guard isExecuting else {
			isExecuting = true
			return
		}

		let id = UUID()
		try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				if Task.isCancelled {
					continuation.resume(throwing: CancellationError())
				} else {
					waiters.append(Waiter(id: id, continuation: continuation))
				}
			}
		}, onCancel: {
			Task { await self.cancelWaiter(id: id) }
		})
	}

	/// Hands the gate to the longest-waiting job, or opens it when nobody is queued.
	///
	/// Ownership transfers directly: `isExecuting` deliberately stays `true` when a waiter is
	/// resumed, because the gate never becomes free between the two.
	func release() {
		guard waiters.isEmpty == false else {
			isExecuting = false
			return
		}
		waiters.removeFirst().continuation.resume()
	}

	private func cancelWaiter(id: UUID) {
		guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
		let waiter = waiters.remove(at: index)
		waiter.continuation.resume(throwing: CancellationError())
	}
}

func elapsedNanoseconds(since start: UInt64) -> UInt64 {
	let end = DispatchTime.now().uptimeNanoseconds
	return end >= start ? end - start : 0
}
