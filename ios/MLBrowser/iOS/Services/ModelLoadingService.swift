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
    /// An already-compiled `.mlmodelc` bundle that Core ML would not load (AIA-0844). Carries the
    /// underlying error because the likely causes — a bundle compiled for another platform or OS, or
    /// a directory that merely wears the extension — are only distinguishable from Core ML's message.
    case compiledModelLoadFailed(URL, Error)
    case modelTypeNotDetermined(URL)
    /// Refused before `MLModel.load` because this process's remaining headroom cannot plausibly
    /// hold the load (AIA-0889). Byte counts, not a file name: the caller decides how to phrase it.
    case insufficientMemory(URL, requiredByteCount: UInt64, availableByteCount: UInt64)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let url):
            return "Failed to load model from \(url.lastPathComponent)"
        case .compiledModelLoadFailed(let url, let underlyingError):
            // Core ML's wording is quoted inside parentheses; a trailing period would otherwise read
            // as "(…).", so it is stripped along with surrounding whitespace.
            var reason = underlyingError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.hasSuffix(".") {
                reason.removeLast()
            }
            return "Could not load the compiled model \(url.lastPathComponent) on this device (\(reason)). Compiled .mlmodelc bundles are platform-specific; import the .mlmodel or .mlpackage it was built from instead."
        case .metadataExtractionFailed(let url):
            return "Failed to extract metadata from \(url.lastPathComponent)"
        case .compilationFailed(let url, let underlyingError):
            return "Failed to compile model \(url.lastPathComponent): \(underlyingError.localizedDescription)"
        case .modelTypeNotDetermined(let url):
            return "Could not determine model type for \(url.lastPathComponent). The model metadata must specify a supported type (detector or classifier)."
        case .insufficientMemory(let url, let requiredByteCount, let availableByteCount):
            // Localized, unlike its siblings: this one is shown to an ordinary user hitting a device
            // limit, not to someone diagnosing a malformed file. It names the file like every
            // sibling — this is the import alert, not the shareable conversion diagnostic, and the
            // strict path/raw-error rail applies to the latter only.
            return L10n.Import.Error.insufficientMemory(
                url.lastPathComponent,
                Self.megabytes(requiredByteCount),
                Self.megabytes(availableByteCount)
            )
        }
    }

    /// True for a load refused on memory alone.
    ///
    /// Callers that keep a permanent-failure budget need to tell "this file cannot be loaded" apart
    /// from "not right now": only the former is evidence about the model.
    public var isInsufficientMemory: Bool {
        if case .insufficientMemory = self { return true }
        return false
    }

    /// Whole megabytes, for messages that must stay readable and carry no fractional noise.
    ///
    /// A non-zero amount never renders as "0 MB": truncating a real requirement to zero would make
    /// a refusal contradict itself. Only an actual zero — which a *reading* can legitimately be,
    /// unlike a requirement — prints as zero.
    static func megabytes(_ byteCount: UInt64) -> String {
        let wholeMegabytes = byteCount / (1024 * 1024)
        if wholeMegabytes == 0, byteCount > 0 {
            return "less than 1 MB"
        }
        return "\(wholeMegabytes) MB"
    }
}

// MARK: - Load-time memory admission (AIA-0889)

/// What this *process* has left against its own jetsam limit — not device free RAM.
///
/// `unavailable` means no per-process limit meaningfully applies (simulator, iOS-app-on-Mac), which
/// is categorically different from a reported zero. On a real iOS app a zero means the process has
/// already exceeded its limit, so it must refuse rather than wave the load through.
public enum ModelLoadHeadroom: Equatable, Sendable {
    case bytes(UInt64)
    case unavailable
}

/// The admission decision for one model load.
public enum ModelLoadAdmission: Equatable, Sendable {
    case admit
    case refuse(requiredByteCount: UInt64, availableByteCount: UInt64)
}

/// Whether a given caller's load is subject to the memory gate.
public enum ModelLoadAdmissionPolicy: Equatable, Sendable {
    /// Refuse a load this process cannot plausibly hold. The right policy wherever the load is
    /// retryable — an import the user can repeat, a backfill row the next launch revisits.
    case enforced
    /// Load regardless of headroom.
    ///
    /// For app-owned bundled resources: they are small, their size is known at build time, and
    /// their seeding is *not* retryable. `DemoDataManager` skips all demo creation once any demo
    /// exists, so one refused demo is never created again — a permanent, silent loss traded
    /// against a gate that could never have fired on a bundled model anyway.
    case exempt
}

