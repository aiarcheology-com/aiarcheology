//
//  NativeModelCoreMLEmitter.swift
//  NativeModelConverter
//
//  Emits a Core ML neural-network protobuf from a validated native graph.
//

import Foundation

/// Serializes the currently implemented native-graph subset as a Core ML neural-network model.
///
/// The emitter intentionally has a narrower operation set than `NativeModelGraphValidator`.
/// Validation answers whether a graph belongs to the version 1 interchange contract; this type
/// answers whether the installed native emitter can faithfully serialize it today. Unsupported
/// operations fail explicitly, which prevents a partially converted model from reaching Core ML.
public struct NativeModelCoreMLEmitter: Sendable {
	private struct EmissionContext {
		let metadata: NativeModelCoreMLMetadata?
		/// Ordered class labels from the source package. When they match the single graph output's
		/// width, the emitter wraps the logits as a Core ML classifier; otherwise they are ignored.
		let classifierLabels: [String]?
		/// When present and the single input is image-shaped, the emitter declares that input as a Core
		/// ML image feature and prepends a per-channel normalization layer. Ignored otherwise.
		let imagePreprocessing: NativeModelImagePreprocessing?
		/// When present, the graph is emitted as a two-stage detector pipeline (network + NMS)
		/// instead of a single model. Mutually exclusive with `classifierLabels`.
		let detection: NativeModelDetectionInterface?
		let progress: NativeModelConversionProgressHandler?
		let cancellationCheck: NativeModelConversionCancellationHandler?

		init(
			metadata: NativeModelCoreMLMetadata?,
			classifierLabels: [String]? = nil,
			imagePreprocessing: NativeModelImagePreprocessing? = nil,
			detection: NativeModelDetectionInterface? = nil,
			progress: NativeModelConversionProgressHandler?,
			cancellationCheck: NativeModelConversionCancellationHandler?
		) {
			self.metadata = metadata
			self.classifierLabels = classifierLabels
			self.imagePreprocessing = imagePreprocessing
			self.detection = detection
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
	@discardableResult
	public func emit(
		package: NativeModelGraphPackage,
		to outputURL: URL,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws -> NativeModelEmissionMetrics {
		let emissionStartedAt = DispatchTime.now().uptimeNanoseconds
		try cancellationCheck?()
		let classifierLabels = eligibleClassifierLabels(graph: package.graph, labels: package.metadata?.labels)
		let metadata = try targetMetadata(
			from: package.metadata?.source,
			checksums: NativeModelConversionChecksums(
				weightsSHA256: package.manifest.weightsSHA256,
				graphSHA256: package.manifest.graphSHA256,
				metadataSHA256: package.manifest.metadataSHA256
			),
			graph: package.graph,
			sourceProvenance: sourceProvenance,
			classifierLabelCount: classifierLabels?.count
		)
		try emit(
			graph: package.graph,
			weights: package.weights,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				classifierLabels: classifierLabels,
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
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(metadata: nil, progress: nil, cancellationCheck: nil)
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
		sourceMetadata: NativeModelCoreMLMetadata? = nil,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws {
		let eligibleLabels = eligibleClassifierLabels(graph: graph, labels: classifierLabels)
		// Hash the exact blob being emitted for correct provenance. On this path that is `weights`.
		let metadata = try onnxTargetMetadata(
			source: sourceMetadata,
			sourceProvenance: sourceProvenance,
			graph: graph,
			emittedWeights: weights,
			classifierLabelCount: eligibleLabels?.count
		)
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				classifierLabels: eligibleLabels,
				imagePreprocessing: eligibleLabels == nil ? nil : imagePreprocessing,
				progress: progress,
				cancellationCheck: cancellationCheck
			)
		)
	}

	/// Emits a graph as a Core ML detector: a two-stage pipeline whose first stage is the converted
	/// network and whose second is Core ML's non-maximum-suppression model. The resulting model
	/// publishes `coordinates`/`confidence`, which is what makes Vision return
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
		sourceMetadata: NativeModelCoreMLMetadata? = nil,
		sourceProvenance: NativeModelConversionSourceProvenance? = nil,
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
		// `weights` here is the detector blob (network weights + synthesized decode constants), which
		// is exactly what gets emitted — so hashing it yields a truthful weights-sha256 for the
		// pipeline model. makeModel attaches this metadata to the OUTER pipeline description.
		let metadata = try onnxTargetMetadata(
			source: sourceMetadata,
			sourceProvenance: sourceProvenance,
			graph: graph,
			emittedWeights: weights,
			classifierLabelCount: nil,
			detection: detectionTarget
		)
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(
				metadata: metadata,
				imagePreprocessing: imagePreprocessing,
				detection: detection,
				progress: progress,
				cancellationCheck: cancellationCheck
			)
		)
	}

