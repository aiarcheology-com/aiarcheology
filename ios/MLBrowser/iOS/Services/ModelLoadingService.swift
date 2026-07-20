//
//  ModelLoadingService.swift
//  AI Archeology
//
//  Created by Agent on 2025-12-29.
//

import Foundation
import CoreML
import OSLog
import NativeModelConverter

/// Sendable struct containing extracted model metadata.
/// Safe to pass across actor boundaries.
public struct ExtractedModelInfo: Sendable, Equatable {
    public let modelVersion: String?
    public let modelDescription: String?
    public let author: String?
    /// The source license declared in the Core ML model's standard metadata. Blank metadata is
    /// normalized to `nil` so persistence and presentation never manufacture an empty license.
    public let license: String?
    public let creationDateString: String?
    public let task: DeepDriverType
    /// `true` when `task` came from the metadata parser (authoritative). `false` when the parser
    /// couldn't determine it and `task` is a structural-signature recommendation for the user to
    /// confirm — the driver of the locked-vs-editable type control (AIA-0402).
    public let typeWasParsed: Bool
    /// A one-time import warning for a converted model whose emitted labels were selected from a
    /// known convention or generated because the source carried no labels. This is deliberately
    /// transient: the model metadata remains the durable audit trail, not Core Data.
    public let nativeModelImportAssumption: NativeModelImportAssumption?

    public init(
        modelVersion: String?,
        modelDescription: String?,
        author: String?,
        license: String? = nil,
        creationDateString: String?,
        task: DeepDriverType,
        typeWasParsed: Bool,
        nativeModelImportAssumption: NativeModelImportAssumption? = nil
    ) {
        self.modelVersion = modelVersion
        self.modelDescription = modelDescription
        self.author = author
        self.license = ModelLoadingService.normalizedMetadataString(license)
        self.creationDateString = creationDateString
        self.task = task
        self.typeWasParsed = typeWasParsed
        self.nativeModelImportAssumption = nativeModelImportAssumption
    }
}

/// A fallback-label fact extracted from a complete converter target-semantics contract.
///
/// The app never guesses this from a model's output shape. Metadata-backed labels deliberately
/// produce `nil`, even when the converter also added a known image preprocessing layer.
public struct NativeModelImportAssumption: Sendable, Equatable {
    public let labelProfile: NativeModelTargetSemantics.LabelProfile
    public let preprocessingProfile: NativeModelTargetSemantics.PreprocessingProfile

    init?(targetSemantics: NativeModelTargetSemantics) {
        guard targetSemantics.requiresImportAssumptionNotice else { return nil }
        labelProfile = targetSemantics.labelProfile
        preprocessingProfile = targetSemantics.preprocessingProfile
    }
}

/// Error types for model loading operations.
public enum ModelLoadingError: Error, LocalizedError {
    case modelLoadFailed(URL)
    case metadataExtractionFailed(URL)
    case compilationFailed(URL, Error)
    case modelTypeNotDetermined(URL)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let url):
            return "Failed to load model from \(url.lastPathComponent)"
        case .metadataExtractionFailed(let url):
            return "Failed to extract metadata from \(url.lastPathComponent)"
        case .compilationFailed(let url, let underlyingError):
            return "Failed to compile model \(url.lastPathComponent): \(underlyingError.localizedDescription)"
        case .modelTypeNotDetermined(let url):
            return "Could not determine model type for \(url.lastPathComponent). The model metadata must specify a supported type (detector or classifier)."
        }
    }
}

/// Narrow boundary for metadata extraction from a Core ML model.
///
/// `ModelTypeBackfiller` uses the same extraction path as import, while tests can provide a
/// deterministic loader without compiling a fixture model.
protocol ModelMetadataLoading: Sendable {
    func loadAndExtractMetadata(from url: URL, demo: Bool) async throws -> ExtractedModelInfo
}

