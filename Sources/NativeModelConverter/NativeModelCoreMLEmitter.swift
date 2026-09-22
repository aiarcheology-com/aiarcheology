//
//  NativeModelCoreMLEmitter.swift
//  NativeModelConverter
//
//  Emits a Core ML neural-network protobuf from a validated native graph.
//

import Foundation

/// All of the fixed ADAF conversion facts required by the file-backed emitter.
///
/// This stays internal because only the closed detector registry can construct a valid request.
struct NativeModelADAFEmissionRequest {
	let graph: NativeModelGraph
	let promotedWeights: NativeModelADAFPromotedWeights
	let detection: NativeModelDetectionInterface
	let detectionTarget: NativeModelDetectionTargetInfo
	let imagePreprocessing: NativeModelImagePreprocessing
	let imageSizingContract: NativeModelImageSizingContract
	let targetSemanticsIntent: NativeModelTargetSemanticsIntent
	let parityEvidence: NativeModelParityEvidence
}

private let adafWeightsSHA256Placeholder = String(repeating: "x", count: 64)

/// Serializes the currently implemented native-graph subset as a Core ML neural-network model.
///
/// The emitter intentionally has a narrower operation set than `NativeModelGraphValidator`.
/// Validation answers whether a graph belongs to the version 1 interchange contract; this type
/// answers whether the installed native emitter can faithfully serialize it today. Unsupported
/// operations fail explicitly, which prevents a partially converted model from reaching Core ML.
public struct NativeModelCoreMLEmitter: Sendable {
	struct EmissionContext {
		let metadata: NativeModelCoreMLMetadata?
		/// The exact target interface resolved before metadata is written. Keeping this single plan
		/// prevents provenance from describing a requested image preprocessing that the emitter later
		/// declined because the graph input was not image-shaped.
		let interface: ResolvedEmissionInterface
		let progress: NativeModelConversionProgressHandler?
		let cancellationCheck: NativeModelConversionCancellationHandler?

		init(
			metadata: NativeModelCoreMLMetadata?,
			interface: ResolvedEmissionInterface,
			progress: NativeModelConversionProgressHandler?,
			cancellationCheck: NativeModelConversionCancellationHandler?
		) {
			self.metadata = metadata
			self.interface = interface
			self.progress = progress
			self.cancellationCheck = cancellationCheck
		}
	}

	private struct ModelBuildInput {
		let inputTensors: [NativeModelTensor]
		let outputTensors: [NativeModelTensor]
		let operations: [NativeModelOperation]
		let weightsByName: [String: NativeModelWeight]
		let weights: Data
	}

	/// The target facts decided once and used for both protobuf emission and target metadata.
	struct ResolvedEmissionInterface {
		let classifier: ClassifierPlan?
		let imagePlan: ImageInputPlan?
		let detection: NativeModelDetectionInterface?
		let detectionTarget: NativeModelDetectionTargetInfo?
		let targetSemantics: NativeModelTargetSemantics?

		var modelFormat: String {
			if detection != nil { return "pipeline" }
			return classifier == nil ? "neuralNetwork" : "neuralNetworkClassifier"
		}
	}

	public init() {}

	/// Emits a graph that contains no weights.
	///
	/// Use ``emit(graph:weights:to:)`` for convolutional and linear graphs. This overload remains
	/// useful for the initial activation-only conformance fixture and prevents accidental use of an
	/// empty weight blob with a weight-bearing graph.
	public func emit(graph: NativeModelGraph, to outputURL: URL) throws {
		try emit(graph: graph, weights: Data(), to: outputURL)
	}

	/// Emits a model from a graph package whose integrity has already been verified by
	/// ``NativeModelGraphPackageReader``.
	///
	/// When the package contains source metadata, this writes target-correct Core ML metadata into
	/// the model and an exact `<model-name>.metadata.json` sidecar beside it.
	///
	/// `parityEvidence` is the caller's claim about the emitted numerics and defaults to the
	/// unevidenced one: only a caller that actually ran a reference-oracle check may pass `.verified`.
	@discardableResult
	public func emit(
		package: NativeModelGraphPackage,
		to outputURL: URL,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
		parityEvidence: NativeModelParityEvidence = .unevidenced,
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws -> NativeModelEmissionMetrics {
		let emissionStartedAt = DispatchTime.now().uptimeNanoseconds
		try cancellationCheck?()
		let interface = try resolveEmissionInterface(
			graph: package.graph,
			classifierLabels: package.metadata?.labels,
			imagePreprocessing: nil,
			detection: nil,
			detectionTarget: nil,
			targetSemanticsIntent: package.metadata?.labels.map { _ in
				NativeModelTargetSemanticsIntent(
					labelProfile: .sourceMetadata,
					preprocessingProfile: .none
				)
			}
		)
		let metadata = try targetMetadata(
			from: package.metadata?.source,
			checksums: NativeModelConversionChecksums(
				weightsSHA256: package.manifest.weightsSHA256,
				graphSHA256: package.manifest.graphSHA256,
				metadataSHA256: package.manifest.metadataSHA256
			),
			graph: package.graph,
			sourceProvenance: sourceProvenance,
			interface: interface,
			parityEvidence: parityEvidence
		)
		try emit(
			graph: package.graph,
			weights: package.weights,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				interface: interface,
				progress: progress,
				cancellationCheck: cancellationCheck
			)
		)
		try cancellationCheck?()
		progress?(NativeModelConversionProgress(phase: .writingMetadata))
		try NativeModelMetadataSidecar.write(package.rawMetadata, beside: outputURL)
		progress?(NativeModelConversionProgress(phase: .writingMetadata, completedUnitCount: 1, totalUnitCount: 1))
		return NativeModelEmissionMetrics(
			sourceFootprint: package.sourceFootprint,
			operationCount: package.graph.operations.count,
			outputModelByteCount: try outputFileByteCount(at: outputURL),
			outputMetadataSidecarByteCount: UInt64(package.rawMetadata?.count ?? 0),
			emissionDurationNanoseconds: elapsedNanoseconds(since: emissionStartedAt)
		)
	}

