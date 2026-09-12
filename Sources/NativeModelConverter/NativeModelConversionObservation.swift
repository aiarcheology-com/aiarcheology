//
//  NativeModelConversionObservation.swift
//  NativeModelConverter
//
//  Client-visible progress and diagnostics for native conversion.
//

import Foundation

/// A stable conversion stage suitable for a UI, support report, or instrumentation event.
public enum NativeModelConversionPhase: String, Codable, CaseIterable, Sendable {
	case waitingForExclusiveAccess
	case preparing
	case readingManifest
	case validatingManifest
	case readingGraph
	case validatingGraph
	case readingWeights
	case validatingWeights
	case readingMetadata
	case validatingMetadata
	case emittingModel
	case writingModel
	case writingMetadata
	case completed
	case cancelled
	case failed
}

/// A progress update emitted synchronously by the conversion work.
///
/// Package phases report one completed unit when their work finishes. During
/// ``NativeModelConversionPhase/emittingModel``, `totalUnitCount` is the exact graph operation
/// count and `completedUnitCount` advances after each serialized operation. This is deliberately
/// phase-local rather than an invented global percentage: the complete operation count is unknown
/// until `graph.json` has been validated.
public struct NativeModelConversionProgress: Codable, Equatable, Sendable {
	public let phase: NativeModelConversionPhase
	public let completedUnitCount: Int
	public let totalUnitCount: Int
	public let operationName: String?
	/// Process-level memory sampled at this conversion boundary, when available.
	///
	/// The sample is for the full host process and its peak is only the largest value observed at
	/// progress boundaries. See ``NativeModelConversionProcessMemoryUsage`` for the precise scope.
	public let processMemoryUsage: NativeModelConversionProcessMemoryUsage?

	public init(
		phase: NativeModelConversionPhase,
		completedUnitCount: Int = 0,
		totalUnitCount: Int = 0,
		operationName: String? = nil,
		processMemoryUsage: NativeModelConversionProcessMemoryUsage? = nil
	) {
		self.phase = phase
		self.completedUnitCount = completedUnitCount
		self.totalUnitCount = totalUnitCount
		self.operationName = operationName
		self.processMemoryUsage = processMemoryUsage
	}

	/// The phase-local fraction when the phase has a non-zero number of units.
	public var fractionCompleted: Double? {
		guard totalUnitCount > 0 else { return nil }
		return Double(completedUnitCount) / Double(totalUnitCount)
	}

	func withProcessMemoryUsage(_ processMemoryUsage: NativeModelConversionProcessMemoryUsage?) -> Self {
		Self(
			phase: phase,
			completedUnitCount: completedUnitCount,
			totalUnitCount: totalUnitCount,
			operationName: operationName,
			processMemoryUsage: processMemoryUsage
		)
	}
}

/// A callback invoked from the conversion executor. Dispatch UI changes to the main actor.
public typealias NativeModelConversionProgressHandler = @Sendable (NativeModelConversionProgress) -> Void

/// A cooperative cancellation checkpoint used between package and emission units of work.
///
/// The high-level converter supplies `Task.checkCancellation()`. Direct users of the reader or
/// emitter can supply the same check when they need cancellation at their own boundary.
public typealias NativeModelConversionCancellationHandler = @Sendable () throws -> Void

/// A stable, serializable diagnostic that can be shown to a user or copied into a support report.
///
/// The diagnostic intentionally contains no file path. Clients that need to attach the original
/// package should ask the user explicitly rather than collecting a user document implicitly.
public struct NativeModelConversionDiagnostic: Codable, Equatable, Sendable {
	public let code: String
	public let phase: NativeModelConversionPhase
	public let message: String

	public init(code: String, phase: NativeModelConversionPhase, message: String) {
		self.code = code
		self.phase = phase
		self.message = message
	}
}