/// Refuses a Core ML load that this process's remaining headroom cannot plausibly hold.
///
/// AIA-0889: a ~200 MB converted model was loaded with `computeUnits = .all` while two detectors
/// were already resident, and the process was killed inside `MLModel.load` — no thrown error, no
/// diagnostic, just a relaunch. This gate turns the unlucky half of that race into a real error.
///
/// It narrows a window; it does not close one. Passing admission reserves nothing: the process
/// keeps allocating between the sample and the load, and ANE compilation runs out-of-process in
/// `ANECompilerService`, whose failures arrive as thrown errors no preflight can pre-empt.
public enum ModelLoadMemoryPreflight {
    /// Multiple of the model's on-disk size taken as the load's peak demand.
    ///
    /// Measured on two platforms, both for the same ~190 MB converted ADAF detector.
    ///
    /// - **iPad (8th generation, 3 GB, entitlement active)** — the authoritative iOS datapoint, and
    ///   a *lower bound*: a 199,964,757-byte model was admitted with 1,851,537,432 bytes of
    ///   headroom and the process was killed inside the load anyway. It therefore needed more than
    ///   **9.26×** the model's size. How much more is unknown, because it died rather than finished.
    /// - **macOS (Apple Silicon)** — a *completed* load: footprint rose 1,341,605,232 bytes for a
    ///   199,788,861-byte model, **6.72×**, peaking at 1.28 GB resident.
    ///
    /// The two agree rather than conflict: 6.72× is the resident cost after loading, while the
    /// iPad's kill proves the transient peak runs higher still. Note also that macOS charged
    /// 422 MB to `compileModel` while the device reported only 84 MB before the load — on iOS that
    /// compilation is farmed to a separate service, so it never enters this process's footprint.
    /// That asymmetry is why compilation survives on device and the load does not, and why this
    /// gate gates the load alone.
    ///
    /// 12 requires 2.4 GB for a model of this size: it refuses on the iPad, whose 1.72 GB of
    /// headroom genuinely is not enough, and admits wherever the real ~1.3–1.9 GB fits. Raise it
    /// against another killed load; lower it only against a *completed* one reporting a smaller
    /// ratio, since only a load that survives can measure the ceiling.
    ///
    /// The margin is deliberately biased and the cost is known. Demanding 2.4 GB for a load that
    /// needs ~1.9 GB leaves a band — roughly 1.9–2.4 GB of headroom, which a 4 GB device could sit
    /// in — where a model that *would* have loaded is refused instead. That is the accepted error:
    /// a refusal is visible, explains itself, and the user can retry after closing something, while
    /// the alternative is a silent kill that loses the work and leaves no diagnostic. If field logs
    /// show real devices refused in that band, this is the number to lower — with their reported
    /// headroom as the evidence.
    ///
    /// File size remains a proxy, not a model of the cost: `MLModel.load` performs device-specific
    /// specialization even after a successful `compileModel`, and weight encoding does not map
    /// uniformly onto resident bytes.
    static let loadFootprintFactor: UInt64 = 12

    /// Pure, so every branch is testable without a device.
    ///
    /// Fails **open** on an *unknown* input — an unreadable size or an inapplicable limit must
    /// never block a load that would have worked. Exhausted is not unknown: a known-zero headroom
    /// refuses whatever the size turns out to be, because no load allocates nothing and an
    /// unreadable size is no reason to disbelieve a budget the OS reported as spent.
    public static func decide(modelByteCount: UInt64?, headroom: ModelLoadHeadroom) -> ModelLoadAdmission {
        guard case .bytes(let availableByteCount) = headroom else { return .admit }

        // The requirement, or `nil` when the size could not be read. Overflow is carried alongside
        // the value rather than folded into it: saturating to `.max` and comparing would *admit*
        // against `.max` headroom, since `.max > .max` is false — failing open on exactly the
        // absurd input the saturation was meant to catch.
        let requirement: (byteCount: UInt64, overflowed: Bool)? = modelByteCount.map { byteCount in
            let (product, overflowed) = byteCount.multipliedReportingOverflow(by: loadFootprintFactor)
            return (overflowed ? .max : product, overflowed)
        }

        // Checked before the size fallback below. Exhausted is not unknown: the OS reported this
        // process as over its limit, and an unreadable size is no reason to disbelieve it. No Core
        // ML load allocates nothing, so nothing is admissible here — not even a zero-byte file,
        // whose emptiness says nothing about what loading it costs.
        guard availableByteCount > 0 else {
            // Never refuse while claiming a zero requirement. A zero-byte model still costs
            // something to load — the emptiness of the file says nothing about the cost — and a
            // message reading "needed about 0 MB" would contradict the refusal it explains.
            return .refuse(requiredByteCount: max(requirement?.byteCount ?? 1, 1), availableByteCount: 0)
        }

        // Only now may an unknown size fail open: there is real headroom, and blocking a load that
        // would have worked is the worse error.
        guard let requirement else { return .admit }
        guard requirement.overflowed || requirement.byteCount > availableByteCount else { return .admit }
        return .refuse(requiredByteCount: requirement.byteCount, availableByteCount: availableByteCount)
    }