	/// Writes a Core ML neural-network `.mlmodel`.
	///
	/// Version 4 is the first neural-network specification that preserves the exact rank of a
	/// multi-array feature. Float16 multi-array interfaces require version 7, so the emitter raises
	/// the specification version when needed. The first emission slice is intentionally limited to
	/// ReLU and Conv2D so the protobuf path and weight encoding can be compiled and executed before
	/// the rest of the MobileNetV2 operation sequence is added.
	public func emit(graph: NativeModelGraph, weights: Data, to outputURL: URL) throws {
		let interface = try resolveEmissionInterface(
			graph: graph,
			classifierLabels: nil,
			imagePreprocessing: nil,
			detection: nil,
			detectionTarget: nil,
			targetSemanticsIntent: nil
		)
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(metadata: nil, interface: interface, progress: nil, cancellationCheck: nil)
		)
	}

	/// Emits a Core ML classifier for a graph read from a standard image-classification model (e.g.
	/// ONNX). When `labels` match the single output width and the single input is image-shaped
	/// (`[1, C, H, W]`, C matching `imagePreprocessing`), the model exposes an image input with the
	/// given per-channel normalization and returns `classLabel`/`classLabelProbs`. If either condition
	/// does not hold, the graph is emitted as a plain neural network (labels/preprocessing ignored),
	/// so this is always safe to call.
	public func emit(
		graph: NativeModelGraph,
		weights: Data,
		to outputURL: URL,
		classifierLabels: [String]?,
		imagePreprocessing: NativeModelImagePreprocessing?,
		targetSemanticsIntent: NativeModelTargetSemanticsIntent? = nil,
		sourceMetadata: NativeModelCoreMLMetadata? = nil,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
		parityEvidence: NativeModelParityEvidence = .unevidenced,
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws {
		let interface = try resolveEmissionInterface(
			graph: graph,
			classifierLabels: classifierLabels,
			imagePreprocessing: imagePreprocessing,
			detection: nil,
			detectionTarget: nil,
			targetSemanticsIntent: targetSemanticsIntent
		)
		// Hash the exact blob being emitted for correct provenance. On this path that is `weights`.
		let metadata = try onnxTargetMetadata(
			source: sourceMetadata,
			sourceProvenance: sourceProvenance,
			graph: graph,
			emittedWeights: weights,
			interface: interface,
			parityEvidence: parityEvidence
		)
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				interface: interface,
				progress: progress,
				cancellationCheck: cancellationCheck
			)
		)
	}

	/// Emits the pinned ADAF detector without materialising its promoted Float32 weights or the
	/// enclosing Core ML protobuf. This is deliberately internal: the file-backed source is a closed
	/// registry contract, not a second general-purpose graph input API.
	func emit(
		adaf request: NativeModelADAFEmissionRequest,
		to outputURL: URL,
		reporting progress: NativeModelConversionProgressHandler?,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler?
	) throws {
		guard request.detectionTarget.classCount == request.detection.labels.count else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "detection target class count \(request.detectionTarget.classCount) does not match \(request.detection.labels.count) labels"
			)
		}
		let interface = try resolveEmissionInterface(
			graph: request.graph,
			classifierLabels: nil,
			imagePreprocessing: request.imagePreprocessing,
			detection: request.detection,
			detectionTarget: request.detectionTarget,
			targetSemanticsIntent: request.targetSemanticsIntent
		)
		let metadata = try targetMetadata(
			from: nil,
			checksums: NativeModelConversionChecksums(weightsSHA256: adafWeightsSHA256Placeholder),
			graph: request.graph,
			sourceProvenance: nil,
			interface: interface,
			imageSizingContract: request.imageSizingContract,
			parityEvidence: request.parityEvidence
		)
		let weightsDigest = NativeModelADAFPromotedWeightsDigest(logicalWeights: request.graph.weights)
		try emitStreamingADAF(
			graph: request.graph,
			promotedWeights: request.promotedWeights,
			weightsDigest: weightsDigest,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				interface: interface,
				progress: progress,
				cancellationCheck: cancellationCheck
			)
		)
	}

	/// Emits a graph as a Core ML detector: a two-stage pipeline whose first stage is the converted
	/// network and whose second is Core ML's non-maximum-suppression model. That second stage owns the
	/// policy for ordinary detector graphs and is a fixed interface adapter when the graph owns it. The
	/// resulting model publishes `coordinates`/`confidence`, which is what makes Vision return
	/// `VNRecognizedObjectObservation` and the app classify the import as a detector.
	///
	/// Throws rather than silently degrading to a plain network: unlike classifier labels — which are
	/// advisory and safely ignorable — a caller asking for a detector and getting a raw-tensor model
	/// would ship a model the detector driver cannot consume.
	public func emit(
		graph: NativeModelGraph,
		weights: Data,
		to outputURL: URL,
		detection: NativeModelDetectionInterface,
		detectionTarget: NativeModelDetectionTargetInfo,
		imagePreprocessing: NativeModelImagePreprocessing? = nil,
		imageSizingContract: NativeModelImageSizingContract? = nil,
		targetSemanticsIntent: NativeModelTargetSemanticsIntent? = nil,
		sourceMetadata: NativeModelCoreMLMetadata? = nil,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
		parityEvidence: NativeModelParityEvidence = .unevidenced,
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws {
		// The recorded class count must match the interface's labels; a mismatch would emit a model
		// whose metadata states a class count its confidence matrix does not have.
		guard detectionTarget.classCount == detection.labels.count else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "detection target class count \(detectionTarget.classCount) does not match \(detection.labels.count) labels"
			)
		}
		let interface = try resolveEmissionInterface(
			graph: graph,
			classifierLabels: nil,
			imagePreprocessing: imagePreprocessing,
			detection: detection,
			detectionTarget: detectionTarget,
			targetSemanticsIntent: targetSemanticsIntent
		)
		// `weights` here is the detector blob (network weights + synthesized decode constants), which
		// is exactly what gets emitted — so hashing it yields a truthful weights-sha256 for the
		// pipeline model. makeModel attaches this metadata to the OUTER pipeline description.
		let metadata = try onnxTargetMetadata(
			source: sourceMetadata,
			sourceProvenance: sourceProvenance,
			graph: graph,
			emittedWeights: weights,
			interface: interface,
			imageSizingContract: imageSizingContract,
			parityEvidence: parityEvidence
		)
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				interface: interface,
				progress: progress,
				cancellationCheck: cancellationCheck
			)
		)
	}

	/// Emits the model together with a standalone ROI box head chunk beside it, and records in the
	/// primary model's metadata which companion it needs and how to verify it.
	///
	/// Two independent `.mlmodel` files, never a Core ML pipeline: a pipeline stage is embedded in
	/// the outer model and runs inside the same `prediction` call, which is exactly the in-graph
	/// chunking AIA-0670 measured as saving nothing. See ``NativeModelROIBoxHeadChunkEmission``.
	///
	/// The companion is written first and the primary last. The primary is the discovery anchor — it
	/// is the file that carries the manifest — so publishing it before the companion exists would
	/// leave a model advertising a file that is not there.
	///
	/// The pair is not production-managed yet: the app's cleanup path removes exactly the model and
	/// its metadata sidecar, and the CLI reports one model size. Teaching those paths about
	/// companions is M3c; until then the caller owns the companion's lifetime.
	///
	/// One emission makes one parity claim, stamped on both files: the primary is useless without the
	/// chunk it drives, so a check that covered only one of them has not checked what this emission
	/// produces.
	@discardableResult
	public func emit(
		graph: NativeModelGraph,
		weights: Data,
		to outputURL: URL,
		roiBoxHeadChunk chunk: NativeModelROIBoxHeadChunkEmission,
		parityEvidence: NativeModelParityEvidence = .unevidenced
	) throws -> NativeModelEmissionArtifactSet {
		guard chunk.fixedBatchSize > 0 else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "the chunk's fixed batch size must be positive, got \(chunk.fixedBatchSize)"
			)
		}
		guard chunk.proposalCount > 0 else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "the chunk's proposal count must be positive, got \(chunk.proposalCount)"
			)
		}
		// A batch larger than the whole proposal set describes a loop whose single invocation is asked for
		// proposals that do not exist.
		guard chunk.fixedBatchSize <= chunk.proposalCount else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "the chunk's fixed batch size \(chunk.fixedBatchSize) exceeds the \(chunk.proposalCount) proposals it batches"
			)
		}
		// The manifest is an instruction to the runtime: send `fixedBatchSize` proposals per invocation.
		// Nothing else ties that number to the model it is written beside, so a chunk graph declaring a
		// different batch extent would ship a manifest Core ML refuses at input-binding time.
		//
		// "At least one input" rather than "every input", because the two are different shapes and only
		// one of them is this graph: the ROI and level-weight inputs are batched per proposal, while the
		// four FPN feature maps are shared across the whole batch and declare a leading extent of 1.
		// Demanding the batch everywhere would reject the very model this overload exists to emit. But
		// `contains` alone would also accept a stray input declaring some third extent, so anything that
		// is neither the batch nor the shared 1 is refused by name.
		let declaredBatchExtents = chunk.graph.inputs.compactMap(\.shape.first)
		guard declaredBatchExtents.contains(chunk.fixedBatchSize) else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "the manifest would ask the runtime for batches of \(chunk.fixedBatchSize), but no chunk input declares that leading extent (declared: \(declaredBatchExtents))"
			)
		}
		let unbatchable = declaredBatchExtents.filter { $0 != chunk.fixedBatchSize && $0 != 1 }
		guard unbatchable.isEmpty else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "every chunk input must be batched at \(chunk.fixedBatchSize) or shared at 1, but \(unbatchable) is neither"
			)
		}
		// Resolved before anything is written: a name the runtime could not resolve beside the primary
		// must never reach a shipped manifest.
		let companionFilename = try Self.companionFilename(for: .roiBoxHeadChunk, besidePrimaryAt: outputURL)
		let companionURL = outputURL.deletingLastPathComponent().appendingPathComponent(companionFilename)

		// The companion's bytes come first because the primary's manifest records their digest; the
		// primary therefore cannot be built until the companion is final. Its metadata is its own —
		// the primary's would state the wrong interface, graph and weights digest for this file — and
		// it is emitted as a plain neural network, not through the detector overload, which would wrap
		// it in the network + suppression pipeline it is not.
		let companionInterface = try resolveEmissionInterface(
			graph: chunk.graph,
			classifierLabels: nil,
			imagePreprocessing: nil,
			detection: nil,
			detectionTarget: nil,
			targetSemanticsIntent: nil
		)
		let companionMetadata = try onnxTargetMetadata(
			source: nil,
			sourceProvenance: nil,
			graph: chunk.graph,
			emittedWeights: chunk.weights,
			interface: companionInterface,
			parityEvidence: parityEvidence
		)
		let companionModel = try modelData(
			graph: chunk.graph,
			weights: chunk.weights,
			context: EmissionContext(
				metadata: companionMetadata,
				interface: companionInterface,
				progress: nil,
				cancellationCheck: nil
			)
		)
		let companionSHA256 = NativeModelConversionChecksums.sha256Hex(of: companionModel)

		let manifest = NativeModelArtifactManifest(companions: [
			NativeModelArtifactManifest.Companion(
				role: .roiBoxHeadChunk,
				filename: companionFilename,
				sha256: companionSHA256,
				fixedBatchSize: chunk.fixedBatchSize,
				proposalCount: chunk.proposalCount,
				invocationCount: chunk.invocationCount
			)
		])
		let primaryInterface = try resolveEmissionInterface(
			graph: graph,
			classifierLabels: nil,
			imagePreprocessing: nil,
			detection: nil,
			detectionTarget: nil,
			targetSemanticsIntent: nil
		)
		// The manifest rides in the primary's target metadata, which makeModel attaches to the model's
		// outer description — the only description `MLModelDescription` publishes.
		let primaryMetadata = try metadata(
			onnxTargetMetadata(
				source: nil,
				sourceProvenance: nil,
				graph: graph,
				emittedWeights: weights,
				interface: primaryInterface,
				parityEvidence: parityEvidence
			),
			addingUserDefined: NativeModelArtifactManifest.userDefinedKey,
			value: manifest.canonicalJSON()
		)
		let primaryModel = try modelData(
			graph: graph,
			weights: weights,
			context: EmissionContext(
				metadata: primaryMetadata,
				interface: primaryInterface,
				progress: nil,
				cancellationCheck: nil
			)
		)

		try companionModel.write(to: companionURL, options: .atomic)
		do {
			try primaryModel.write(to: outputURL, options: .atomic)
		} catch {
			// The companion was published for a primary that never arrived. Take it back rather than
			// leave a file nothing names: on a fresh directory this restores the pre-emission state
			// exactly. It cannot do so when an *existing* pair was being replaced — the old companion's
			// bytes are already gone — which is why the emission is documented as non-atomic against a
			// live pair, and why a consumer is expected to verify the manifest digest rather than trust
			// the file beside it. Best effort by construction: the write failed, so the filesystem is
			// already misbehaving, and a failure to clean up must not replace the error that explains it.
			try? FileManager.default.removeItem(at: companionURL)
			throw error
		}

		// Byte counts come from the same buffers the digests cover, so a reported size can never
		// describe different bytes than the reported hash.
		return NativeModelEmissionArtifactSet(
			primary: NativeModelEmittedArtifact(
				role: .primary,
				url: outputURL,
				byteCount: UInt64(primaryModel.count),
				sha256: NativeModelConversionChecksums.sha256Hex(of: primaryModel)
			),
			companions: [
				NativeModelEmittedArtifact(
					role: .roiBoxHeadChunk,
					url: companionURL,
					byteCount: UInt64(companionModel.count),
					sha256: companionSHA256
				)
			]
		)
	}

	/// The plain basename a companion takes beside the primary model: `converted.mlmodel` yields
	/// `converted.roi-box-head-chunk.mlmodel`, following the `<model-name>.metadata.json` sidecar
	/// convention. The `.mlmodel` extension is fixed rather than inherited because Core ML compiles
	/// by extension.
	///
	/// The manifest records a name the runtime resolves *beside* the primary, so anything that is not
	/// a plain basename — a path separator, a leading dot that could read as a traversal component —
	/// is rejected here instead of being written into a shipped model.
	static func companionFilename(
		for role: NativeModelEmittedArtifact.Role,
		besidePrimaryAt primaryURL: URL
	) throws -> String {
		let suffix: String
		switch role {
		case .primary:
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(reason: "the primary model is not a companion of itself")
		case .roiBoxHeadChunk:
			suffix = "roi-box-head-chunk"
		}
		let filename = "\(primaryURL.deletingPathExtension().lastPathComponent).\(suffix).mlmodel"
		guard !filename.contains("/"), !filename.hasPrefix(".") else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "'\(filename)' is not a plain filename that resolves beside the primary model"
			)
		}
		return filename
	}

	/// Returns `metadata` carrying one more `userDefined` entry. Core ML's string map is the only
	/// place a manifest can travel with the model it describes.
	private func metadata(
		_ metadata: NativeModelCoreMLMetadata,
		addingUserDefined key: String,
		value: String
	) -> NativeModelCoreMLMetadata {
		var userDefined = metadata.userDefined
		userDefined[key] = value
		return NativeModelCoreMLMetadata(
			shortDescription: metadata.shortDescription,
			versionString: metadata.versionString,
			author: metadata.author,
			license: metadata.license,
			userDefined: userDefined
		)
	}

	private func emit(
		graph: NativeModelGraph,
		weights: Data,
		to outputURL: URL,
		context: EmissionContext
	) throws {
		let model = try modelData(graph: graph, weights: weights, context: context)
		try context.cancellationCheck?()
		context.progress?(NativeModelConversionProgress(phase: .writingModel))
		try model.write(to: outputURL, options: .atomic)
		context.progress?(NativeModelConversionProgress(phase: .writingModel, completedUnitCount: 1, totalUnitCount: 1))
	}

	private func emitStreamingADAF(
		graph: NativeModelGraph,
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		to outputURL: URL,
		context: EmissionContext
	) throws {
		try context.cancellationCheck?()
		let model = try streamingADAFModelSegments(
			graph: graph,
			promotedWeights: promotedWeights,
			weightsDigest: weightsDigest,
			context: context
		)
		guard let digestOffset = model.firstFileOffset(of: Data(adafWeightsSHA256Placeholder.utf8)) else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: "metadata",
				reason: "the streamed ADAF weights checksum placeholder is missing"
			)
		}
		let operationCount = graph.operations.count
		context.progress?(NativeModelConversionProgress(
			phase: .emittingModel,
			completedUnitCount: 0,
			totalUnitCount: operationCount
		))
		try NativeModelAtomicFilePublisher.writeAtomically(
			to: outputURL,
			writing: { handle in
				try model.write(to: handle, reporting: context.progress)
			},
			beforePublish: { temporaryURL in
				try context.cancellationCheck?()
				let digest = try weightsDigest.sha256(of: temporaryURL, checkingCancellation: context.cancellationCheck)
				let handle = try FileHandle(forWritingTo: temporaryURL)
				defer { try? handle.close() }
				try handle.seek(toOffset: digestOffset)
				try handle.write(contentsOf: Data(digest.utf8))
				try context.cancellationCheck?()
			}
		)
		context.progress?(NativeModelConversionProgress(phase: .writingModel, completedUnitCount: 1, totalUnitCount: 1))
	}

	func streamingADAFModelSegments(
		graph: NativeModelGraph,
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		context: EmissionContext
	) throws -> CoreMLProtobufSegments {
		let validation = NativeModelGraphValidator().validate(graph)
		guard validation.isConvertible else {
			throw NativeModelCoreMLEmissionError.invalidGraph(validation.issues)
		}
		let weightsByName = Dictionary(uniqueKeysWithValues: graph.weights.map { ($0.name, $0) })
		let tensorsByName = tensorIndex(for: graph)
		let outputTensors = try graph.outputs.map { outputName -> NativeModelTensor in
			guard let tensor = tensorsByName[outputName] else {
				throw NativeModelCoreMLEmissionError.missingOutputTensor(outputName)
			}
			return tensor
		}
		guard let detection = context.interface.detection, context.interface.classifier == nil else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "the streamed emitter is reserved for the ADAF detector pipeline"
			)
		}
		try validate(detection: detection, against: outputTensors)
		let usesLegacyShapeMapping = requiresLegacyRank5ShapeMapping(graph.operations)
		let imagePlan = context.interface.imagePlan
		let layers = try streamingNetworkLayers(
			operations: graph.operations,
			weightsByName: weightsByName,
			promotedWeights: promotedWeights,
			weightsDigest: weightsDigest,
			imagePlan: imagePlan,
			usesLegacyShapeMapping: usesLegacyShapeMapping,
			cancellationCheck: context.cancellationCheck
		)

		let inputFeatures = CoreMLProtobufEncoder.message { features in
			for input in graph.inputs {
				if let imagePlan, input.name == imagePlan.networkInputName {
					CoreMLProtobufEncoder.appendMessageField(1, value: imageFeatureDescription(for: imagePlan), to: &features)
				} else {
					CoreMLProtobufEncoder.appendMessageField(1, value: featureDescription(
						for: legacyMappedFeature(input, usesLegacyShapeMapping: usesLegacyShapeMapping)
					), to: &features)
				}
			}
		}
		let description = CoreMLProtobufEncoder.message { description in
			description.append(inputFeatures)
			CoreMLProtobufEncoder.appendMessageField(10, value: NativeModelDetectorPipelineBuilder.fixedDetectionFeature(
				named: detection.coordinatesBlobName, rows: detection.boxCount, columns: 4
			), to: &description)
			CoreMLProtobufEncoder.appendMessageField(10, value: NativeModelDetectorPipelineBuilder.fixedDetectionFeature(
				named: detection.confidenceBlobName, rows: detection.boxCount, columns: detection.labels.count
			), to: &description)
			// A detector pipeline owns its metadata on the outer description. Adding it to this
			// inner network stage would change the established serialized artifact and publish
			// duplicate provenance to Core ML.
		}
		var network = CoreMLProtobufSegments()
		network.append(contentsOf: layers)
		var networkTail = Data()
		if !usesLegacyShapeMapping {
			CoreMLProtobufEncoder.appendVarintField(5, value: 1, to: &networkTail)
			if imagePlan != nil {
				CoreMLProtobufEncoder.appendVarintField(6, value: 1, to: &networkTail)
			}
		}
		network.append(data: networkTail)

		let specificationVersion = (graph.inputs + outputTensors).contains { $0.dataType == .float16 } ? 7 : 4
		var networkModel = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendVarintField(1, value: UInt64(specificationVersion), to: &networkModel)
		appendStaticMessageField(2, value: description, to: &networkModel)
		CoreMLProtobufStreamingEncoder.appendMessageField(500, value: network, to: &networkModel)

		let pipelineDescription = CoreMLProtobufEncoder.message { pipelineDescription in
			pipelineDescription.append(inputFeatures)
			if detection.suppressionOwnership == .pipeline {
				CoreMLProtobufEncoder.appendMessageField(1, value: NativeModelDetectorPipelineBuilder.doubleFeature(
					named: NativeModelDetectionInterface.iouThresholdInputName, isOptional: true
				), to: &pipelineDescription)
				CoreMLProtobufEncoder.appendMessageField(1, value: NativeModelDetectorPipelineBuilder.doubleFeature(
					named: NativeModelDetectionInterface.confidenceThresholdInputName, isOptional: true
				), to: &pipelineDescription)
			}
			for output in NativeModelDetectorPipelineBuilder.suppressedOutputFeatures(for: detection) {
				CoreMLProtobufEncoder.appendMessageField(10, value: output, to: &pipelineDescription)
			}
			if let metadata = context.metadata {
				CoreMLProtobufEncoder.appendMessageField(100, value: coreMLMetadataMessage(for: metadata), to: &pipelineDescription)
			}
		}
		var pipeline = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendMessageField(1, value: networkModel, to: &pipeline)
		appendStaticMessageField(1, value: NativeModelDetectorPipelineBuilder.nonMaximumSuppressionModel(for: detection), to: &pipeline)
		var outerModel = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendVarintField(1, value: UInt64(specificationVersion), to: &outerModel)
		appendStaticMessageField(2, value: pipelineDescription, to: &outerModel)
		CoreMLProtobufStreamingEncoder.appendMessageField(NativeModelDetectorPipelineBuilder.pipelineModelField, value: pipeline, to: &outerModel)
		outerModel.append(progress: NativeModelConversionProgress(phase: .writingModel))
		return outerModel
	}

	private func appendStaticMessageField(
		_ fieldNumber: Int,
		value: Data,
		to segments: inout CoreMLProtobufSegments
	) {
		var message = CoreMLProtobufSegments()
		message.append(data: value)
		CoreMLProtobufStreamingEncoder.appendMessageField(fieldNumber, value: message, to: &segments)
	}

	func streamingNetworkLayers(
		operations: [NativeModelOperation],
		weightsByName: [String: NativeModelWeight],
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		imagePlan: ImageInputPlan?,
		usesLegacyShapeMapping: Bool,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		var layers = CoreMLProtobufSegments()
		if let imagePlan {
			appendStaticMessageField(1, value: imagePreprocessingLayer(for: imagePlan), to: &layers)
		}
		for (index, operation) in operations.enumerated() {
			try cancellationCheck?()
			var layer = try streamingLayer(
				for: operation,
				weightsByName: weightsByName,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				usesLegacyShapeMapping: usesLegacyShapeMapping,
				cancellationCheck: cancellationCheck
			)
			layer.append(progress: NativeModelConversionProgress(
				phase: .emittingModel,
				completedUnitCount: index + 1,
				totalUnitCount: operations.count,
				operationName: operation.name
			))
			CoreMLProtobufStreamingEncoder.appendMessageField(1, value: layer, to: &layers)
		}
		return layers
	}

	private func streamingLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		usesLegacyShapeMapping: Bool,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		switch operation.kind {
		case .convolution2D:
			return try streamingConvolutionLayer(
				for: operation,
				weightsByName: weightsByName,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				cancellationCheck: cancellationCheck
			)
		case .batchNormalization:
			return try streamingBatchNormalizationLayer(
				for: operation,
				weightsByName: weightsByName,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				cancellationCheck: cancellationCheck
			)
		case .linear:
			return try streamingLinearLayer(
				for: operation,
				weightsByName: weightsByName,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				cancellationCheck: cancellationCheck
			)
		case .constant:
			return try streamingConstantLayer(
				for: operation,
				weightsByName: weightsByName,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				isExactRank: false,
				cancellationCheck: cancellationCheck
			)
		case .constantND:
			return try streamingConstantLayer(
				for: operation,
				weightsByName: weightsByName,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				isExactRank: true,
				cancellationCheck: cancellationCheck
			)
		default:
			var staticLayer = CoreMLProtobufSegments()
			staticLayer.append(data: try layer(
				for: operation,
				weightsByName: weightsByName,
				weights: Data(),
				usesLegacyShapeMapping: usesLegacyShapeMapping
			))
			return staticLayer
		}
	}

	func streamingConvolutionLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		guard operation.inputs.count == 2 || operation.inputs.count == 3 else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "expected an activation input, kernel weight, and optional bias"
			)
		}
		let kernel = try weight(named: operation.inputs[1], in: weightsByName)
		guard kernel.shape.count == 4 else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "kernel '\(kernel.name)' must have [outputChannels, kernelChannels, height, width] shape"
			)
		}
		let kernelSize = try integerArrayAttribute("kernelSize", for: operation, count: 2)
		let strides = try integerArrayAttribute("strides", for: operation, count: 2)
		let padding = try paddingAttribute(for: operation)
		let dilations = try integerArrayAttribute("dilations", for: operation, count: 2)
		let groups = try integerAttribute("groups", for: operation)
		guard kernel.shape[2] == kernelSize[0], kernel.shape[3] == kernelSize[1],
			kernelSize.allSatisfy({ $0 > 0 }), strides.allSatisfy({ $0 > 0 }),
			dilations.allSatisfy({ $0 > 0 }), groups > 0
		else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "kernel shape, kernelSize, and groups are inconsistent"
			)
		}
		let bias = try operation.inputs.dropFirst(2).first.map { try weight(named: $0, in: weightsByName) }
		if let bias, bias.shape != [kernel.shape[0]] {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "bias '\(bias.name)' must contain one value per output channel"
			)
		}
		var convolution = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendVarintField(1, value: UInt64(kernel.shape[0]), to: &convolution)
		CoreMLProtobufStreamingEncoder.appendVarintField(2, value: UInt64(kernel.shape[1]), to: &convolution)
		CoreMLProtobufStreamingEncoder.appendVarintField(10, value: UInt64(groups), to: &convolution)
		for dimension in kernelSize {
			CoreMLProtobufStreamingEncoder.appendVarintField(20, value: UInt64(dimension), to: &convolution)
		}
		for stride in strides {
			CoreMLProtobufStreamingEncoder.appendVarintField(30, value: UInt64(stride), to: &convolution)
		}
		for dilation in dilations {
			CoreMLProtobufStreamingEncoder.appendVarintField(40, value: UInt64(dilation), to: &convolution)
		}
		appendStaticMessageField(50, value: validPadding(padding), to: &convolution)
		if let bias {
			CoreMLProtobufStreamingEncoder.appendVarintField(70, value: 1, to: &convolution)
			CoreMLProtobufStreamingEncoder.appendMessageField(
				91,
				value: try streamingWeightParameters(
					for: bias,
					promotedWeights: promotedWeights,
					weightsDigest: weightsDigest,
					cancellationCheck: cancellationCheck
				),
				to: &convolution
			)
		}
		CoreMLProtobufStreamingEncoder.appendMessageField(
			90,
			value: try streamingWeightParameters(
				for: kernel,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				cancellationCheck: cancellationCheck
			),
			to: &convolution
		)
		return streamingLayerEnvelope(
			name: operation.name,
			inputs: [operation.inputs[0]],
			outputs: operation.outputs,
			parameterField: 100,
			parameters: convolution
		)
	}

	private func streamingBatchNormalizationLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		guard operation.inputs.count == 5 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "batchNorm requires an activation input followed by scale, bias, mean, and variance weights"
			)
		}
		let gamma = try weight(named: operation.inputs[1], in: weightsByName)
		let beta = try weight(named: operation.inputs[2], in: weightsByName)
		let mean = try weight(named: operation.inputs[3], in: weightsByName)
		let variance = try weight(named: operation.inputs[4], in: weightsByName)
		guard gamma.shape.count == 1, beta.shape == gamma.shape, mean.shape == gamma.shape, variance.shape == gamma.shape else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "batchNorm scale, bias, mean, and variance must be equal-length vectors"
			)
		}
		guard let epsilon = operation.attributes["epsilon"]?.floatingPointValue, epsilon >= 0 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(operation: operation.name, reason: "batchNorm epsilon must be a non-negative floating-point value")
		}
		var batchNorm = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendVarintField(1, value: UInt64(gamma.shape[0]), to: &batchNorm)
		CoreMLProtobufStreamingEncoder.appendFloatField(10, value: Float(epsilon), to: &batchNorm)
		for (field, weight) in [(15, gamma), (16, beta), (17, mean), (18, variance)] {
			CoreMLProtobufStreamingEncoder.appendMessageField(
				field,
				value: try streamingWeightParameters(
					for: weight,
					promotedWeights: promotedWeights,
					weightsDigest: weightsDigest,
					cancellationCheck: cancellationCheck
				),
				to: &batchNorm
			)
		}
		return streamingLayerEnvelope(
			name: operation.name,
			inputs: [operation.inputs[0]],
			outputs: operation.outputs,
			parameterField: 160,
			parameters: batchNorm
		)
	}

	private func streamingLinearLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		guard operation.inputs.count == 2 || operation.inputs.count == 3 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "linear requires an activation input, weight matrix, and optional bias"
			)
		}
		let matrix = try weight(named: operation.inputs[1], in: weightsByName)
		guard matrix.shape.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "linear weight '\(matrix.name)' must have [outputChannels, inputChannels] shape"
			)
		}
		let bias = try operation.inputs.dropFirst(2).first.map { try weight(named: $0, in: weightsByName) }
		if let bias, bias.shape != [matrix.shape[0]] {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "linear bias '\(bias.name)' must contain one value per output channel"
			)
		}
		var innerProduct = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendVarintField(1, value: UInt64(matrix.shape[1]), to: &innerProduct)
		CoreMLProtobufStreamingEncoder.appendVarintField(2, value: UInt64(matrix.shape[0]), to: &innerProduct)
		if let bias {
			CoreMLProtobufStreamingEncoder.appendVarintField(10, value: 1, to: &innerProduct)
			CoreMLProtobufStreamingEncoder.appendMessageField(
				21,
				value: try streamingWeightParameters(
					for: bias,
					promotedWeights: promotedWeights,
					weightsDigest: weightsDigest,
					cancellationCheck: cancellationCheck
				),
				to: &innerProduct
			)
		}
		CoreMLProtobufStreamingEncoder.appendMessageField(
			20,
			value: try streamingWeightParameters(
				for: matrix,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				cancellationCheck: cancellationCheck
			),
			to: &innerProduct
		)
		return streamingLayerEnvelope(
			name: operation.name,
			inputs: [operation.inputs[0]],
			outputs: operation.outputs,
			parameterField: 140,
			parameters: innerProduct
		)
	}

	func streamingConstantLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		isExactRank: Bool,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		guard operation.inputs.count == 1 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "\(isExactRank ? "constantND" : "constant") takes exactly one input naming the weight that holds its values"
			)
		}
		let constant = try weight(named: operation.inputs[0], in: weightsByName)
		let shape: [Int]
		if isExactRank {
			guard !constant.shape.isEmpty, constant.shape.allSatisfy({ $0 > 0 }) else {
				throw NativeModelCoreMLEmissionError.invalidOperation(
					operation: operation.name,
					reason: "constantND '\(constant.name)' must have a non-empty positive shape"
				)
			}
			shape = constant.shape
		} else {
			shape = constant.shape.count == 4 && constant.shape[0] == 1 ? Array(constant.shape.dropFirst()) : constant.shape
			guard shape.count == 3 else {
				throw NativeModelCoreMLEmissionError.invalidOperation(
					operation: operation.name,
					reason: "constant '\(constant.name)' must have a [channels, height, width] shape, got \(constant.shape)"
				)
			}
		}
		var parameters = CoreMLProtobufSegments()
		var shapeData = Data()
		CoreMLProtobufEncoder.appendPackedVarintField(1, values: shape.map(UInt64.init), to: &shapeData)
		parameters.append(data: shapeData)
		CoreMLProtobufStreamingEncoder.appendMessageField(
			2,
			value: try streamingWeightParameters(
				for: constant,
				promotedWeights: promotedWeights,
				weightsDigest: weightsDigest,
				cancellationCheck: cancellationCheck
			),
			to: &parameters
		)
		return streamingLayerEnvelope(
			name: operation.name,
			inputs: [],
			outputs: operation.outputs,
			parameterField: isExactRank ? 1070 : 290,
			parameters: parameters
		)
	}

	private func streamingWeightParameters(
		for weight: NativeModelWeight,
		promotedWeights: NativeModelADAFPromotedWeights,
		weightsDigest: NativeModelADAFPromotedWeightsDigest,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufSegments {
		guard weight.dataType == .float32 else {
			preconditionFailure("ADAF promoted weights must be Float32 before protobuf emission.")
		}
		var parameters = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendDeferredPayloadField(
			1,
			payload: try promotedWeights.payload(
				for: weight,
				checkingCancellation: cancellationCheck,
				digest: weightsDigest
			),
			to: &parameters
		)
		return parameters
	}

	private func streamingLayerEnvelope(
		name: String,
		inputs: [String],
		outputs: [NativeModelTensor],
		parameterField: Int,
		parameters: CoreMLProtobufSegments
	) -> CoreMLProtobufSegments {
		var layer = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendStringField(1, value: name, to: &layer)
		for input in inputs {
			CoreMLProtobufStreamingEncoder.appendStringField(2, value: input, to: &layer)
		}
		for output in outputs {
			CoreMLProtobufStreamingEncoder.appendStringField(3, value: output.name, to: &layer)
		}
		CoreMLProtobufStreamingEncoder.appendMessageField(parameterField, value: parameters, to: &layer)
		return layer
	}

	/// Validates the graph against the emitter's contract and serializes it, without touching disk.
	///
	/// Separated from writing so a multi-artifact emission can build every file's bytes — and hash
	/// them — before any of them is published.
	private func modelData(
		graph: NativeModelGraph,
		weights: Data,
		context: EmissionContext
	) throws -> Data {
		try context.cancellationCheck?()
		let validation = NativeModelGraphValidator().validate(graph)
		guard validation.isConvertible else {
			throw NativeModelCoreMLEmissionError.invalidGraph(validation.issues)
		}

		let weightsByName = Dictionary(uniqueKeysWithValues: graph.weights.map { ($0.name, $0) })
		for weight in graph.weights {
			let (endOffset, overflow) = weight.offset.addingReportingOverflow(weight.byteCount)
			guard !overflow, endOffset <= UInt64(weights.count) else {
				throw NativeModelCoreMLEmissionError.weightDataOutOfBounds(
					name: weight.name,
					offset: weight.offset,
					byteCount: weight.byteCount,
					availableByteCount: UInt64(weights.count)
				)
			}
		}

		let tensorsByName = tensorIndex(for: graph)
		let outputTensors = try graph.outputs.map { outputName in
			guard let tensor = tensorsByName[outputName] else {
				throw NativeModelCoreMLEmissionError.missingOutputTensor(outputName)
			}
			return tensor
		}

		return try makeModel(
			input: ModelBuildInput(
				inputTensors: graph.inputs,
				outputTensors: outputTensors,
				operations: graph.operations,
				weightsByName: weightsByName,
				weights: weights
			),
			context: context
		)
	}

	private func tensorIndex(for graph: NativeModelGraph) -> [String: NativeModelTensor] {
		var result = Dictionary(uniqueKeysWithValues: graph.inputs.map { ($0.name, $0) })
		for operation in graph.operations {
			for output in operation.outputs {
				result[output.name] = output
			}
		}
		return result
	}

	private func outputFileByteCount(at url: URL) throws -> UInt64 {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
			throw NativeModelCoreMLEmissionError.outputFileSizeUnavailable(url.lastPathComponent)
		}
		return size
	}

	/// Resolves the interface once, before both target metadata and protobuf layers are produced.
	/// A target-semantics intent is advisory until this function proves it matches an interface that
	/// will really be emitted.
	func resolveEmissionInterface(
		graph: NativeModelGraph,
		classifierLabels: [String]?,
		imagePreprocessing: NativeModelImagePreprocessing?,
		detection: NativeModelDetectionInterface?,
		detectionTarget: NativeModelDetectionTargetInfo?,
		targetSemanticsIntent: NativeModelTargetSemanticsIntent?
	) throws -> ResolvedEmissionInterface {
		let tensors = tensorIndex(for: graph)
		let outputs = graph.outputs.compactMap { tensors[$0] }
		let classifier = detection == nil
			? classifierPlan(outputs: outputs, operations: graph.operations, labels: classifierLabels)
			: nil
		let imagePlan = imageInputPlan(
			inputTensors: graph.inputs,
			declaresImageInterface: classifier != nil || detection != nil,
			preprocessing: imagePreprocessing
		)

		let task: NativeModelTargetSemantics.Task?
		let classCount: Int?
		if let detection {
			guard let detectionTarget else {
				throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
					reason: "a detector target requires matching target metadata"
				)
			}
			guard detectionTarget.classCount == detection.labels.count else {
				throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
					reason: "detection target class count \(detectionTarget.classCount) does not match \(detection.labels.count) labels"
				)
			}
			if let targetSemanticsIntent,
				targetSemanticsIntent.labelProfile.provenance != Self.semanticsProvenance(of: detectionTarget.labelProvenance) {
				throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
					reason: "target semantics label provenance does not match the detection target"
				)
			}
			task = .detection
			classCount = detection.labels.count
		} else if let classifier {
			task = .classification
			classCount = classifier.labels.count
		} else {
			task = nil
			classCount = nil
		}

		let targetSemantics: NativeModelTargetSemantics?
		if let targetSemanticsIntent, let task, let classCount {
			targetSemantics = targetSemanticsIntent.resolved(
				task: task,
				classCount: classCount,
				imagePreprocessingWasApplied: imagePlan != nil
			)
		} else {
			targetSemantics = nil
		}

		return ResolvedEmissionInterface(
			classifier: classifier,
			imagePlan: imagePlan,
			detection: detection,
			detectionTarget: detectionTarget,
			targetSemantics: targetSemantics
		)
	}

	/// Explicit bridge between the detector catalog's provenance and the target-semantics one. The
	/// two enums align by name today, but a rawValue comparison would silently change behavior if
	/// either side ever diverged.
	private static func semanticsProvenance(
		of provenance: NativeModelDetectorCatalog.DetectorLabelProvenance
	) -> NativeModelTargetSemantics.LabelProvenance {
		switch provenance {
		case .metadata: .metadata
		case .convention: .convention
		case .unnamed: .unnamed
		}
	}

	private func makeModel(
		input: ModelBuildInput,
		context: EmissionContext
	) throws -> Data {
		let inputTensors = input.inputTensors
		let outputTensors = input.outputTensors
		let operations = input.operations
		let metadata = context.metadata
		let progress = context.progress
		let cancellationCheck = context.cancellationCheck
		let specificationVersion = (inputTensors + outputTensors).contains { $0.dataType == .float16 } ? 7 : 4
		let classifier = context.interface.classifier
		let imagePlan = context.interface.imagePlan

		// Computed before the layers are written: softmax emission depends on which shape mapping the
		// finished network will declare (see softmaxLayer).
		let usesLegacyShapeMapping = requiresLegacyRank5ShapeMapping(operations)

		let layers = try networkLayers(
			input: input,
			imagePlan: imagePlan,
			classifier: classifier,
			usesLegacyShapeMapping: usesLegacyShapeMapping,
			progress: progress,
			cancellationCheck: cancellationCheck
		)

		let detection = context.interface.detection
		if let detection {
			try validate(detection: detection, against: outputTensors)
		}

		let inputFeatures = CoreMLProtobufEncoder.message { features in
			for input in inputTensors {
				if let imagePlan, input.name == imagePlan.networkInputName {
					CoreMLProtobufEncoder.appendMessageField(1, value: imageFeatureDescription(for: imagePlan), to: &features)
				} else {
					CoreMLProtobufEncoder.appendMessageField(1, value: featureDescription(
						for: legacyMappedFeature(input, usesLegacyShapeMapping: usesLegacyShapeMapping)
					), to: &features)
				}
			}
		}

		let description = CoreMLProtobufEncoder.message { description in
			description.append(inputFeatures)
			if let detection {
				// Stage one publishes the raw boxes and scores that the suppression stage consumes.
				CoreMLProtobufEncoder.appendMessageField(10, value: NativeModelDetectorPipelineBuilder.fixedDetectionFeature(
					named: detection.coordinatesBlobName, rows: detection.boxCount, columns: 4
				), to: &description)
				CoreMLProtobufEncoder.appendMessageField(10, value: NativeModelDetectorPipelineBuilder.fixedDetectionFeature(
					named: detection.confidenceBlobName, rows: detection.boxCount, columns: detection.labels.count
				), to: &description)
			} else if let classifier {
				CoreMLProtobufEncoder.appendMessageField(10, value: stringFeatureDescription(named: classifier.classLabelName), to: &description)
				CoreMLProtobufEncoder.appendMessageField(10, value: probabilitiesFeatureDescription(named: classifier.classLabelProbsName), to: &description)
				CoreMLProtobufEncoder.appendStringField(11, value: classifier.classLabelName, to: &description)
				CoreMLProtobufEncoder.appendStringField(12, value: classifier.classLabelProbsName, to: &description)
			} else {
				for output in outputTensors {
					CoreMLProtobufEncoder.appendMessageField(10, value: featureDescription(
						for: legacyMappedFeature(output, usesLegacyShapeMapping: usesLegacyShapeMapping)
					), to: &description)
				}
			}
			// A pipeline carries the model metadata on its outer description, not on stage one.
			if let metadata, detection == nil {
				CoreMLProtobufEncoder.appendMessageField(100, value: coreMLMetadataMessage(for: metadata), to: &description)
			}
		}

		if usesLegacyShapeMapping, classifier != nil {
			// Never silently flip a classifier to the legacy mapping: under it the image enters as
			// [1, 1, C, H, W] and an in-graph class-axis softmax normalizes the size-1 batch
			// dimension instead, returning an all-ones vector. That produced a converted model
			// predicting one label at probability 1.0.
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: "classifier",
				reason: "reshape/transpose need Core ML's rank-5 layout, which is incompatible with a classifier interface"
			)
		}

		let network = CoreMLProtobufEncoder.message { network in
			network.append(layers)
			// Core ML's classic Reshape and Permute layers operate on the rank-5 [sequence, batch,
			// channel, height, width] layout and reject rank-4 input outright, so a graph using them
			// must keep the legacy mapping — which is what Apple's own detector exports do. Every
			// other graph declares EXACT_ARRAY_MAPPING/RANK4_IMAGE_MAPPING so the axes the reader
			// computed survive into Core ML unchanged.
			if !usesLegacyShapeMapping {
				CoreMLProtobufEncoder.appendVarintField(5, value: 1, to: &network)
				if imagePlan != nil {
					CoreMLProtobufEncoder.appendVarintField(6, value: 1, to: &network)
				}
			}
			if let classifier {
				CoreMLProtobufEncoder.appendMessageField(100, value: stringVector(classifier.labels), to: &network)
				CoreMLProtobufEncoder.appendStringField(200, value: classifier.probabilitiesBlobName, to: &network)
			}
		}

		let networkModel = CoreMLProtobufEncoder.message { model in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(specificationVersion), to: &model)
			CoreMLProtobufEncoder.appendMessageField(2, value: description, to: &model)
			CoreMLProtobufEncoder.appendMessageField(classifier == nil ? 500 : 403, value: network, to: &model)
		}
		guard let detection else { return networkModel }

		// The detector is the network followed by the NMS model Vision requires. Most detectors own
		// their policy in that stage and expose its two threshold inputs. Faster R-CNN already emits
		// its complete two-pass policy as NN layers, so its final model is an interface adapter only;
		// publishing threshold inputs there would silently add a third policy pass.
		let pipelineDescription = CoreMLProtobufEncoder.message { pipelineDescription in
			pipelineDescription.append(inputFeatures)
			if detection.suppressionOwnership == .pipeline {
				CoreMLProtobufEncoder.appendMessageField(1, value: NativeModelDetectorPipelineBuilder.doubleFeature(
					named: NativeModelDetectionInterface.iouThresholdInputName, isOptional: true
				), to: &pipelineDescription)
				CoreMLProtobufEncoder.appendMessageField(1, value: NativeModelDetectorPipelineBuilder.doubleFeature(
					named: NativeModelDetectionInterface.confidenceThresholdInputName, isOptional: true
				), to: &pipelineDescription)
			}
			for output in NativeModelDetectorPipelineBuilder.suppressedOutputFeatures(for: detection) {
				CoreMLProtobufEncoder.appendMessageField(10, value: output, to: &pipelineDescription)
			}
			if let metadata {
				CoreMLProtobufEncoder.appendMessageField(100, value: coreMLMetadataMessage(for: metadata), to: &pipelineDescription)
			}
		}
		return NativeModelDetectorPipelineBuilder.pipelineModel(
			specificationVersion: specificationVersion,
			description: pipelineDescription,
			stages: [networkModel, NativeModelDetectorPipelineBuilder.nonMaximumSuppressionModel(for: detection)]
		)
	}

	/// Under the legacy rank-5 mapping, Core ML's validator only accepts rank-1 or rank-3 multi-array
	/// feature declarations — a rank-4 `[1, C, H, W]` input is rejected outright ("must have dimension
	/// 1 (vector) or 3 (image-like arrays)"). The reader's unit batch axis carries no information, so
	/// it is dropped from the *declared* feature (`[1, C, H, W]` → `[C, H, W]`); the graph and its
	/// blobs are untouched. Rank-3 declarations then also match what the runtime actually returns for
	/// outputs (the blob's `[C, H, W]`), instead of mismatching a declared rank-4 shape.
	private func legacyMappedFeature(_ tensor: NativeModelTensor, usesLegacyShapeMapping: Bool) -> NativeModelTensor {
		guard usesLegacyShapeMapping, tensor.shape.count == 4, tensor.shape[0] == 1 else { return tensor }
		return NativeModelTensor(name: tensor.name, dataType: tensor.dataType, shape: Array(tensor.shape.dropFirst()))
	}

	/// Whether the graph contains a layer Core ML only implements against its legacy rank-5 blob
	/// layout. Reshape and Permute are the two the detection decode needs; both refuse rank-4 input.
	private func requiresLegacyRank5ShapeMapping(_ operations: [NativeModelOperation]) -> Bool {
		operations.contains { $0.kind == .reshape || $0.kind == .transpose }
	}

	/// Encodes the network's layer sequence: the optional image normalization, every graph
	/// operation, and the classifier interface's trailing flatten/softmax.
	private func networkLayers(
		input: ModelBuildInput,
		imagePlan: ImageInputPlan?,
		classifier: ClassifierPlan?,
		usesLegacyShapeMapping: Bool,
		progress: NativeModelConversionProgressHandler?,
		cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> Data {
		let operations = input.operations
		var layers = Data()
		// A normalization layer must run before the graph so it produces the blob the first operation
		// consumes (the graph's original input name).
		if let imagePlan {
			CoreMLProtobufEncoder.appendMessageField(1, value: imagePreprocessingLayer(for: imagePlan), to: &layers)
		}
		progress?(NativeModelConversionProgress(
			phase: .emittingModel,
			completedUnitCount: 0,
			totalUnitCount: operations.count
		))
		for (index, operation) in operations.enumerated() {
			try cancellationCheck?()
			let layer = try layer(
				for: operation, weightsByName: input.weightsByName, weights: input.weights,
				usesLegacyShapeMapping: usesLegacyShapeMapping
			)
			CoreMLProtobufEncoder.appendMessageField(1, value: layer, to: &layers)
			progress?(NativeModelConversionProgress(
				phase: .emittingModel,
				completedUnitCount: index + 1,
				totalUnitCount: operations.count,
				operationName: operation.name
			))
		}
		// The classifier interface flattens the class scores to a plain `[1, N]` vector when needed
		// (Core ML expects the probability blob to be vector-shaped) and appends one softmax so the
		// reported probabilities are normalized — unless the graph already ended in a class-axis
		// softmax, whose probabilities another softmax would squash. It then exposes
		// classLabel/classLabelProbs instead of the raw multi-array output.
		guard let classifier else { return layers }
		if let flattened = classifier.flattenedBlobName {
			CoreMLProtobufEncoder.appendMessageField(1, value: flattenTo2DLayer(
				name: "classifier_flatten",
				input: classifier.logitsBlobName,
				output: flattened
			), to: &layers)
		}
		if classifier.appendsSoftmax {
			CoreMLProtobufEncoder.appendMessageField(1, value: softmaxNDLayer(
				name: "classifier_softmax",
				input: classifier.softmaxInputBlobName,
				output: classifier.probabilitiesBlobName,
				axis: 1
			), to: &layers)
		}
		return layers
	}

	/// Checks that the graph actually produces the two tensors the detection interface promises, in
	/// the row/column order Core ML's suppression stage reads them.
	///
	/// Core ML pads detection tensors with unit axes (the decode's final permute yields
	/// `[1, boxes, columns, 1]`), so unit dimensions are ignored and only the significant extents are
	/// compared. Emitting a transposed or mis-sized tensor here would still compile and then hand
	/// every box the wrong score, so this is a hard error rather than a fallback.
	private func validate(detection: NativeModelDetectionInterface, against outputs: [NativeModelTensor]) throws {
		guard !detection.labels.isEmpty else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(reason: "a detector requires at least one class label")
		}
		guard detection.boxCount > 0 else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(reason: "boxCount must be positive")
		}
		guard detection.coordinatesBlobName != detection.confidenceBlobName else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "coordinates and confidence must be different graph outputs"
			)
		}
		// The thresholds are encoded verbatim as protobuf doubles; out-of-range values would compile
		// and then suppress everything or nothing.
		guard detection.iouThreshold.isFinite, (0 ... 1).contains(detection.iouThreshold) else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "iouThreshold must be a finite value in 0...1, got \(detection.iouThreshold)"
			)
		}
		guard detection.confidenceThreshold.isFinite, detection.confidenceThreshold >= 0 else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "confidenceThreshold must be finite and non-negative, got \(detection.confidenceThreshold)"
			)
		}
		try requireDetectionOutput(named: detection.coordinatesBlobName, extents: [detection.boxCount, 4], in: outputs)
		try requireDetectionOutput(named: detection.confidenceBlobName, extents: [detection.boxCount, detection.labels.count], in: outputs)
	}

	private func requireDetectionOutput(named name: String, extents: [Int], in outputs: [NativeModelTensor]) throws {
		guard let tensor = outputs.first(where: { $0.name == name }) else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(reason: "the graph does not output '\(name)'")
		}
		let significant = tensor.shape.filter { $0 != 1 }
		// A [boxes, 1] tensor — a single-class detector — collapses to one significant extent, so
		// compare against the interface's own unit-stripped expectation rather than demanding two.
		guard significant == extents.filter({ $0 != 1 }) else {
			throw NativeModelCoreMLEmissionError.invalidDetectionInterface(
				reason: "output '\(name)' has shape \(tensor.shape); expected \(extents) once unit axes are ignored"
			)
		}
	}

	struct ClassifierPlan {
		let labels: [String]
		/// The graph's output blob (class scores in any unit-padded layout).
		let logitsBlobName: String
		/// Set when the scores are not already `[1, N]`: a flattenTo2D layer reshapes them first —
		/// Core ML expects the probability blob to be a plain class vector.
		let flattenedBlobName: String?
		/// False when the graph itself ends in a softmax over the class axis; appending another one
		/// would squash the probabilities (argmax survives, the reported confidences do not).
		let appendsSoftmax: Bool
		/// What the classifier's `labelProbabilityLayerName` points at.
		let probabilitiesBlobName: String
		let classLabelName = "classLabel"
		let classLabelProbsName = "classLabelProbs"

		/// The blob the appended classifier softmax reads (the flattened vector when one exists).
		var softmaxInputBlobName: String { flattenedBlobName ?? logitsBlobName }
	}

	/// Returns a classifier plan when the supplied labels match a single graph output that is a
	/// class-score vector in any unit-padded layout — `[1, N]`, `[1, N, 1, 1]`, `[1, 1, N]`, … (batch
	/// 1, exactly one non-unit dimension). Otherwise the graph is emitted as a plain neural network
	/// with its raw output.
	private func classifierPlan(
		outputs: [NativeModelTensor],
		operations: [NativeModelOperation],
		labels: [String]?
	) -> ClassifierPlan? {
		guard let labels, !labels.isEmpty, outputs.count == 1 else { return nil }
		let output = outputs[0]
		let shape = output.shape
		// At most one non-unit dimension, holding the class count. A one-label classifier's [1, 1]
		// (or [1, 1, 1, 1]) output has no non-unit dimension at all; its class axis is 1 by
		// convention, preserving the acceptance the package path always had.
		let nonUnitAxes = shape.indices.filter { shape[$0] != 1 }
		guard shape.count >= 2, shape[0] == 1, nonUnitAxes.count <= 1,
			let classAxis = nonUnitAxes.first ?? (labels.count == 1 ? 1 : nil),
			shape[classAxis] == labels.count
		else {
			return nil
		}
		let logits = output.name
		// A graph that already ends in a softmax over the class axis produced probabilities, not
		// logits. A softmax over any *other* (unit) axis normalizes nothing and still needs the real
		// class-axis softmax appended.
		let producing = operations.first { $0.outputs.contains { $0.name == logits } }
		let alreadyProbabilities = producing?.kind == .softmax
			&& producing?.attributes["axis"]?.integerValue == classAxis
		let flattenedBlobName = shape.count > 2 ? "\(logits)__classVector" : nil
		return ClassifierPlan(
			labels: labels,
			logitsBlobName: logits,
			flattenedBlobName: flattenedBlobName,
			appendsSoftmax: !alreadyProbabilities,
			probabilitiesBlobName: alreadyProbabilities ? (flattenedBlobName ?? logits) : "\(logits)__classProbs"
		)
	}

	/// The labels that will actually drive a classifier interface for this graph, or nil when the
	/// graph is emitted as a plain neural network.
	private func eligibleClassifierLabels(graph: NativeModelGraph, labels: [String]?) -> [String]? {
		let tensors = tensorIndex(for: graph)
		let outputs = graph.outputs.compactMap { tensors[$0] }
		return classifierPlan(outputs: outputs, operations: graph.operations, labels: labels)?.labels
	}

	/// A `softmaxND` layer normalizing along `axis`. The classifier interface uses it at axis 1 —
	/// the class dimension of a rank-2 `[batch, classes]` blob, where a negative axis could land on a
	/// size-1 trailing dimension and normalize nothing — and graph softmax ops pass their own
	/// reader-normalized axis.
	private func softmaxNDLayer(name: String, input: String, output: String, axis: Int) -> Data {
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(axis), to: &parameters)
		}
		return CoreMLProtobufEncoder.message { layer in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &layer)
			CoreMLProtobufEncoder.appendStringField(2, value: input, to: &layer)
			CoreMLProtobufEncoder.appendStringField(3, value: output, to: &layer)
			CoreMLProtobufEncoder.appendMessageField(950, value: parameters, to: &layer)
		}
	}

	private func stringVector(_ values: [String]) -> Data {
		CoreMLProtobufEncoder.message { vector in
			for value in values {
				CoreMLProtobufEncoder.appendStringField(1, value: value, to: &vector)
			}
		}
	}

	private func stringFeatureDescription(named name: String) -> Data {
		let featureType = CoreMLProtobufEncoder.message { featureType in
			CoreMLProtobufEncoder.appendMessageField(3, value: Data(), to: &featureType)
		}
		return CoreMLProtobufEncoder.message { feature in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &feature)
			CoreMLProtobufEncoder.appendMessageField(3, value: featureType, to: &feature)
		}
	}

	private func probabilitiesFeatureDescription(named name: String) -> Data {
		let dictionaryType = CoreMLProtobufEncoder.message { dictionaryType in
			CoreMLProtobufEncoder.appendMessageField(2, value: Data(), to: &dictionaryType)
		}
		let featureType = CoreMLProtobufEncoder.message { featureType in
			CoreMLProtobufEncoder.appendMessageField(6, value: dictionaryType, to: &featureType)
		}
		return CoreMLProtobufEncoder.message { feature in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &feature)
			CoreMLProtobufEncoder.appendMessageField(3, value: featureType, to: &feature)
		}
	}

	/// Builds target metadata for a model converted straight from ONNX (no package manifest).
	///
	/// Always produces a metadata block — even when the source carries no attribution — so every
	/// converted model records that it *is* a conversion, by which converter, of which weights. This
	/// matches the `.aiagraph` package path. A source-less model writes only converter/target
	/// provenance (no empty description/author/license), so its on-screen display stays the existing
	/// filename fallback. The weights digest is taken from `emittedWeights`, the exact blob written
	/// (which on the detector path already includes the synthesized decode constants).
	private func onnxTargetMetadata(
		source: NativeModelCoreMLMetadata?,
		sourceProvenance: NativeModelConversionSourceProvenance?,
		graph: NativeModelGraph,
		emittedWeights: Data,
		interface: ResolvedEmissionInterface,
		imageSizingContract: NativeModelImageSizingContract? = nil,
		parityEvidence: NativeModelParityEvidence = .unevidenced
	) throws -> NativeModelCoreMLMetadata {
		try targetMetadata(
			from: source,
			checksums: NativeModelConversionChecksums(
				weightsSHA256: NativeModelConversionChecksums.sha256Hex(of: emittedWeights)
			),
			graph: graph,
			sourceProvenance: sourceProvenance,
			interface: interface,
			imageSizingContract: imageSizingContract,
			parityEvidence: parityEvidence
		)
	}

	/// `parityEvidence` defaults to the unevidenced claim in both metadata builders, so a path added
	/// later that says nothing about parity writes the conservative fact rather than no fact at all.
	private func targetMetadata(
		from source: NativeModelCoreMLMetadata?,
		checksums: NativeModelConversionChecksums,
		graph: NativeModelGraph,
		sourceProvenance: NativeModelConversionSourceProvenance?,
		interface: ResolvedEmissionInterface,
		imageSizingContract: NativeModelImageSizingContract? = nil,
		parityEvidence: NativeModelParityEvidence = .unevidenced
	) throws -> NativeModelCoreMLMetadata {
		// A detector is emitted as a Core ML pipeline (network + NMS); a classifier interface is only
		// emitted when labels match the output. The format string reflects what was actually written.
		var userDefined: [String: String] = [
			"com.aiarcheology.native.target.model-format": interface.modelFormat,
			"com.aiarcheology.native.target.graph-format-version": String(graph.formatVersion),
			"com.aiarcheology.native.converter.package-version": NativeModelConverterVersion.packageVersion,
			"com.aiarcheology.native.converter.conversion-revision": String(NativeModelConverterVersion.conversionRevision),
			"com.aiarcheology.native.conversion.weights-sha256": checksums.weightsSHA256,
			"com.aiarcheology.native.conversion.producer.name": graph.producer.name,
			"com.aiarcheology.native.conversion.producer.version": graph.producer.version,
			"com.aiarcheology.native.target.interface.json": try targetInterfaceJSON(
				inputs: graph.inputs,
				outputs: graph.outputs,
				graph: graph
			),
			// Written on every path that builds target metadata, never conditionally: a model missing the
			// fact is indistinguishable from one whose numerics were checked, which is the confusion the
			// fact exists to prevent. The bare `emit(graph:weights:to:)` overload builds no metadata at
			// all, so a model written through it carries none of these keys.
			NativeModelParityProvenance.userDefinedKey:
				try NativeModelParityProvenance(evidence: parityEvidence).canonicalJSON()
		]
		if let imageSizingContract {
			userDefined[NativeModelImageSizingContract.userDefinedKey] = try imageSizingContract.canonicalJSON()
		}
		if let graphSHA256 = checksums.graphSHA256 {
			userDefined["com.aiarcheology.native.conversion.graph-sha256"] = graphSHA256
		}
		if let metadataChecksum = checksums.metadataSHA256 {
			userDefined["com.aiarcheology.native.conversion.source-metadata-sha256"] = metadataChecksum
		}
		if let filename = sourceProvenance?.sourcePackageFilename {
			userDefined["com.aiarcheology.native.conversion.source-package-filename"] = filename
		}
		if let filename = sourceProvenance?.originalModelFilename {
			userDefined["com.aiarcheology.native.conversion.original-model-filename"] = filename
		}
		if let url = sourceProvenance?.originalModelURL {
			userDefined["com.aiarcheology.native.conversion.original-model-url"] = url
		}
		if let classifier = interface.classifier {
			userDefined["com.aiarcheology.native.target.task"] = "classification"
			userDefined["com.aiarcheology.native.target.class-count"] = String(classifier.labels.count)
		}
		if let detection = interface.detection, let detectionTarget = interface.detectionTarget {
			// The facts AIA-0471's import UI reads to decide whether the labels are trustworthy or
			// inferred, and how the coordinates were normalized.
			userDefined["com.aiarcheology.native.target.task"] = "detection"
			userDefined["com.aiarcheology.native.target.class-count"] = String(detection.labels.count)
			userDefined["com.aiarcheology.native.target.label-provenance"] = detectionTarget.labelProvenanceValue
			userDefined["com.aiarcheology.native.target.coordinate-space"] = detectionTarget.coordinateSpaceValue
		}
		if let targetSemantics = interface.targetSemantics {
			targetSemantics.write(to: &userDefined)
		}

		guard let source else {
			return NativeModelCoreMLMetadata(userDefined: userDefined)
		}

		for (key, value) in source.userDefined {
			userDefined["com.aiarcheology.native.source.user-defined.\(key)"] = value
		}
		if let value = source.shortDescription {
			userDefined["com.aiarcheology.native.source.short-description"] = value
		}
		if let value = source.versionString {
			userDefined["com.aiarcheology.native.source.version"] = value
		}
		if let value = source.author {
			userDefined["com.aiarcheology.native.source.author"] = value
		}
		if let value = source.license {
			userDefined["com.aiarcheology.native.source.license"] = value
		}

		let description = source.shortDescription.map { "Converted Core ML neural-network model. Source description: \($0)" }
		return NativeModelCoreMLMetadata(
			shortDescription: description,
			versionString: source.versionString,
			author: source.author,
			license: source.license,
			userDefined: userDefined
		)
	}

	private func targetInterfaceJSON(
		inputs: [NativeModelTensor],
		outputs: [String],
		graph: NativeModelGraph
	) throws -> String {
		let tensors = tensorIndex(for: graph)
		let targetOutputs = try outputs.map { name -> NativeModelTensor in
			guard let tensor = tensors[name] else {
				throw NativeModelCoreMLEmissionError.missingOutputTensor(name)
			}
			return tensor
		}
		let interface = NativeModelTargetInterface(inputs: inputs, outputs: targetOutputs)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let encodedInterface = try encoder.encode(interface)
		guard let interfaceJSON = String(bytes: encodedInterface, encoding: .utf8) else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: "targetInterface",
				reason: "The JSON encoder produced non-UTF-8 data."
			)
		}
		return interfaceJSON
	}

	private func coreMLMetadataMessage(for metadata: NativeModelCoreMLMetadata) -> Data {
		CoreMLProtobufEncoder.message { message in
			if let value = metadata.shortDescription {
				CoreMLProtobufEncoder.appendStringField(1, value: value, to: &message)
			}
			if let value = metadata.versionString {
				CoreMLProtobufEncoder.appendStringField(2, value: value, to: &message)
			}
			if let value = metadata.author {
				CoreMLProtobufEncoder.appendStringField(3, value: value, to: &message)
			}
			if let value = metadata.license {
				CoreMLProtobufEncoder.appendStringField(4, value: value, to: &message)
			}
			for (key, value) in metadata.userDefined.sorted(by: { $0.key < $1.key }) {
				let entry = CoreMLProtobufEncoder.message { entry in
					CoreMLProtobufEncoder.appendStringField(1, value: key, to: &entry)
					CoreMLProtobufEncoder.appendStringField(2, value: value, to: &entry)
				}
				CoreMLProtobufEncoder.appendMessageField(100, value: entry, to: &message)
			}
		}
	}

	private func layer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		weights: Data,
		usesLegacyShapeMapping: Bool
	) throws -> Data {
		switch operation.kind {
		case .relu:
			reluLayer(for: operation)
		case .convolution2D:
			try convolutionLayer(for: operation, weightsByName: weightsByName, weights: weights)
		case .batchNormalization:
			try batchNormalizationLayer(for: operation, weightsByName: weightsByName, weights: weights)
		case .relu6:
			try relu6Layer(for: operation)
		case .globalAveragePool2D:
			try globalAveragePoolLayer(for: operation)
		case .flatten:
			try flattenLayer(for: operation)
		case .linear:
			try linearLayer(for: operation, weightsByName: weightsByName, weights: weights)
		case .add:
			try addLayer(for: operation)
		case .maxPool2D, .averagePool2D:
			try poolingLayer(for: operation)
		case .concatenate:
			try concatenateLayer(for: operation)
		case .softmax:
			try softmaxLayer(for: operation, usesLegacyShapeMapping: usesLegacyShapeMapping)
		case .constant:
			try loadConstantLayer(for: operation, weightsByName: weightsByName, weights: weights)
		case .constantND:
			try loadConstantNDLayer(for: operation, weightsByName: weightsByName, weights: weights)
		case .concatenateND:
			try concatenateNDLayer(for: operation)
		case .leakyReLU, .sigmoid, .exponential, .multiply, .reshape, .transpose, .sliceChannels, .softmaxChannel, .upsample2D,
			.reshapeND, .transposeND, .sliceND, .splitND, .batchedMatrixMultiplicationND,
			.floor, .naturalLogarithm, .greaterOrEqual, .minimumND, .maximumND, .subtract, .cropResize,
			.topK, .gather, .nonMaximumSuppression:
			try detectionLayer(for: operation)
		default:
			throw NativeModelCoreMLEmissionError.unsupportedOperation(
				operation: operation.name,
				kind: operation.kind.serializedValue
			)
		}
	}

	private func featureDescription(for tensor: NativeModelTensor) -> Data {
		let arrayType = CoreMLProtobufEncoder.message { arrayType in
			for dimension in tensor.shape {
				CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(dimension), to: &arrayType)
			}
			CoreMLProtobufEncoder.appendVarintField(2, value: coreMLArrayDataType(for: tensor.dataType), to: &arrayType)
		}

		let featureType = CoreMLProtobufEncoder.message { featureType in
			CoreMLProtobufEncoder.appendMessageField(5, value: arrayType, to: &featureType)
		}

		return CoreMLProtobufEncoder.message { featureDescription in
			CoreMLProtobufEncoder.appendStringField(1, value: tensor.name, to: &featureDescription)
			CoreMLProtobufEncoder.appendMessageField(3, value: featureType, to: &featureDescription)
		}
	}

	struct ImageInputPlan {
		/// The model's image input feature name (what Vision feeds).
		let imageFeatureName: String
		/// The graph's original input blob name; the normalization layer writes it.
		let networkInputName: String
		let width: Int
		let height: Int
		let preprocessing: NativeModelImagePreprocessing
	}

	/// Derives an image-input plan when the graph declares a vision interface (classifier or
	/// detector) and its single input is `[1, C, H, W]` with the channel count `preprocessing`
	/// expects and concrete spatial dimensions. Returns nil otherwise, so a non-image or
	/// raw-tensor graph keeps its plain multi-array input.
	private func imageInputPlan(
		inputTensors: [NativeModelTensor],
		declaresImageInterface: Bool,
		preprocessing: NativeModelImagePreprocessing?
	) -> ImageInputPlan? {
		guard declaresImageInterface, let preprocessing, inputTensors.count == 1 else { return nil }
		let input = inputTensors[0]
		let shape = input.shape
		guard shape.count == 4, shape[0] == 1,
			shape[1] == preprocessing.channelCount,
			preprocessing.scale.count == preprocessing.channelCount,
			preprocessing.bias.count == preprocessing.channelCount,
			shape[2] > 1, shape[3] > 1
		else {
			return nil
		}
		return ImageInputPlan(
			imageFeatureName: input.name == "image" ? "image_input" : "image",
			networkInputName: input.name,
			width: shape[3],
			height: shape[2],
			preprocessing: preprocessing
		)
	}

	/// A per-channel `scale · pixel + bias` layer that normalizes `[0, 255]` image pixels into the
	/// tensor the graph expects. Consumes the image feature and produces the graph's original input.
	private func imagePreprocessingLayer(for plan: ImageInputPlan) -> Data {
		let channelCount = UInt64(plan.preprocessing.channelCount)
		let scaleParameters = CoreMLProtobufEncoder.message { params in
			CoreMLProtobufEncoder.appendVarintField(1, value: channelCount, to: &params) // shapeScale = [C]
			CoreMLProtobufEncoder.appendMessageField(2, value: weightParameters(floats: plan.preprocessing.scale), to: &params)
			CoreMLProtobufEncoder.appendVarintField(3, value: 1, to: &params) // hasBias
			CoreMLProtobufEncoder.appendVarintField(4, value: channelCount, to: &params) // shapeBias = [C]
			CoreMLProtobufEncoder.appendMessageField(5, value: weightParameters(floats: plan.preprocessing.bias), to: &params)
		}
		return CoreMLProtobufEncoder.message { layer in
			CoreMLProtobufEncoder.appendStringField(1, value: "image_preprocessing", to: &layer)
			CoreMLProtobufEncoder.appendStringField(2, value: plan.imageFeatureName, to: &layer)
			CoreMLProtobufEncoder.appendStringField(3, value: plan.networkInputName, to: &layer)
			CoreMLProtobufEncoder.appendMessageField(245, value: scaleParameters, to: &layer) // ScaleLayerParams
		}
	}

	/// Encodes inline float constants as a float32 `WeightParams` (`floatValue`, little-endian raw
	/// bytes — the same encoding graph weights use).
	private func weightParameters(floats: [Float]) -> Data {
		let raw = floats.withUnsafeBytes { Data($0) }
		return CoreMLProtobufEncoder.message { params in
			CoreMLProtobufEncoder.appendMessageField(1, value: raw, to: &params)
		}
	}

	private func imageFeatureDescription(for plan: ImageInputPlan) -> Data {
		let imageType = CoreMLProtobufEncoder.message { imageType in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(plan.width), to: &imageType)
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(plan.height), to: &imageType)
			CoreMLProtobufEncoder.appendVarintField(3, value: plan.preprocessing.colorSpace.coreMLValue, to: &imageType)
		}
		let featureType = CoreMLProtobufEncoder.message { featureType in
			CoreMLProtobufEncoder.appendMessageField(4, value: imageType, to: &featureType) // FeatureType.imageType
		}
		return CoreMLProtobufEncoder.message { feature in
			CoreMLProtobufEncoder.appendStringField(1, value: plan.imageFeatureName, to: &feature)
			CoreMLProtobufEncoder.appendMessageField(3, value: featureType, to: &feature)
		}
	}

	private func reluLayer(for operation: NativeModelOperation) -> Data {
		let activation = CoreMLProtobufEncoder.message { activation in
			CoreMLProtobufEncoder.appendMessageField(10, value: Data(), to: &activation)
		}

		return CoreMLProtobufEncoder.message { layer in
			CoreMLProtobufEncoder.appendStringField(1, value: operation.name, to: &layer)
			for input in operation.inputs {
				CoreMLProtobufEncoder.appendStringField(2, value: input, to: &layer)
			}
			for output in operation.outputs {
				CoreMLProtobufEncoder.appendStringField(3, value: output.name, to: &layer)
			}
			CoreMLProtobufEncoder.appendMessageField(130, value: activation, to: &layer)
		}
	}

	private func convolutionLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		weights: Data
	) throws -> Data {
		guard operation.inputs.count == 2 || operation.inputs.count == 3 else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "expected an activation input, kernel weight, and optional bias"
			)
		}
		let kernel = try weight(named: operation.inputs[1], in: weightsByName)
		guard kernel.shape.count == 4 else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "kernel '\(kernel.name)' must have [outputChannels, kernelChannels, height, width] shape"
			)
		}
		let kernelSize = try integerArrayAttribute("kernelSize", for: operation, count: 2)
		let strides = try integerArrayAttribute("strides", for: operation, count: 2)
		let padding = try paddingAttribute(for: operation)
		let dilations = try integerArrayAttribute("dilations", for: operation, count: 2)
		let groups = try integerAttribute("groups", for: operation)
		guard kernel.shape[2] == kernelSize[0],
			kernel.shape[3] == kernelSize[1],
			kernelSize.allSatisfy({ $0 > 0 }),
			strides.allSatisfy({ $0 > 0 }),
			dilations.allSatisfy({ $0 > 0 }),
			groups > 0
		else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "kernel shape, kernelSize, and groups are inconsistent"
			)
		}

		let bias = try operation.inputs.dropFirst(2).first.map { try weight(named: $0, in: weightsByName) }
		if let bias, bias.shape != [kernel.shape[0]] {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "bias '\(bias.name)' must contain one value per output channel"
			)
		}

		let convolution = CoreMLProtobufEncoder.message { convolution in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(kernel.shape[0]), to: &convolution)
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(kernel.shape[1]), to: &convolution)
			CoreMLProtobufEncoder.appendVarintField(10, value: UInt64(groups), to: &convolution)
			for dimension in kernelSize {
				CoreMLProtobufEncoder.appendVarintField(20, value: UInt64(dimension), to: &convolution)
			}
			for stride in strides {
				CoreMLProtobufEncoder.appendVarintField(30, value: UInt64(stride), to: &convolution)
			}
			for dilation in dilations {
				CoreMLProtobufEncoder.appendVarintField(40, value: UInt64(dilation), to: &convolution)
			}
			CoreMLProtobufEncoder.appendMessageField(50, value: validPadding(padding), to: &convolution)
			if let bias {
				CoreMLProtobufEncoder.appendVarintField(70, value: 1, to: &convolution)
				CoreMLProtobufEncoder.appendMessageField(91, value: weightParameters(for: bias, in: weights), to: &convolution)
			}
			CoreMLProtobufEncoder.appendMessageField(90, value: weightParameters(for: kernel, in: weights), to: &convolution)
		}

		return CoreMLProtobufEncoder.message { layer in
			CoreMLProtobufEncoder.appendStringField(1, value: operation.name, to: &layer)
			CoreMLProtobufEncoder.appendStringField(2, value: operation.inputs[0], to: &layer)
			for output in operation.outputs {
				CoreMLProtobufEncoder.appendStringField(3, value: output.name, to: &layer)
			}
			CoreMLProtobufEncoder.appendMessageField(100, value: convolution, to: &layer)
		}
	}

	private func batchNormalizationLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		weights: Data
	) throws -> Data {
		guard operation.inputs.count == 5 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "batchNorm requires an activation input followed by scale, bias, mean, and variance weights"
			)
		}
		let gamma = try weight(named: operation.inputs[1], in: weightsByName)
		let beta = try weight(named: operation.inputs[2], in: weightsByName)
		let mean = try weight(named: operation.inputs[3], in: weightsByName)
		let variance = try weight(named: operation.inputs[4], in: weightsByName)
		guard gamma.shape.count == 1,
			beta.shape == gamma.shape,
			mean.shape == gamma.shape,
			variance.shape == gamma.shape
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "batchNorm scale, bias, mean, and variance must be equal-length vectors"
			)
		}
		guard let epsilon = operation.attributes["epsilon"]?.floatingPointValue, epsilon >= 0 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "batchNorm epsilon must be a non-negative floating-point value"
			)
		}

		let batchNorm = CoreMLProtobufEncoder.message { batchNorm in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(gamma.shape[0]), to: &batchNorm)
			CoreMLProtobufEncoder.appendFloatField(10, value: Float(epsilon), to: &batchNorm)
			CoreMLProtobufEncoder.appendMessageField(15, value: weightParameters(for: gamma, in: weights), to: &batchNorm)
			CoreMLProtobufEncoder.appendMessageField(16, value: weightParameters(for: beta, in: weights), to: &batchNorm)
			CoreMLProtobufEncoder.appendMessageField(17, value: weightParameters(for: mean, in: weights), to: &batchNorm)
			CoreMLProtobufEncoder.appendMessageField(18, value: weightParameters(for: variance, in: weights), to: &batchNorm)
		}

		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 160, parameters: batchNorm)
	}

	private func relu6Layer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		let clip = CoreMLProtobufEncoder.message { clip in
			CoreMLProtobufEncoder.appendFloatField(1, value: 0, to: &clip)
			CoreMLProtobufEncoder.appendFloatField(2, value: 6, to: &clip)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 660, parameters: clip)
	}

	private func globalAveragePoolLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		let pooling = CoreMLProtobufEncoder.message { pooling in
			CoreMLProtobufEncoder.appendVarintField(1, value: 1, to: &pooling)
			CoreMLProtobufEncoder.appendMessageField(30, value: validPadding([0, 0]), to: &pooling)
			CoreMLProtobufEncoder.appendVarintField(60, value: 1, to: &pooling)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 120, parameters: pooling)
	}

	/// Max and average pooling are one `PoolingLayerParams` (field 120) apart: the two differ only in the
	/// `type` member and in the average-only padding rule below, so they share an emitter rather than a
	/// copied one. Field numbers read off coremltools 9.0's `NeuralNetwork_pb2.PoolingLayerParams`
	/// descriptor: type = 1, kernelSize = 10, stride = 20, valid = 30, avgPoolExcludePadding = 50.
	///
	/// `avgPoolExcludePadding` is pinned to true, meaning the divisor counts only real samples. It is
	/// unobservable at the zero padding the ROI construction uses, so the pin is chosen for the padded
	/// case: it matches ONNX AveragePool's default (`count_include_pad = 0`). PyTorch's `AvgPool2d`
	/// defaults the other way, so a future reader that meets `count_include_pad=True` with non-zero
	/// padding has to reject it rather than assume this emitter agrees.
	private func poolingLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let kernelSize = operation.attributes["kernelSize"]?.integerArrayValue, kernelSize.count == 2,
			let strides = operation.attributes["strides"]?.integerArrayValue, strides.count == 2,
			(kernelSize + strides).allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "\(operation.kind.serializedValue) requires kernelSize/strides pairs of positive integers"
			)
		}
		let isAverage = operation.kind == .averagePool2D
		let padding = try paddingAttribute(for: operation)
		let pooling = CoreMLProtobufEncoder.message { pooling in
			// PoolingType MAX is the proto3 default (0), so only AVERAGE (1) is written.
			if isAverage {
				CoreMLProtobufEncoder.appendVarintField(1, value: 1, to: &pooling)
			}
			for dimension in kernelSize {
				CoreMLProtobufEncoder.appendVarintField(10, value: UInt64(dimension), to: &pooling)
			}
			for stride in strides {
				CoreMLProtobufEncoder.appendVarintField(20, value: UInt64(stride), to: &pooling)
			}
			CoreMLProtobufEncoder.appendMessageField(30, value: validPadding(padding), to: &pooling)
			if isAverage {
				CoreMLProtobufEncoder.appendVarintField(50, value: 1, to: &pooling)
			}
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 120, parameters: pooling)
	}

	/// The classic concat layer joins its inputs along the channel axis (third-from-last), which is
	/// axis 1 of the rank-4 `[1, C, H, W]` activations the reader produces — and the only axis the
	/// reader accepts, re-checked here so a hand-built graph cannot smuggle a different one through.
	private func concatenateLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count >= 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "concat requires at least two activation inputs"
			)
		}
		guard operation.attributes["axis"]?.integerValue == 1 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "concat currently supports the channel axis (1) only"
			)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 320, parameters: Data())
	}

	private func softmaxLayer(for operation: NativeModelOperation, usesLegacyShapeMapping: Bool) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let axis = operation.attributes["axis"]?.integerValue, axis >= 0 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "softmax requires a non-negative axis (the reader normalizes negative axes)"
			)
		}
		// Under the legacy rank-5 mapping (forced network-wide by any reshape/permute), softmaxND's
		// axis numbering addresses the [Seq, Batch, Channel, Height, Width] layout — NOT the rank the
		// reader computed the axis against — so a reader axis of 1 (channel) must emit the classic
		// channel softmax instead, and any other axis has no correct classic equivalent.
		if usesLegacyShapeMapping {
			guard axis == 1 else {
				throw NativeModelCoreMLEmissionError.invalidOperation(
					operation: operation.name,
					reason: "softmax over axis \(axis) cannot be expressed under Core ML's legacy rank-5 mapping (only the channel axis, 1, can)"
				)
			}
			return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 175, parameters: Data())
		}
		return softmaxNDLayer(name: operation.name, input: operation.inputs[0], output: operation.outputs[0].name, axis: axis)
	}

	private func flattenLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard operation.attributes["axis"]?.integerValue == 1 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "flatten currently supports channel-first axis 1 only"
			)
		}
		return flattenTo2DLayer(name: operation.name, input: operation.inputs[0], output: operation.outputs[0].name)
	}

	/// FlattenTo2D produces a rank-2 [batch, features] blob that Core ML accepts both internally and
	/// as an external model output. The legacy Flatten layer (rank-preserving) cannot be exposed as
	/// a rank-2 output feature, which a classifier flatten-to-logits at the end of a graph requires.
	/// Shared by the graph flatten op and the classifier interface's class-vector flatten.
	private func flattenTo2DLayer(name: String, input: String, output: String) -> Data {
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: 1, to: &parameters) // axis 1
		}
		return CoreMLProtobufEncoder.message { layer in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &layer)
			CoreMLProtobufEncoder.appendStringField(2, value: input, to: &layer)
			CoreMLProtobufEncoder.appendStringField(3, value: output, to: &layer)
			CoreMLProtobufEncoder.appendMessageField(1130, value: parameters, to: &layer)
		}
	}

	/// Routes the operations introduced for detection decoding. Split from `layer(for:)` so the
	/// operator table stays inside the cyclomatic-complexity limit; the kinds it does not name go on to
	/// `boxArithmeticLayer(for:)`, which raises the same unsupported-operation error for anything
	/// neither router handles.
	private func detectionLayer(for operation: NativeModelOperation) throws -> Data {
		switch operation.kind {
		case .leakyReLU: try leakyReLULayer(for: operation)
		case .sigmoid: try sigmoidLayer(for: operation)
		case .exponential: try exponentialLayer(for: operation)
		case .multiply: try multiplyLayer(for: operation)
		case .reshape: try reshapeLayer(for: operation)
		case .transpose: try transposeLayer(for: operation)
		case .sliceChannels: try sliceChannelsLayer(for: operation)
		case .softmaxChannel: try softmaxChannelLayer(for: operation)
		case .upsample2D: try upsampleLayer(for: operation)
		case .reshapeND: try reshapeNDLayer(for: operation)
		case .transposeND: try transposeNDLayer(for: operation)
		case .sliceND: try sliceNDLayer(for: operation)
		case .splitND: try splitNDLayer(for: operation)
		case .batchedMatrixMultiplicationND: try batchedMatrixMultiplicationNDLayer(for: operation)
		default: try boxArithmeticLayer(for: operation)
		}
	}

	/// Routes the elementwise and mask primitives the box arithmetic is built from — FPN level
	/// assignment, small-box filtering, and coordinate clipping — plus the ROI crop those boxes feed and
	/// the top-K/gather pair that decides which boxes reach it at all.
	/// A third router rather than more cases in the two above it, for the same reason those were split:
	/// to stay inside the cyclomatic-complexity limit, which the router above is already at.
	private func boxArithmeticLayer(for operation: NativeModelOperation) throws -> Data {
		switch operation.kind {
		case .floor: try floorLayer(for: operation)
		case .naturalLogarithm: try naturalLogarithmLayer(for: operation)
		case .greaterOrEqual: try greaterOrEqualLayer(for: operation)
		case .minimumND: try elementwiseBoundLayer(for: operation, parameterField: 870)
		case .maximumND: try elementwiseBoundLayer(for: operation, parameterField: 875)
		case .subtract: try subtractLayer(for: operation)
		case .cropResize: try cropResizeLayer(for: operation)
		case .topK: try topKLayer(for: operation)
		case .gather: try gatherLayer(for: operation)
		case .nonMaximumSuppression: try nonMaximumSuppressionLayer(for: operation)
		default:
			throw NativeModelCoreMLEmissionError.unsupportedOperation(
				operation: operation.name,
				kind: operation.kind.serializedValue
			)
		}
	}

	/// Rounds toward negative infinity — Core ML's parameterless `FloorLayerParams` (field 670). The
	/// level assignment relies on the negative side truncating downward: a box smaller than the
	/// canonical scale has a negative level before clamping, where `trunc` would round it the wrong way.
	private func floorLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 670, parameters: Data())
	}

	/// `ln(x)`, expressed as Core ML's unary-function layer with type LOG. Any other base is one
	/// multiply away (`log2(x) = ln(x) · 1/ln 2`), which is what lets the level assignment sum two
	/// half-logarithms instead of forming a box area that overflows fp16 above 65504.
	private func naturalLogarithmLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		let unary = CoreMLProtobufEncoder.message { unary in
			// UnaryFunctionLayerParams.type = 1; the LOG member of that enum is 5.
			CoreMLProtobufEncoder.appendVarintField(1, value: 5, to: &unary)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 220, parameters: unary)
	}

	/// `x >= threshold` as a 1.0/0.0 mask. `GreaterEqualLayerParams` (field 832) accepts either two
	/// blobs or one blob and its threshold scalar; this is the single-input form, so the threshold
	/// rides in the layer rather than costing a constant blob. That scalar is the message's *only*
	/// field and it is numbered 2, not 1 — writing it as field 1 leaves the layer comparing against 0.
	private func greaterOrEqualLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let threshold = operation.attributes["threshold"]?.floatingPointValue else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "greaterEqual requires a floating-point 'threshold' attribute"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendFloatField(2, value: Float(threshold), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 832, parameters: parameters)
	}

	/// Elementwise `min(a, b)` (field 870) and `max(a, b)` (field 875), both parameterless. Taking the
	/// bound as a second tensor is what makes a per-coordinate box clip expressible: the scalar Clip
	/// layer would force one interval on x and y, which is wrong the moment the image is not square.
	private func elementwiseBoundLayer(for operation: NativeModelOperation, parameterField: Int) throws -> Data {
		guard operation.inputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "\(operation.kind.serializedValue) requires exactly two activation inputs"
			)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: parameterField, parameters: Data())
	}

	/// Core ML's `CropResize` (layer field 212) — one bilinear ROI patch per box, and the first layer
	/// here with two runtime inputs that are not interchangeable: input 0 is the feature map and input 1
	/// the boxes. Both must be declared rank 5 (the layer validates `rank >= 5` and rejects less):
	/// features `[1, B, C, H, W]`, boxes `[K, 1, 4, 1, 1]`, output `[K, B, C, targetHeight, targetWidth]`
	/// — measured, not assumed, in `scripts/m3a_parity_spike/probes.py`.
	///
	/// `CropResizeLayerParams` field numbers verified against coremltools 9.0's
	/// `NeuralNetwork_pb2.CropResizeLayerParams` descriptor: targetSize = 1 (repeated uint64, height then
	/// width, matching `NeuralNetworkBuilder.add_crop_resize`'s append order), normalizedCoordinates = 2,
	/// mode = 3, boxIndicesMode = 4, spatialScale = 5.
	///
	/// Sampling mode and box order are pinned rather than parameterised. `SamplingMode.samplingMethod`
	/// (field 1) is written as ROI_ALIGN_MODE (3) because the enum's zero member is
	/// STRICT_ALIGN_ENDPOINTS_MODE, a *different* sampling grid that would silently take the default.
	/// `BoxCoordinatesMode.boxMode` (field 1) is CORNERS_HEIGHT_FIRST, which *is* that enum's zero member,
	/// so field 4 carries an empty message: the submessage is present on the wire without writing a
	/// redundant zero. `[y0, x0, y1, x1]` is the order the box blob must already be in.
	private func cropResizeLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "cropResize requires exactly two inputs: the feature map and the box blob"
			)
		}
		guard let targetHeight = operation.attributes["targetHeight"]?.integerValue, targetHeight > 0,
			let targetWidth = operation.attributes["targetWidth"]?.integerValue, targetWidth > 0,
			let spatialScale = operation.attributes["spatialScale"]?.floatingPointValue, spatialScale > 0
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "cropResize requires positive 'targetHeight'/'targetWidth' integers and a positive 'spatialScale'"
			)
		}
		// Absent means unnormalized box coordinates — the form the box arithmetic produces, in feature
		// pixels once `spatialScale` has been applied. The validator refuses a present non-boolean, so
		// this coalesce covers absence only, never a wrongly typed value quietly reading as false.
		let normalizedROI = operation.attributes["normalizedROI"]?.booleanValue ?? false
		let samplingMode = CoreMLProtobufEncoder.message { mode in
			CoreMLProtobufEncoder.appendVarintField(1, value: 3, to: &mode)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(targetHeight), to: &parameters)
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(targetWidth), to: &parameters)
			if normalizedROI {
				CoreMLProtobufEncoder.appendVarintField(2, value: 1, to: &parameters)
			}
			CoreMLProtobufEncoder.appendMessageField(3, value: samplingMode, to: &parameters)
			CoreMLProtobufEncoder.appendMessageField(4, value: Data(), to: &parameters)
			CoreMLProtobufEncoder.appendFloatField(5, value: Float(spatialScale), to: &parameters)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 212, parameters: parameters)
	}

	/// Core ML's `TopK` (layer field 1015): the `k` largest values along `axis` and the source index of
	/// each. Two outputs, values first and indices second — not a choice this emitter makes, but the
	/// layer's own rule: Core ML's validator rejects any other count outright ("Layer 'tk' of type 1015
	/// has 1 outputs but expects exactly 2", measured on a compiled model with coremltools 9.0). So a
	/// values-only emitter fails to compile, while a swapped one compiles and returns ranks as scores.
	///
	/// `TopKLayerParams` field numbers verified against coremltools 9.0's `NeuralNetwork_pb2.TopKLayerParams`
	/// descriptor: axis = 1 (int64), K = 2 (uint64), useBottomK = 3 (bool). `useBottomK` stays at its
	/// proto3 default of false; the bottom-k form is the same layer returning the K *smallest* values and
	/// would compile identically.
	///
	/// Values come back in descending order (measured on that same probe). Which of two *equal* values
	/// wins is not part of the contract — nothing in the parameters orders them — so a graph that depends
	/// on tie order is depending on an unspecified detail.
	private func topKLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard operation.outputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "topK produces exactly two outputs: the values, then their source indices"
			)
		}
		guard let k = operation.attributes["k"]?.integerValue, k > 0,
			let axis = operation.attributes["axis"]?.integerValue, axis >= 0
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "topK requires a positive 'k' and a non-negative 'axis' (the reader normalizes negative axes)"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(axis), to: &parameters)
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(k), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 1015, parameters: parameters)
	}

	/// Core ML's `Gather` (layer field 930): input 0 is the data blob, input 1 the indices, and the output
	/// takes the indices tensor's shape in place of `data`'s `axis`. Its rank is therefore
	/// `data.rank - 1 + indices.rank` — the same expression coremltools' own `add_gather` records for the
	/// output — so rank-2 indices over rank-2 data give a rank-3 result. Nothing here recomputes that: the
	/// emitter declares the shape the graph already carries, and Core ML rejects a declaration that
	/// disagrees. The two inputs are not interchangeable and a swap still compiles whenever both ranks
	/// permit it.
	///
	/// `GatherLayerParams` has exactly one field, axis = 1 (int64), verified against coremltools 9.0's
	/// `NeuralNetwork_pb2.GatherLayerParams` descriptor. Indices ride in an ordinary float blob — the
	/// neural-network spec has no integer blob — and the layer truncates them.
	private func gatherLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "gather requires exactly two inputs: the data blob and the indices"
			)
		}
		guard let axis = operation.attributes["axis"]?.integerValue, axis >= 0 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "gather requires a non-negative 'axis' (the reader normalizes negative axes)"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(axis), to: &parameters)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 930, parameters: parameters)
	}

	/// Greedy non-maximum suppression as a **layer inside the graph** (`NeuralNetworkLayer` field 1400) —
	/// deliberately not the standalone NMS **model** `NativeModelDetectorPipeline` emits as its terminal
	/// stage. Different operator, different message, different semantics: the model has flexible outputs
	/// and a Vision-facing interface and can only be last, this one has fixed padded outputs and a
	/// valid-count and can sit anywhere. The M3a spike measured both precisely because reporting one while
	/// meaning the other is the easy mistake here.
	///
	/// Inputs are boxes then scores, and both must be rank 3 exactly: `[1, N, 4]` and `[1, N, classes]`.
	/// Measured, not assumed — a rank-2 pair still writes a well-formed `.mlmodel`, which Core ML's own
	/// compiler then refuses: "non_maximum_suppression_kernel: first two inputs must have rank 3"
	/// (coremltools 9.0, the probe harness in `scripts/m3a_parity_spike/probes.py`).
	///
	/// **Box coordinates are mandatorily `[center-x, center-y, width, height]`.** Unlike `CropResize`,
	/// whose `boxIndicesMode` chooses between corner conventions, this message has *no* coordinate-mode
	/// field — verified by reading the whole descriptor, which has exactly the four fields written below.
	/// Every other box operation in this file works in corners, so the conversion belongs immediately
	/// before this layer; corners fed here suppress a different set and nothing reports an error.
	///
	/// `NonMaximumSuppressionLayerParams` field numbers verified against coremltools 9.0's
	/// `NeuralNetwork_pb2.NonMaximumSuppressionLayerParams` descriptor: iouThreshold = 1 (float),
	/// scoreThreshold = 2 (float), maxBoxes = 3 (uint64), perClassSuppression = 4 (bool).
	///
	/// Four outputs, all padded to `maxBoxes` — kept boxes, kept scores, kept source indices (padded with
	/// −1), and `valid_count`. **`valid_count` lies at zero survivors**: with a score threshold above every
	/// input score the layer reports 1, and slot 0 carries the highest-scoring box together with its real,
	/// sub-threshold score (measured, coremltools 9.0). A graph that trusts it therefore grows one phantom
	/// detection on every empty tile, which for this app is every page with no archaeology on it. The fix
	/// is a mask on the returned scores, composed in the graph rather than hidden in this layer;
	/// `NativeModelDetectionLayerTests` pins both the defect and the composition that cancels it.
	private func nonMaximumSuppressionLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "nms requires exactly two inputs: the boxes and the scores"
			)
		}
		guard operation.outputs.count == 4 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "nms produces exactly four outputs: boxes, scores, source indices, then the valid count"
			)
		}
		guard let iouThreshold = operation.attributes["iouThreshold"]?.floatingPointValue,
			let scoreThreshold = operation.attributes["scoreThreshold"]?.floatingPointValue,
			let maxBoxes = operation.attributes["maxBoxes"]?.integerValue, maxBoxes > 0
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "nms requires floating-point 'iouThreshold' and 'scoreThreshold' values and a positive 'maxBoxes'"
			)
		}
		// Absent means class-agnostic suppression, which is what ADAF's single-class detectors need and
		// what the reference pipeline does; the flag only becomes observable with more than one class. As
		// with `normalizedROI`, the validator refuses a present non-boolean before this coalesce runs.
		let perClassSuppression = operation.attributes["perClassSuppression"]?.booleanValue ?? false
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendFloatField(1, value: Float(iouThreshold), to: &parameters)
			CoreMLProtobufEncoder.appendFloatField(2, value: Float(scoreThreshold), to: &parameters)
			CoreMLProtobufEncoder.appendVarintField(3, value: UInt64(maxBoxes), to: &parameters)
			if perClassSuppression {
				CoreMLProtobufEncoder.appendVarintField(4, value: 1, to: &parameters)
			}
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 1400, parameters: parameters)
	}

	/// `a - b`, Core ML's parameterless `SubtractBroadcastableLayerParams` (field 905). The classic
	/// layer set has add (230) and multiply (231) but no subtract at all, which is why this one
	/// operation the graph validator has always accepted had no emitter case until now.
	private func subtractLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "subtract requires exactly two activation inputs"
			)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 905, parameters: Data())
	}

	/// Core ML's classic softmax (field 175), which always normalizes over the channel axis. The
	/// decode uses it on the class-scores blob under the legacy rank-5 layout, where softmaxND's
	/// axis numbering would be relative to a different rank than the reader computed.
	private func softmaxChannelLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 175, parameters: Data())
	}

	/// Nearest-neighbor spatial upsample — Core ML's classic `UpsampleLayerParams` (field 210). The
	/// interpolation mode stays at its proto3 default (NN = 0), so no mode field is written; the
	/// scaling factor is the required `[H, W]` order. This reproduces ONNX `Resize` with nearest mode,
	/// `asymmetric` transform, and integer scales, where `out[c, i, j] = in[c, i / f, j / f]`.
	private func upsampleLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let scalingFactor = operation.attributes["scalingFactor"]?.integerArrayValue,
			scalingFactor.count == 2, scalingFactor.allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "upsample2d requires a 'scalingFactor' of two positive integers"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			// UpsampleLayerParams.scalingFactor = 1 (repeated uint64, [H, W]).
			for factor in scalingFactor {
				CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(factor), to: &parameters)
			}
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 210, parameters: parameters)
	}

	/// `y = x` for `x > 0`, `alpha · x` otherwise. Core ML carries the slope inside
	/// `ActivationParams.leakyReLU` (field 15), whose single float field is alpha.
	private func leakyReLULayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let alpha = operation.attributes["alpha"]?.floatingPointValue else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "leakyRelu requires a floating-point 'alpha' attribute"
			)
		}
		let leaky = CoreMLProtobufEncoder.message { leaky in
			CoreMLProtobufEncoder.appendFloatField(1, value: Float(alpha), to: &leaky)
		}
		let activation = CoreMLProtobufEncoder.message { activation in
			CoreMLProtobufEncoder.appendMessageField(15, value: leaky, to: &activation)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 130, parameters: activation)
	}

	/// The logistic activation, `ActivationParams.sigmoid` (field 40) — an empty message, since the
	/// function takes no parameters.
	private func sigmoidLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		let activation = CoreMLProtobufEncoder.message { activation in
			CoreMLProtobufEncoder.appendMessageField(40, value: Data(), to: &activation)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 130, parameters: activation)
	}

	/// `e^x`, expressed as Core ML's unary-function layer with type EXP.
	private func exponentialLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		let unary = CoreMLProtobufEncoder.message { unary in
			// UnaryFunctionLayerParams.type = 1; the EXP member of that enum is 4.
			CoreMLProtobufEncoder.appendVarintField(1, value: 4, to: &unary)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 220, parameters: unary)
	}

	/// Elementwise product. Distinct from `add` (230) only by its parameter field, but a mix-up
	/// would silently sum the anchors into the box sizes instead of scaling them.
	private func multiplyLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count >= 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "multiply requires at least two activation inputs"
			)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 231, parameters: Data())
	}

	/// A static reshape. Core ML's classic reshape takes a rank-4 target shape; the decode uses it to
	/// move between the grid layout `[1, A·(5+C), S, S]` and the per-attribute layout it slices.
	private func reshapeLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let shape = operation.attributes["shape"]?.integerArrayValue,
			shape.count == 4, shape.allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "reshape requires a 'shape' of four positive integers"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			// ReshapeLayerParams.targetShape = 1 (packed). Mode stays at its default, which reads the
			// source in channel-first order.
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: shape.map(UInt64.init), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 300, parameters: parameters)
	}

	/// An axis permutation. Row order in the detection outputs depends entirely on this being right:
	/// a wrong permutation still compiles and then pairs every box with another box's scores.
	private func transposeLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let permutation = operation.attributes["permutation"]?.integerArrayValue,
			permutation.count == 4, Set(permutation) == Set(0 ..< 4)
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "transpose requires 'permutation' to be a permutation of the four axes"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			// PermuteLayerParams.axis = 1 (packed).
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: permutation.map(UInt64.init), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 310, parameters: parameters)
	}

	/// A half-open `[start, end)` slice along the channel axis, which is how the decode separates
	/// box geometry, objectness, and class scores out of one packed grid tensor.
	private func sliceChannelsLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let start = operation.attributes["startChannel"]?.integerValue,
			let end = operation.attributes["endChannel"]?.integerValue,
			start >= 0, end > start
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "sliceChannels requires 0 <= startChannel < endChannel"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			// SliceLayerParams: startIndex = 1, endIndex = 2, stride = 3. The axis field stays at its
			// default, CHANNEL_AXIS. startIndex is omitted when zero, matching proto3 defaults.
			if start != 0 {
				CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(start), to: &parameters)
			}
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(end), to: &parameters)
			CoreMLProtobufEncoder.appendVarintField(3, value: 1, to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 350, parameters: parameters)
	}

	/// Exact-rank static reshape (Core ML `ReshapeStaticLayerParams`, field 1140). Unlike the classic
	/// reshape this uses the ONNX target verbatim, including rank 2 and ranks above 4.
	private func reshapeNDLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let shape = operation.attributes["shape"]?.integerArrayValue,
			!shape.isEmpty, shape.allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "reshapeND requires a non-empty 'shape' of positive integers"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: shape.map(UInt64.init), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 1140, parameters: parameters)
	}

	/// Exact-rank axis permutation (Core ML `TransposeLayerParams`, field 985).
	private func transposeNDLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let axes = operation.attributes["permutation"]?.integerArrayValue,
			!axes.isEmpty, Set(axes) == Set(0 ..< axes.count)
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "transposeND requires 'permutation' to be a complete axis permutation"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: axes.map(UInt64.init), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 985, parameters: parameters)
	}

	/// Exact-rank concatenation along the normalized non-negative axis preserved by the reader.
	private func concatenateNDLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count >= 2,
			let axis = operation.attributes["axis"]?.integerValue, axis >= 0
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "concatND requires at least two inputs and a non-negative axis"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(axis), to: &parameters)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 980, parameters: parameters)
	}

	/// Exact-rank static slice with full-rank normalized begin/end/stride lists.
	private func sliceNDLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let beginIds = operation.attributes["beginIds"]?.integerArrayValue,
			let endIds = operation.attributes["endIds"]?.integerArrayValue,
			let strides = operation.attributes["strides"]?.integerArrayValue,
			beginIds.count == endIds.count, beginIds.count == strides.count,
			!beginIds.isEmpty, beginIds.allSatisfy({ $0 >= 0 }), endIds.allSatisfy({ $0 >= 0 }), strides.allSatisfy({ $0 > 0 }),
			zip(beginIds, endIds).allSatisfy({ $0.1 > $0.0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "sliceND requires equal-length non-negative begin/end lists with end > begin and positive strides"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: beginIds.map(UInt64.init), to: &parameters)
			// SliceStatic declares all three mask vectors as required, even when every bit is false.
			// Omitting their proto3-default values makes Core ML reject the model at compile time.
			CoreMLProtobufEncoder.appendPackedVarintField(2, values: Array(repeating: 0, count: beginIds.count), to: &parameters)
			CoreMLProtobufEncoder.appendPackedVarintField(3, values: endIds.map(UInt64.init), to: &parameters)
			CoreMLProtobufEncoder.appendPackedVarintField(4, values: Array(repeating: 0, count: endIds.count), to: &parameters)
			CoreMLProtobufEncoder.appendPackedVarintField(5, values: strides.map(UInt64.init), to: &parameters)
			CoreMLProtobufEncoder.appendPackedVarintField(6, values: Array(repeating: 0, count: strides.count), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 995, parameters: parameters)
	}

	/// Multi-output exact-ND split. `splitSizes` is carried rather than inferred, so the emitted
	/// graph remains faithful to Q/K/V partitions such as `[32, 32, 64]`.
	private func splitNDLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count == 1, operation.outputs.count >= 2,
			let axis = operation.attributes["axis"]?.integerValue, axis >= 0,
			let splitSizes = operation.attributes["splitSizes"]?.integerArrayValue,
			splitSizes.count == operation.outputs.count, splitSizes.allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "splitND requires one input, one positive split size per output, and a non-negative axis"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(axis), to: &parameters)
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(operation.outputs.count), to: &parameters)
			CoreMLProtobufEncoder.appendPackedVarintField(3, values: splitSizes.map(UInt64.init), to: &parameters)
		}
		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 975, parameters: parameters)
	}

	/// Core ML's `BatchedMatMulLayerParams` requires no parameters for the direct `A × B` form.
	private func batchedMatrixMultiplicationNDLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "batchedMatmulND requires exactly two activation inputs"
			)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 1045, parameters: Data())
	}

	/// A `loadConstant` layer: an input-free layer that materializes a fixed tensor, used by the
	/// detection decode for grid offsets and anchor sizes.
	///
	/// Core ML declares the constant's shape as exactly rank 3 (`[channels, height, width]`), so a
	/// rank-4 weight carrying a leading unit batch is accepted and the batch axis dropped; anything
	/// else is rejected rather than reshaped behind the caller's back.
	private func loadConstantLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		weights: Data
	) throws -> Data {
		guard operation.inputs.count == 1 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "constant takes exactly one input naming the weight that holds its values"
			)
		}
		let constant = try weight(named: operation.inputs[0], in: weightsByName)
		let shape = constant.shape.count == 4 && constant.shape[0] == 1
			? Array(constant.shape.dropFirst())
			: constant.shape
		guard shape.count == 3 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "constant '\(constant.name)' must have a [channels, height, width] shape, got \(constant.shape)"
			)
		}

		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: shape.map(UInt64.init), to: &parameters)
			CoreMLProtobufEncoder.appendMessageField(2, value: weightParameters(for: constant, in: weights), to: &parameters)
		}
		// A load-constant layer has no inputs at all; passing one would make Core ML expect a blob
		// that never exists.
		return layer(name: operation.name, inputs: [], outputs: operation.outputs, parameterField: 290, parameters: parameters)
	}

	/// `loadConstantND` is the exact-rank counterpart of `loadConstant`: it retains every declared
	/// ONNX dimension (including batch) and is therefore safe to feed an exact-ND elementwise op.
	private func loadConstantNDLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		weights: Data
	) throws -> Data {
		guard operation.inputs.count == 1 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "constantND takes exactly one input naming the weight that holds its values"
			)
		}
		let constant = try weight(named: operation.inputs[0], in: weightsByName)
		guard !constant.shape.isEmpty, constant.shape.allSatisfy({ $0 > 0 }) else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "constantND '\(constant.name)' must have a non-empty positive shape"
			)
		}
		let parameters = CoreMLProtobufEncoder.message { parameters in
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: constant.shape.map(UInt64.init), to: &parameters)
			CoreMLProtobufEncoder.appendMessageField(2, value: weightParameters(for: constant, in: weights), to: &parameters)
		}
		return layer(name: operation.name, inputs: [], outputs: operation.outputs, parameterField: 1070, parameters: parameters)
	}

	private func linearLayer(
		for operation: NativeModelOperation,
		weightsByName: [String: NativeModelWeight],
		weights: Data
	) throws -> Data {
		guard operation.inputs.count == 2 || operation.inputs.count == 3 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "linear requires an activation input, weight matrix, and optional bias"
			)
		}
		let matrix = try weight(named: operation.inputs[1], in: weightsByName)
		guard matrix.shape.count == 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "linear weight '\(matrix.name)' must have [outputChannels, inputChannels] shape"
			)
		}
		let bias = try operation.inputs.dropFirst(2).first.map { try weight(named: $0, in: weightsByName) }
		if let bias, bias.shape != [matrix.shape[0]] {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "linear bias '\(bias.name)' must contain one value per output channel"
			)
		}

		let innerProduct = CoreMLProtobufEncoder.message { innerProduct in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(matrix.shape[1]), to: &innerProduct)
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(matrix.shape[0]), to: &innerProduct)
			if let bias {
				CoreMLProtobufEncoder.appendVarintField(10, value: 1, to: &innerProduct)
				CoreMLProtobufEncoder.appendMessageField(21, value: weightParameters(for: bias, in: weights), to: &innerProduct)
			}
			CoreMLProtobufEncoder.appendMessageField(20, value: weightParameters(for: matrix, in: weights), to: &innerProduct)
		}

		return simpleLayer(name: operation.name, input: operation.inputs[0], outputs: operation.outputs, parameterField: 140, parameters: innerProduct)
	}

	private func addLayer(for operation: NativeModelOperation) throws -> Data {
		guard operation.inputs.count >= 2 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "add requires at least two activation inputs"
			)
		}
		return layer(name: operation.name, inputs: operation.inputs, outputs: operation.outputs, parameterField: 230, parameters: Data())
	}

	private func simpleLayer(
		name: String,
		input: String,
		outputs: [NativeModelTensor],
		parameterField: Int,
		parameters: Data
	) -> Data {
		layer(name: name, inputs: [input], outputs: outputs, parameterField: parameterField, parameters: parameters)
	}

	private func layer(
		name: String,
		inputs: [String],
		outputs: [NativeModelTensor],
		parameterField: Int,
		parameters: Data
	) -> Data {
		CoreMLProtobufEncoder.message { layer in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &layer)
			for input in inputs {
				CoreMLProtobufEncoder.appendStringField(2, value: input, to: &layer)
			}
			for output in outputs {
				CoreMLProtobufEncoder.appendStringField(3, value: output.name, to: &layer)
			}
			CoreMLProtobufEncoder.appendMessageField(parameterField, value: parameters, to: &layer)
		}
	}

	private func requireSingleActivationInput(_ operation: NativeModelOperation) throws {
		guard operation.inputs.count == 1 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "expected exactly one activation input"
			)
		}
	}

	/// Encodes a `ValidPadding` message. `padding` is either the symmetric `[padH, padW]` form or the
	/// per-edge `[top, left, bottom, right]` form — Core ML's border amounts are ordered
	/// [height, width] with distinct start (top/left) and end (bottom/right) sizes, which is what
	/// lets an ONNX SAME_UPPER's odd padding pixel land on the correct edge.
	private func validPadding(_ padding: [Int]) -> Data {
		let edges: [(start: Int, end: Int)] = padding.count == 4
			? [(padding[0], padding[2]), (padding[1], padding[3])]
			: [(padding[0], padding[0]), (padding[1], padding[1])]
		let borderAmounts = CoreMLProtobufEncoder.message { borderAmounts in
			for edge in edges {
				let edgeSizes = CoreMLProtobufEncoder.message { edgeSizes in
					CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(edge.start), to: &edgeSizes)
					CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(edge.end), to: &edgeSizes)
				}
				CoreMLProtobufEncoder.appendMessageField(10, value: edgeSizes, to: &borderAmounts)
			}
		}
		return CoreMLProtobufEncoder.message { padding in
			CoreMLProtobufEncoder.appendMessageField(1, value: borderAmounts, to: &padding)
		}
	}

	private func weightParameters(for weight: NativeModelWeight, in weights: Data) -> Data {
		let start = Int(weight.offset)
		let end = start + Int(weight.byteCount)
		let values = weights[start..<end]
		return CoreMLProtobufEncoder.message { parameters in
			switch weight.dataType {
			case .float16:
				CoreMLProtobufEncoder.appendMessageField(2, value: Data(values), to: &parameters)
			case .float32:
				CoreMLProtobufEncoder.appendMessageField(1, value: Data(values), to: &parameters)
			case .unsupported:
				preconditionFailure("The graph validator rejects unsupported data types before emission.")
			}
		}
	}

	private func weight(named name: String, in weightsByName: [String: NativeModelWeight]) throws -> NativeModelWeight {
		guard let weight = weightsByName[name] else {
			throw NativeModelCoreMLEmissionError.missingWeight(name)
		}
		return weight
	}

	private func integerArrayAttribute(_ name: String, for operation: NativeModelOperation, count: Int) throws -> [Int] {
		guard let value = operation.attributes[name]?.integerArrayValue, value.count == count, value.allSatisfy({ $0 >= 0 }) else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "attribute '\(name)' must contain \(count) non-negative integers"
			)
		}
		return value
	}

	/// Reads the `padding` attribute in either accepted form: symmetric `[padH, padW]` or per-edge
	/// `[top, left, bottom, right]`.
	private func paddingAttribute(for operation: NativeModelOperation) throws -> [Int] {
		guard let value = operation.attributes["padding"]?.integerArrayValue,
			value.count == 2 || value.count == 4,
			value.allSatisfy({ $0 >= 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "attribute 'padding' must contain 2 or 4 non-negative integers"
			)
		}
		return value
	}

	private func integerAttribute(_ name: String, for operation: NativeModelOperation) throws -> Int {
		guard let value = operation.attributes[name]?.integerValue else {
			throw NativeModelCoreMLEmissionError.invalidConvolution(
				operation: operation.name,
				reason: "attribute '\(name)' must be an integer"
			)
		}
		return value
	}

	private func coreMLArrayDataType(for dataType: NativeModelDataType) -> UInt64 {
		switch dataType {
		case .float16: 65_552
		case .float32: 65_568
		case .unsupported:
			preconditionFailure("The graph validator rejects unsupported data types before emission.")
		}
	}
}