/// Actor responsible for loading ML models and extracting metadata off the MainActor.
///
/// This service handles:
/// - Model compilation (for non-demo models)
/// - Model loading via `MLModel.load()`
/// - Metadata extraction using `MLModelMetadataParser`
///
/// All operations run on the actor's executor, not on MainActor,
/// ensuring UI responsiveness during model import.
///
/// Usage:
/// ```swift
/// let service = ModelLoadingService()
/// let info = try await service.loadAndExtractMetadata(from: modelURL, demo: false)
/// // info is Sendable, safe to use on MainActor
/// ```
public actor ModelLoadingService: ModelMetadataLoading {

    public init() {}

    /// Loads a model and extracts its metadata.
    ///
    /// For non-demo models (`demo == false`), this method first compiles the model
    /// using `MLModel.compileModel(at:)`, which can be CPU-intensive.
    ///
    /// - Parameters:
    ///   - url: The URL of the model file (.mlmodel, .mlpackage, or .mlmodelc)
    ///   - demo: If `true`, skips compilation (assumes pre-compiled .mlmodelc)
    /// - Returns: Extracted model metadata as a `Sendable` struct
    /// - Throws: `ModelLoadingError` if loading or metadata extraction fails
    public func loadAndExtractMetadata(from url: URL, demo: Bool) async throws -> ExtractedModelInfo {
        LoggingPolicy.debug("ModelLoadingService: Loading model from \(url.lastPathComponent), demo=\(demo)", logger: .drivers)

        // Compile model if needed (non-demo models)
        let compiledURL: URL
        if demo {
            compiledURL = url
        } else {
            do {
                compiledURL = try await MLModel.compileModel(at: url)
                LoggingPolicy.debug("ModelLoadingService: Model compiled to \(compiledURL.lastPathComponent)", logger: .drivers)
            } catch {
                LoggingPolicy.error("ModelLoadingService: Compilation failed", error: error, logger: .drivers)
                throw ModelLoadingError.compilationFailed(url, error)
            }
        }

        // Load the model
        let modelConfiguration = MLModelConfiguration()
        let model: MLModel
        do {
            model = try await MLModel.load(contentsOf: compiledURL, configuration: modelConfiguration)
            LoggingPolicy.debug("ModelLoadingService: Model loaded successfully", logger: .drivers)
        } catch {
            LoggingPolicy.error("ModelLoadingService: Load failed", error: error, logger: .drivers)
            throw ModelLoadingError.modelLoadFailed(url)
        }

        // Extract metadata. Empty metadata is not fatal (AIA-0402): the parser then yields nils and
        // an undetermined type, and the structural-signature fallback below still lets a runnable
        // model import (as Disabled if inconclusive) rather than rejecting it outright.
        let metadata = model.modelDescription.metadata
        if metadata.isEmpty {
            LoggingPolicy.warning("ModelLoadingService: Model has no metadata; relying on structural signature", logger: .drivers)
        }

        let parser = MLModelMetadataParser(metadata: metadata)
        let nativeModelImportAssumption = Self.nativeModelImportAssumption(from: metadata)

        // Determine the model type. The metadata `task`/preview/turi key is authoritative when the
        // parser yields one; when it can't (`.invalid`), the type was NOT parsed — fall back to the
        // model's structural signature as a *recommendation* the user confirms, and record that the
        // parser didn't decide so the type control can lock (parsed) or open for editing (AIA-0402).
        let parserTask = parser.task
        let typeWasParsed = parserTask != .invalid
        let task = typeWasParsed ? parserTask : Self.inferType(from: model.modelDescription)

        let info = ExtractedModelInfo(
            modelVersion: parser.modelVersion,
            modelDescription: parser.value(for: .description) as? String,
            author: parser.value(for: .author) as? String,
            license: Self.normalizedMetadataString(parser.value(for: .license)),
            creationDateString: parser.value(for: .date) as? String,
            task: task,
            typeWasParsed: typeWasParsed,
            nativeModelImportAssumption: nativeModelImportAssumption
        )

        LoggingPolicy.info("ModelLoadingService: Metadata extracted - task=\(info.task.rawValue), parsed=\(typeWasParsed), author=\(info.author ?? "unknown")", logger: .drivers)

        return info
    }

    /// Core ML reports some absent standard metadata fields as an empty string. Treat it as absent
    /// rather than persisting a value the configuration screen would have to render as an empty row.
    static func normalizedMetadataString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Parses the converter's versioned target-semantics contract from Core ML creator metadata.
    /// A missing, older, malformed, or unknown contract is intentionally silent rather than guessed.
    static func nativeModelImportAssumption(
        from metadata: [MLModelMetadataKey: Any]
    ) -> NativeModelImportAssumption? {
        guard let userDefined = metadata[.creatorDefinedKey] as? [String: String],
            let targetSemantics = NativeModelTargetSemantics(userDefined: userDefined)
        else {
            return nil
        }
        return NativeModelImportAssumption(targetSemantics: targetSemantics)
    }

    /// Validates that a model can be loaded without extracting full metadata.
    ///
    /// Useful for quick validation checks.
    ///
    /// - Note: As of AIA-0402, a model whose type can't be determined is no longer rejected — it
    ///   loads as Disabled. So this returns `true` for any model that compiles and loads, including
    ///   one that will import with an undetermined (Disabled) type for the user to set.
    ///
    /// - Parameters:
    ///   - url: The URL of the model file
    ///   - demo: If `true`, skips compilation
    /// - Returns: `true` if the model loads successfully
    public func validateModel(at url: URL, demo: Bool) async -> Bool {
        do {
            _ = try await loadAndExtractMetadata(from: url, demo: demo)
            return true
        } catch {
            LoggingPolicy.warning("ModelLoadingService: Validation failed for \(url.lastPathComponent)", logger: .drivers)
            return false
        }
    }

    /// Suggests a model type from the model's structural signature, used as a fallback when the
    /// `task` metadata key is absent (AIA-0402). Advisory only: a structural match does not
    /// guarantee the model produces the Vision observations the driver expects, so the user can
    /// always override the suggestion. Returns `.invalid` (Disabled) when inconclusive.
    ///
    /// - Classifier: the model exposes a predicted-feature name (Core ML classifier convention;
    ///   Vision then yields `VNClassificationObservation`).
    /// - Detector: outputs include both `confidence` and `coordinates` (the CreateML / Vision
    ///   object-detector convention this app's `Detector` relies on).
    static func inferType(from description: MLModelDescription) -> DeepDriverType {
        // Classifier signal first: `predictedFeatureName` can be an empty string (not nil) on
        // non-classifiers, so require a non-empty value.
        if description.predictedFeatureName?.isEmpty == false {
            return .classificator
        }

        let outputs = description.outputDescriptionsByName
        if outputs["confidence"] != nil && outputs["coordinates"] != nil {
            return .detector
        }

        return .invalid
    }
}
