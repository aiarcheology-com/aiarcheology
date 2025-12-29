//
//  ModelLoadingService.swift
//  AI Archeology
//
//  Created by Agent on 2025-12-29.
//

import Foundation
import CoreML
import OSLog

/// Sendable struct containing extracted model metadata.
/// Safe to pass across actor boundaries.
public struct ExtractedModelInfo: Sendable, Equatable {
    public let modelVersion: String?
    public let modelDescription: String?
    public let author: String?
    public let creationDateString: String?
    public let task: DeepDriverType

    public init(
        modelVersion: String?,
        modelDescription: String?,
        author: String?,
        creationDateString: String?,
        task: DeepDriverType
    ) {
        self.modelVersion = modelVersion
        self.modelDescription = modelDescription
        self.author = author
        self.creationDateString = creationDateString
        self.task = task
    }
}

/// Error types for model loading operations.
public enum ModelLoadingError: Error, LocalizedError {
    case modelLoadFailed(URL)
    case metadataExtractionFailed(URL)
    case compilationFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let url):
            return "Failed to load model from \(url.lastPathComponent)"
        case .metadataExtractionFailed(let url):
            return "Failed to extract metadata from \(url.lastPathComponent)"
        case .compilationFailed(let url, let underlyingError):
            return "Failed to compile model \(url.lastPathComponent): \(underlyingError.localizedDescription)"
        }
    }
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
public actor ModelLoadingService {

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

        // Extract metadata
        let metadata = model.modelDescription.metadata
        guard !metadata.isEmpty else {
            LoggingPolicy.warning("ModelLoadingService: Model has no metadata", logger: .drivers)
            throw ModelLoadingError.metadataExtractionFailed(url)
        }

        let parser = MLModelMetadataParser(metadata: metadata)

        let info = ExtractedModelInfo(
            modelVersion: parser.modelVersion,
            modelDescription: parser.value(for: .description) as? String,
            author: parser.value(for: .author) as? String,
            creationDateString: parser.value(for: .date) as? String,
            task: parser.task
        )

        LoggingPolicy.info("ModelLoadingService: Metadata extracted - task=\(info.task.rawValue), author=\(info.author ?? "unknown")", logger: .drivers)

        return info
    }

    /// Validates that a model can be loaded without extracting full metadata.
    ///
    /// Useful for quick validation checks.
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
}
