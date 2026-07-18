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
		let progress: NativeModelConversionProgressHandler?
		let cancellationCheck: NativeModelConversionCancellationHandler?

		init(
			metadata: NativeModelCoreMLMetadata?,
			classifierLabels: [String]? = nil,
			imagePreprocessing: NativeModelImagePreprocessing? = nil,
			progress: NativeModelConversionProgressHandler?,
			cancellationCheck: NativeModelConversionCancellationHandler?
		) {
			self.metadata = metadata
			self.classifierLabels = classifierLabels
			self.imagePreprocessing = imagePreprocessing
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
			manifest: package.manifest,
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
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws {
		let eligibleLabels = eligibleClassifierLabels(graph: graph, labels: classifierLabels)
		try emit(
			graph: graph,
			weights: weights,
			to: outputURL,
			context: EmissionContext(
				metadata: nil,
				classifierLabels: eligibleLabels,
				imagePreprocessing: eligibleLabels == nil ? nil : imagePreprocessing,
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
		let classifier = classifierPlan(outputs: outputTensors, operations: operations, labels: context.classifierLabels)
		let imagePlan = imageInputPlan(
			inputTensors: inputTensors,
			classifier: classifier,
			preprocessing: context.imagePreprocessing
		)

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
			let layer = try layer(for: operation, weightsByName: weightsByName, weights: weights)
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
		if let classifier {
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
		}

		let description = CoreMLProtobufEncoder.message { description in
			for input in inputTensors {
				if let imagePlan, input.name == imagePlan.networkInputName {
					CoreMLProtobufEncoder.appendMessageField(1, value: imageFeatureDescription(for: imagePlan), to: &description)
				} else {
					CoreMLProtobufEncoder.appendMessageField(1, value: featureDescription(for: input), to: &description)
				}
			}
			if let classifier {
				CoreMLProtobufEncoder.appendMessageField(10, value: stringFeatureDescription(named: classifier.classLabelName), to: &description)
				CoreMLProtobufEncoder.appendMessageField(10, value: probabilitiesFeatureDescription(named: classifier.classLabelProbsName), to: &description)
				CoreMLProtobufEncoder.appendStringField(11, value: classifier.classLabelName, to: &description)
				CoreMLProtobufEncoder.appendStringField(12, value: classifier.classLabelProbsName, to: &description)
			} else {
				for output in outputTensors {
					CoreMLProtobufEncoder.appendMessageField(10, value: featureDescription(for: output), to: &description)
				}
			}
			if let metadata {
				CoreMLProtobufEncoder.appendMessageField(100, value: coreMLMetadataMessage(for: metadata), to: &description)
			}
		}

		let network = CoreMLProtobufEncoder.message { network in
			network.append(layers)
			CoreMLProtobufEncoder.appendVarintField(5, value: 1, to: &network)
			// Image inputs must use RANK4_IMAGE_MAPPING to match EXACT_ARRAY_MAPPING above: under the
			// legacy rank-5 mapping the image enters as [1, 1, C, H, W], shifting every axis the reader
			// computed — an in-graph softmax over "axis 1" then normalizes the size-1 batch dim and
			// produces a constant all-ones vector instead of probabilities.
			if imagePlan != nil {
				CoreMLProtobufEncoder.appendVarintField(6, value: 1, to: &network)
			}
			if let classifier {
				CoreMLProtobufEncoder.appendMessageField(100, value: stringVector(classifier.labels), to: &network)
				CoreMLProtobufEncoder.appendStringField(200, value: classifier.probabilitiesBlobName, to: &network)
			}
		}

		return CoreMLProtobufEncoder.message { model in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(specificationVersion), to: &model)
			CoreMLProtobufEncoder.appendMessageField(2, value: description, to: &model)
			CoreMLProtobufEncoder.appendMessageField(classifier == nil ? 500 : 403, value: network, to: &model)
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
		guard shape.count >= 2, shape[0] == 1,
			shape.filter({ $0 != 1 }).count == 1,
			let classAxis = shape.firstIndex(where: { $0 != 1 }),
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

	private func targetMetadata(
		from source: NativeModelCoreMLMetadata?,
		manifest: NativeModelGraphPackageManifest,
		graph: NativeModelGraph,
		sourceProvenance: NativeModelConversionSourceProvenance?,
		classifierLabelCount: Int? = nil
	) throws -> NativeModelCoreMLMetadata {
		var userDefined: [String: String] = [
			// A classifier interface is emitted only when labels match the output; the format then
			// reflects what was actually written and is safe to state as a target fact.
			"com.aiarcheology.native.target.model-format": classifierLabelCount == nil ? "neuralNetwork" : "neuralNetworkClassifier",
			"com.aiarcheology.native.target.graph-format-version": String(graph.formatVersion),
			"com.aiarcheology.native.converter.package-version": NativeModelConverterVersion.packageVersion,
			"com.aiarcheology.native.converter.conversion-revision": String(NativeModelConverterVersion.conversionRevision),
			"com.aiarcheology.native.conversion.weights-sha256": manifest.weightsSHA256,
			"com.aiarcheology.native.conversion.producer.name": graph.producer.name,
			"com.aiarcheology.native.conversion.producer.version": graph.producer.version,
			"com.aiarcheology.native.target.interface.json": try targetInterfaceJSON(
				inputs: graph.inputs,
				outputs: graph.outputs,
				graph: graph
			)
		]
		if let graphSHA256 = manifest.graphSHA256 {
			userDefined["com.aiarcheology.native.conversion.graph-sha256"] = graphSHA256
		}
		if let metadataChecksum = manifest.metadataSHA256 {
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
		weights: Data
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
			try softmaxLayer(for: operation)
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

	/// Derives an image-input plan when the graph is a classifier whose single input is `[1, C, H, W]`
	/// with the channel count `preprocessing` expects and concrete spatial dimensions. Returns nil
	/// otherwise, so a non-image or non-classifier graph keeps its plain multi-array input.
	private func imageInputPlan(
		inputTensors: [NativeModelTensor],
		classifier: ClassifierPlan?,
		preprocessing: NativeModelImagePreprocessing?
	) -> ImageInputPlan? {
		guard classifier != nil, let preprocessing, inputTensors.count == 1 else { return nil }
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
		let padding = try integerArrayAttribute("padding", for: operation, count: 2)
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
			let padding = operation.attributes["padding"]?.integerArrayValue, padding.count == 2,
			(kernelSize + strides).allSatisfy({ $0 > 0 }), padding.allSatisfy({ $0 >= 0 })
		else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "maxPool2d requires kernelSize/strides pairs of positive integers and a non-negative padding pair"
			)
		}
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

	private func softmaxLayer(for operation: NativeModelOperation) throws -> Data {
		try requireSingleActivationInput(operation)
		guard let axis = operation.attributes["axis"]?.integerValue, axis >= 0 else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: operation.name,
				reason: "softmax requires a non-negative axis (the reader normalizes negative axes)"
			)
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

	private func validPadding(_ padding: [Int]) -> Data {
		let borderAmounts = CoreMLProtobufEncoder.message { borderAmounts in
			for amount in padding {
				let edgeSizes = CoreMLProtobufEncoder.message { edgeSizes in
					CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(amount), to: &edgeSizes)
					CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(amount), to: &edgeSizes)
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
		case .outputFileSizeUnavailable(let file):
			"The emitted model '\(file)' could not be measured."
		}
	}
}