    /// Advisory and never cached: Apple documents the value as a moment-in-time reading.
    public static func currentHeadroom() -> ModelLoadHeadroom {
        #if targetEnvironment(simulator)
        // The simulator imposes no app-like per-process limit, so a reading here would be noise.
        return .unavailable
        #else
        // "Designed for iPad" on macOS reports zero with no limit applied. Treating that as "no
        // headroom" would refuse every load on Mac, so it is classified, not measured.
        if ProcessInfo.processInfo.isiOSAppOnMac { return .unavailable }
        let available = os_proc_available_memory()
        return .bytes(available > 0 ? UInt64(available) : 0)
        #endif
    }
}

/// Narrow boundary for metadata extraction from a Core ML model.
///
/// `ModelTypeBackfiller` uses the same extraction path as import, while tests can provide a
/// deterministic loader without compiling a fixture model.
protocol ModelMetadataLoading: Sendable {
    func loadAndExtractMetadata(from url: URL) async throws -> ExtractedModelInfo
}

/// Actor responsible for loading ML models and extracting metadata off the MainActor.
///
/// This service handles:
/// - Model compilation (for `.mlmodel` / `.mlpackage` sources; a compiled `.mlmodelc` loads as-is)
/// - Model loading via `MLModel.load()`
/// - Metadata extraction using `MLModelMetadataParser`
///
/// All operations run on the actor's executor, not on MainActor,
/// ensuring UI responsiveness during model import.
///
/// Usage:
/// ```swift
/// let service = ModelLoadingService()
/// let info = try await service.loadAndExtractMetadata(from: modelURL)
/// // info is Sendable, safe to use on MainActor
/// ```
public actor ModelLoadingService: ModelMetadataLoading {

    /// Injected so the gate is reachable in tests. On a simulator the live reading is
    /// `.unavailable`, so without a seam every refusal path would be unexecutable and deleting the
    /// gate outright would leave the suite green.
    private let headroom: @Sendable () -> ModelLoadHeadroom

    public init(headroom: @escaping @Sendable () -> ModelLoadHeadroom = ModelLoadMemoryPreflight.currentHeadroom) {
        self.headroom = headroom
    }

    public func loadAndExtractMetadata(from url: URL) async throws -> ExtractedModelInfo {
        try await loadAndExtractMetadata(from: url, admission: .enforced)
    }

    /// Loads a model and extracts its metadata.
    ///
    /// The route is decided by the artifact's format, not by where the model came from: a source
    /// `.mlmodel` / `.mlpackage` is first compiled with `MLModel.compileModel(at:)` (CPU-intensive),
    /// while an already-compiled `.mlmodelc` — a bundled demo *or* an imported bundle — is loaded
    /// as-is, because Core ML refuses to compile a compiled bundle a second time (AIA-0844).
    ///
    /// - Parameter url: The URL of the model file (.mlmodel, .mlpackage, or .mlmodelc)
    /// - Returns: Extracted model metadata as a `Sendable` struct
    /// - Throws: `ModelLoadingError` if compiling, loading, or metadata extraction fails
    public func loadAndExtractMetadata(
        from url: URL,
        admission: ModelLoadAdmissionPolicy
    ) async throws -> ExtractedModelInfo {
        let isCompiled = url.isCompiledCoreMLModel
        LoggingPolicy.debug("ModelLoadingService: Loading model from \(url.lastPathComponent), compiled=\(isCompiled)", logger: .drivers)

        // Compile a source model; a compiled bundle is used directly.
        let compiledURL: URL
        if isCompiled {
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

        // AIA-0889: sampled in the same turn as the load, never earlier and never cached — the
        // value is a moment-in-time reading and the process keeps allocating around it.
        let modelByteCount = Self.byteCount(at: compiledURL)
        let headroom = admission == .exempt ? ModelLoadHeadroom.unavailable : self.headroom()
        let footprintBeforeLoad = NativeModelConversionProcessMemory.currentProcessFootprintByteCount()
        // Numbers only, no path: this is the record that makes `loadFootprintFactor` measurable
        // instead of guessed, so it has to survive into a support log.
        LoggingPolicy.info(
            "ModelLoadingService: load preflight — modelBytes=\(modelByteCount.map(String.init) ?? "unknown"), headroom=\(Self.headroomDescription(headroom)), footprintBefore=\(footprintBeforeLoad.map(String.init) ?? "unknown")",
            logger: .drivers
        )
        if case .refuse(let requiredByteCount, let availableByteCount) = ModelLoadMemoryPreflight.decide(
            modelByteCount: modelByteCount,
            headroom: headroom
        ) {
            LoggingPolicy.error(
                "ModelLoadingService: refusing load — required=\(requiredByteCount) available=\(availableByteCount)",
                logger: .drivers
            )
            throw ModelLoadingError.insufficientMemory(
                url,
                requiredByteCount: requiredByteCount,
                availableByteCount: availableByteCount
            )
        }

        // Load the model
        let modelConfiguration = MLModelConfiguration()
        let model: MLModel
        do {
            model = try await MLModel.load(contentsOf: compiledURL, configuration: modelConfiguration)
            // The observed cost of a load that survived. One device log carrying this ratio is what
            // turns the provisional factor into a measured one.
            let footprintAfterLoad = NativeModelConversionProcessMemory.currentProcessFootprintByteCount()
            LoggingPolicy.info(
                "ModelLoadingService: load complete — footprintAfter=\(footprintAfterLoad.map(String.init) ?? "unknown"), observedIncrease=\(Self.footprintIncrease(from: footprintBeforeLoad, to: footprintAfterLoad).map(String.init) ?? "unknown"), modelBytes=\(modelByteCount.map(String.init) ?? "unknown")",
                logger: .drivers
            )
            LoggingPolicy.debug("ModelLoadingService: Model loaded successfully", logger: .drivers)
        } catch {
            LoggingPolicy.error("ModelLoadingService: Load failed", error: error, logger: .drivers)
            // A compiled bundle that will not load has skipped the compile step's validation, so the
            // underlying error is the only clue (wrong platform, malformed bundle); keep it.
            throw isCompiled
                ? ModelLoadingError.compiledModelLoadFailed(url, error)
                : ModelLoadingError.modelLoadFailed(url)
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

    /// Total bytes at `url`, whether it is a file or a package directory.
    ///
    /// A source can be either: ONNX arrives as a single file, a native graph package as a
    /// directory. Summing the directory's contents is what makes the two comparable in a report.
    /// `nil` when the size cannot be read — a missing number is honest, a zero would not be.
    nonisolated static func byteCount(at url: URL) -> UInt64? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        guard isDirectory.boolValue else {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return UInt64(size)
        }
        // `nil` on the first unreadable entry rather than a partial sum: a number that silently
        // omits half a package is worse than no number, because a support reader cannot tell.
        var failed = false
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in
                failed = true
                return false
            }
        ) else { return nil }

        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else {
                return nil
            }
            // Directories and symlinks contribute nothing: a symlink reports its own metadata size,
            // not its target's, so counting it would double or mis-state the total.
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { continue }
            // Sparse or hostile inputs must not trap the app for a diagnostic number.
            let (sum, overflowed) = total.addingReportingOverflow(UInt64(size))
            if overflowed { return nil }
            total = sum
        }
        return failed ? nil : total
    }

    /// Renders headroom for the load-stage record without inventing a number for the case that
    /// deliberately has none.
    nonisolated static func headroomDescription(_ headroom: ModelLoadHeadroom) -> String {
        switch headroom {
        case .bytes(let byteCount): "\(byteCount)"
        case .unavailable: "unavailable"
        }
    }

    /// The load's observed cost, or `nil` when either sample is missing or the footprint fell —
    /// a negative "increase" would be an artefact of sampling, not a measurement.
    nonisolated static func footprintIncrease(from before: UInt64?, to after: UInt64?) -> UInt64? {
        guard let before, let after, after >= before else { return nil }
        return after - before
    }

    /// Core ML reports some absent standard metadata fields as an empty string. Treat it as absent
    /// rather than persisting a value the configuration screen would have to render as an empty row.
    static func normalizedMetadataString(_ value: Any?) -> String? {
        let string: String?
        if let direct = value as? String {
            string = direct
        } else if let optional = value as? String? {
            string = optional
        } else {
            return nil
        }
        guard let string else { return nil }
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
    /// - Parameter url: The URL of the model file (.mlmodel, .mlpackage, or .mlmodelc)
    /// - Returns: `true` if the model loads successfully
    public func validateModel(at url: URL) async -> Bool {
        do {
            _ = try await loadAndExtractMetadata(from: url)
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