	private func emit(
		graph: NativeModelGraph,
		weights: Data,
		to outputURL: URL,
		context: EmissionContext
	) throws {
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

		let model = try makeModel(
			input: ModelBuildInput(
				inputTensors: graph.inputs,
				outputTensors: outputTensors,
				operations: graph.operations,
				weightsByName: weightsByName,
				weights: weights
			),
			context: context
		)
		try context.cancellationCheck?()
		context.progress?(NativeModelConversionProgress(phase: .writingModel))
		try model.write(to: outputURL, options: .atomic)
		context.progress?(NativeModelConversionProgress(phase: .writingModel, completedUnitCount: 1, totalUnitCount: 1))
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

	private func makeModel(
		input: ModelBuildInput,
		context: EmissionContext
	) throws -> Data {
		let inputTensors = input.inputTensors
		let outputTensors = input.outputTensors
		let operations = input.operations
		let weightsByName = input.weightsByName
		let weights = input.weights
		let metadata = context.metadata
		let progress = context.progress
		let cancellationCheck = context.cancellationCheck
		let specificationVersion = (inputTensors + outputTensors).contains { $0.dataType == .float16 } ? 7 : 4
		let classifier = context.detection == nil
			? classifierPlan(outputs: outputTensors, operations: operations, labels: context.classifierLabels)
			: nil
		let imagePlan = imageInputPlan(
			inputTensors: inputTensors,
			declaresImageInterface: classifier != nil || context.detection != nil,
			preprocessing: context.imagePreprocessing
		)

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

		let detection = context.detection
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

		// The detector is the network followed by suppression. The outer description republishes the
		// network's inputs, adds the two optional threshold inputs, and declares the suppressed
		// outputs — whose row count is data-dependent and therefore a range, not a fixed size.
		let pipelineDescription = CoreMLProtobufEncoder.message { pipelineDescription in
			pipelineDescription.append(inputFeatures)
			CoreMLProtobufEncoder.appendMessageField(1, value: NativeModelDetectorPipelineBuilder.doubleFeature(
				named: NativeModelDetectionInterface.iouThresholdInputName, isOptional: true
			), to: &pipelineDescription)
			CoreMLProtobufEncoder.appendMessageField(1, value: NativeModelDetectorPipelineBuilder.doubleFeature(
				named: NativeModelDetectionInterface.confidenceThresholdInputName, isOptional: true
			), to: &pipelineDescription)
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

	private struct ClassifierPlan {
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
		classifierLabelCount: Int?,
		detection: NativeModelDetectionTargetInfo? = nil
	) throws -> NativeModelCoreMLMetadata {
		try targetMetadata(
			from: source,
			checksums: NativeModelConversionChecksums(
				weightsSHA256: NativeModelConversionChecksums.sha256Hex(of: emittedWeights)
			),
			graph: graph,
			sourceProvenance: sourceProvenance,
			classifierLabelCount: classifierLabelCount,
			detection: detection
		)
	}

	private func targetMetadata(
		from source: NativeModelCoreMLMetadata?,
		checksums: NativeModelConversionChecksums,
		graph: NativeModelGraph,
		sourceProvenance: NativeModelConversionSourceProvenance?,
		classifierLabelCount: Int? = nil,
		detection: NativeModelDetectionTargetInfo? = nil
	) throws -> NativeModelCoreMLMetadata {
		// A detector is emitted as a Core ML pipeline (network + NMS); a classifier interface is only
		// emitted when labels match the output. The format string reflects what was actually written.
		let modelFormat: String
		if detection != nil {
			modelFormat = "pipeline"
		} else {
			modelFormat = classifierLabelCount == nil ? "neuralNetwork" : "neuralNetworkClassifier"
		}
		var userDefined: [String: String] = [
			"com.aiarcheology.native.target.model-format": modelFormat,
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
			)
		]
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
		if let classifierLabelCount {
			userDefined["com.aiarcheology.native.target.task"] = "classification"
			userDefined["com.aiarcheology.native.target.class-count"] = String(classifierLabelCount)
		}
		if let detection {
			// The facts AIA-0471's import UI reads to decide whether the labels are trustworthy or
			// inferred, and how the coordinates were normalized.
			userDefined["com.aiarcheology.native.target.task"] = "detection"
			userDefined["com.aiarcheology.native.target.class-count"] = String(detection.classCount)
			userDefined["com.aiarcheology.native.target.label-provenance"] = detection.labelProvenanceValue
			userDefined["com.aiarcheology.native.target.coordinate-space"] = detection.coordinateSpaceValue
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
		case .maxPool2D:
			try maxPoolLayer(for: operation)
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
			.reshapeND, .transposeND, .sliceND, .splitND, .batchedMatrixMultiplicationND:
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

	private struct ImageInputPlan {
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

	private func maxPoolLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let kernelSize = operation.attributes["kernelSize"]?.integerArrayValue, kernelSize.count == 2,
			let strides = operation.attributes["strides"]?.integerArrayValue, strides.count == 2,
			(kernelSize + strides).allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "maxPool2d requires kernelSize/strides pairs of positive integers"
			)
		}
		let padding = try paddingAttribute(for: operation)
		let pooling = CoreMLProtobufEncoder.message { pooling in
			// PoolingLayerParams.type MAX is the proto3 default (0), so no explicit type field is written.
			for dimension in kernelSize {
				CoreMLProtobufEncoder.appendVarintField(10, value: UInt64(dimension), to: &pooling)
			}
			for stride in strides {
				CoreMLProtobufEncoder.appendVarintField(20, value: UInt64(stride), to: &pooling)
			}
			CoreMLProtobufEncoder.appendMessageField(30, value: validPadding(padding), to: &pooling)
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
	/// operator table stays inside the cyclomatic-complexity limit.
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
		default:
			throw NativeModelCoreMLEmissionError.unsupportedOperation(
				operation: operation.name,
				kind: operation.kind.serializedValue
			)
		}
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
			!beginIds.isEmpty, beginIds.allSatisfy({ $0 >= 0 }), endIds.allSatisfy({ $0 >= 0 }), strides.allSatisfy({ $0 > 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "sliceND requires equal-length non-negative begin/end and positive stride lists"
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
		case .outputFileSizeUnavailable(let file):
			"The emitted model '\(file)' could not be measured."
		}
	}
}