private struct NativeModelTargetInterface: Encodable {
	let inputs: [NativeModelTensor]
	let outputs: [NativeModelTensor]
}

public enum NativeModelCoreMLEmissionError: Error, Equatable, LocalizedError, Sendable {
	case invalidGraph([NativeModelGraphValidationIssue])
	case unsupportedOperation(operation: String, kind: String)
	case missingOutputTensor(String)
	case missingWeight(String)
	case weightDataOutOfBounds(name: String, offset: UInt64, byteCount: UInt64, availableByteCount: UInt64)
	case invalidConvolution(operation: String, reason: String)
	case invalidOperation(operation: String, reason: String)
	case invalidDetectionInterface(reason: String)
	case invalidArtifactSet(reason: String)
	case outputFileSizeUnavailable(String)

	public var errorDescription: String? {
		switch self {
		case .invalidGraph(let issues):
			"The native graph is invalid: \(issues.map(\.localizedDescription).joined(separator: "; "))"
		case .unsupportedOperation(let operation, let kind):
			"The current Core ML emitter does not support operation '\(operation)' of kind '\(kind)'."
		case .missingOutputTensor(let name):
			"The native graph declares output '\(name)' but no tensor defines it."
		case .missingWeight(let name):
			"The graph references weight '\(name)' but does not declare it."
		case .weightDataOutOfBounds(let name, let offset, let byteCount, let availableByteCount):
			// Phrased to avoid computing `offset + byteCount`, which can overflow UInt64 for a
			// malformed weight and would trap while rendering this diagnostic.
			"Weight '\(name)' needs \(byteCount) bytes at offset \(offset); weights.bin has \(availableByteCount)."
		case .invalidConvolution(let operation, let reason):
			"Convolution '\(operation)' is invalid: \(reason)."
		case .invalidOperation(let operation, let reason):
			"Operation '\(operation)' is invalid: \(reason)."
		case .invalidDetectionInterface(let reason):
			"The detection interface is invalid: \(reason)."
		case .invalidArtifactSet(let reason):
			"The emitted artifact set is invalid: \(reason)."
		case .outputFileSizeUnavailable(let file):
			"The emitted model '\(file)' could not be measured."
		}
	}
}