/// An error produced by the high-level native conversion API.
///
/// Lower-level package and emission errors remain available as associated values. `diagnostic`
/// gives every caller a stable code, phase, and user-readable message without requiring it to
/// pattern-match implementation details.
public enum NativeModelConversionError: Error, Equatable, LocalizedError, Sendable {
	case package(NativeModelGraphPackageError)
	case emission(NativeModelCoreMLEmissionError)
	case cancelled(phase: NativeModelConversionPhase)
	case unexpected(phase: NativeModelConversionPhase, message: String)

	/// Stable, path-free message for an error the converter could not classify. The raw underlying
	/// description is recorded only as private unified-log data, never in this shareable diagnostic.
	static let unexpectedMessage = "An unexpected error occurred during native model conversion."

	public var diagnostic: NativeModelConversionDiagnostic {
		switch self {
		case .package(let error):
			NativeModelConversionDiagnostic(
				code: "package.\(error.diagnosticCode)",
				phase: error.conversionPhase,
				message: error.localizedDescription
			)
		case .emission(let error):
			NativeModelConversionDiagnostic(
				code: "emission.\(error.diagnosticCode)",
				phase: error.conversionPhase,
				message: error.localizedDescription
			)
		case .cancelled(let phase):
			NativeModelConversionDiagnostic(
				code: "cancelled",
				phase: phase,
				message: "Conversion was cancelled during \(phase.rawValue)."
			)
		case .unexpected(let phase, let message):
			NativeModelConversionDiagnostic(code: "unexpected", phase: phase, message: message)
		}
	}

	public var errorDescription: String? {
		let diagnostic = diagnostic
		return "[native-model-conversion.\(diagnostic.code)] \(diagnostic.message)"
	}
}

extension NativeModelGraphPackageError {
	public var diagnosticCode: String {
		switch self {
		case .notDirectory: "notDirectory"
		case .missingFile: "missingFile"
		case .symbolicLinkNotAllowed: "symbolicLinkNotAllowed"
		case .notRegularFile: "notRegularFile"
		case .invalidFileMetadata: "invalidFileMetadata"
		case .fileTooLarge: "fileTooLarge"
		case .invalidManifest: "invalidManifest"
		case .unexpectedFile: "unexpectedFile"
		case .invalidGraphJSON: "invalidGraphJSON"
		case .invalidGraph: "invalidGraph"
		case .graphChecksumMismatch: "graphChecksumMismatch"
		case .weightsChecksumMismatch: "weightsChecksumMismatch"
		case .metadataChecksumMismatch: "metadataChecksumMismatch"
		case .invalidMetadataJSON: "invalidMetadataJSON"
		case .truncatedWeights: "truncatedWeights"
		}
	}

	public var conversionPhase: NativeModelConversionPhase {
		switch self {
		case .notDirectory, .missingFile, .symbolicLinkNotAllowed, .notRegularFile, .invalidFileMetadata, .fileTooLarge:
			.readingManifest
		case .invalidManifest, .unexpectedFile:
			.validatingManifest
		case .invalidGraphJSON, .invalidGraph, .graphChecksumMismatch:
			.validatingGraph
		case .weightsChecksumMismatch, .truncatedWeights:
			.validatingWeights
		case .metadataChecksumMismatch, .invalidMetadataJSON:
			.validatingMetadata
		}
	}
}

extension NativeModelCoreMLEmissionError {
	public var diagnosticCode: String {
		switch self {
		case .invalidGraph: "invalidGraph"
		case .unsupportedOperation: "unsupportedOperation"
		case .missingOutputTensor: "missingOutputTensor"
		case .missingWeight: "missingWeight"
		case .weightDataOutOfBounds: "weightDataOutOfBounds"
		case .invalidConvolution: "invalidConvolution"
		case .invalidOperation: "invalidOperation"
		case .invalidDetectionInterface: "invalidDetectionInterface"
		case .outputFileSizeUnavailable: "outputFileSizeUnavailable"
		}
	}

	public var conversionPhase: NativeModelConversionPhase {
		switch self {
		case .outputFileSizeUnavailable:
			.writingModel
		default:
			.emittingModel
		}
	}
}
