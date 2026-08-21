//
//  NativeModelFasterRCNNRegistry.swift
//  NativeModelConverter
//
//  The pinned ADAF Faster R-CNN architecture and its first loadable Core ML graph (AIA-0685).
//

import Foundation

/// The only Faster R-CNN architecture this converter currently lowers.
///
/// The checkpoint reader establishes that an ADAF file has the published tensor table; this registry
/// establishes what those tensors *mean*. Neither step infers a network from arbitrary PyTorch module
/// names. The architecture, every expected parameter shape, the input canvas, and the fixed proposal
/// budget are named here so a future checkpoint with a superficially similar table cannot silently
/// select a different graph.
public enum NativeModelFasterRCNNRegistry {

	/// The immutable choices that define the graph family.
	public struct Architecture: Equatable, Sendable {
		public let identifier: String
		public let canvas: NativeModelImageSize
		public let proposalCount: Int
		public let predictorLogitCount: Int
		public let fpnChannels: Int
		public let anchorSizes: [Int]
		public let anchorAspectRatios: [Double]

		fileprivate init(
			identifier: String,
			canvas: NativeModelImageSize,
			proposalCount: Int,
			predictorLogitCount: Int,
			fpnChannels: Int,
			anchorSizes: [Int],
			anchorAspectRatios: [Double]
		) {
			self.identifier = identifier
			self.canvas = canvas
			self.proposalCount = proposalCount
			self.predictorLogitCount = predictorLogitCount
			self.fpnChannels = fpnChannels
			self.anchorSizes = anchorSizes
			self.anchorAspectRatios = anchorAspectRatios
		}
	}

	/// `1344 × 1344` is deliberate. The host still sizes image *content* with torchvision's
	/// `800/1333` rule; this is the fixed padded canvas into which that content is placed. A 1333
	/// square would preserve the long-side number but gives FPN levels `334 → 167 → 84 → 42`, where
	/// the required top-down `×2` upsample cannot join the 167-wide lateral feature. 1344 is the
	/// transform's stride-rounded upper edge, keeps the emitted `336 → 168 → 84 → 42` levels exact,
	/// and accepts every page aspect rather than baking one device's aspect ratio into the model. It
	/// does choose a square anchor grid instead of torchvision's variable `1344 × N` grid; that is a
	/// known numerical question for AIA-0688, not a parity claim made by this loadability slice.
	public static let architecture = Architecture(
		identifier: "fasterrcnn_resnet50_fpn_v2",
		canvas: NativeModelImageSize(width: 1344, height: 1344),
		proposalCount: 1_000,
		predictorLogitCount: 2,
		fpnChannels: 256,
		anchorSizes: [32, 64, 128, 256, 512],
		anchorAspectRatios: [0.5, 1, 2]
	)

	/// A graph template before its source and synthesized blobs are joined.
	public struct Template: Sendable {
		public let graph: NativeModelGraph
		public let interface: NativeModelDetectionInterface
		public let targetInfo: NativeModelDetectionTargetInfo
		public let targetSemanticsIntent: NativeModelTargetSemanticsIntent
		public let synthesizedWeightData: Data
		public let sourceWeightByteCount: UInt64
	}

	/// A graph together with the exact blob the Core ML emitter addresses.
	public struct Conversion: Sendable {
		public let graph: NativeModelGraph
		public let weights: Data
		public let interface: NativeModelDetectionInterface
		public let targetInfo: NativeModelDetectionTargetInfo
		public let targetSemanticsIntent: NativeModelTargetSemanticsIntent
	}

	/// Builds the graph skeleton from the closed architecture registry.
	///
	/// This slice deliberately stops after a fixed RPN proposal selection. It is enough to prove the
	/// actual image → ResNet-50 → FPN → RPN graph, detector pipeline, and checkpoint weights compile
	/// and load. It is not a numerical claim: AIA-0686 replaces this provisional anchor-only proposal
	/// path with decoded boxes and both terminal suppression passes; AIA-0687 adds the edge and
	/// empty-result corrections; AIA-0688 is where a reference oracle may change parity provenance.
	public static func template(
		for model: ADAFObjectDetectionModel,
		weights: [NativeModelWeight]
	) throws -> Template {
		guard model.architecture == architecture.identifier,
			model.predictorLogitCount == architecture.predictorLogitCount
		else {
			throw NativeModelFasterRCNNRegistryError.unsupportedModel(
				architecture: model.architecture,
				predictorLogitCount: model.predictorLogitCount
			)
		}

		let sourceWeightByteCount = try validateSourceWeights(weights)
		let label = model.classLabel?.displayName ?? "Object"
		let labelProvenance: NativeModelDetectorCatalog.DetectorLabelProvenance =
			model.labelProvenance == .checkpointIdentifier ? .metadata : .unnamed
		let targetSemantics = NativeModelTargetSemanticsIntent(
			labelProfile: model.labelProvenance == .checkpointIdentifier ? .sourceMetadata : .genericClassIndex,
			preprocessingProfile: .imageNetRGB
		)

		var builder = GraphBuilder(
			sourceWeights: try weightsByName(weights),
			sourceWeightByteCount: sourceWeightByteCount
		)
		let graph = try builder.makeGraph()
		let interface = NativeModelDetectionInterface(
			labels: [label],
			boxCount: architecture.proposalCount,
			coordinatesBlobName: GraphBuilder.coordinatesOutput,
			confidenceBlobName: GraphBuilder.confidenceOutput,
			iouThreshold: 0.5,
			confidenceThreshold: 0.5
		)
		return Template(
			graph: graph,
			interface: interface,
			targetInfo: NativeModelDetectionTargetInfo(
				classCount: interface.labels.count,
				labelProvenance: labelProvenance,
				coordinateMode: .normalizedByGraph
			),
			targetSemanticsIntent: targetSemantics,
			synthesizedWeightData: builder.synthesizedWeightData,
			sourceWeightByteCount: sourceWeightByteCount
		)
	}

	/// Joins a real extracted checkpoint blob to its template.
	///
	/// The checkpoint identity is checked again here because this is the public entry point that makes
	/// an emit-ready graph. A caller cannot pass a tensor list that merely looks similar and receive a
	/// detector whose structure belongs to a different checkpoint family.
	public static func conversion(
		checkpoint: PyTorchCheckpoint,
		extraction: PyTorchWeightExtraction,
		weightData: Data
	) throws -> Conversion {
		guard case let .objectDetection(model) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			throw NativeModelFasterRCNNRegistryError.checkpointIsNotPinnedDetector
		}
		let template = try template(for: model, weights: extraction.weights)
		guard extraction.byteCount == template.sourceWeightByteCount,
			UInt64(weightData.count) == template.sourceWeightByteCount
		else {
			throw NativeModelFasterRCNNRegistryError.weightDataLengthMismatch(
				expected: template.sourceWeightByteCount,
				actual: UInt64(weightData.count)
			)
		}
		var combined = weightData
		combined.append(template.synthesizedWeightData)
		return Conversion(
			graph: template.graph,
			weights: combined,
			interface: template.interface,
			targetInfo: template.targetInfo,
			targetSemanticsIntent: template.targetSemanticsIntent
		)
	}

	// MARK: - Registry validation

	private struct ExpectedWeight: Equatable {
		let name: String
		let shape: [Int]
	}

	private static func validateSourceWeights(_ weights: [NativeModelWeight]) throws -> UInt64 {
		let expected = expectedWeights()
		let actualByName = try weightsByName(weights)
		let expectedNames = Set(expected.map(\.name))
		let actualNames = Set(actualByName.keys)
		guard expectedNames == actualNames else {
			throw NativeModelFasterRCNNRegistryError.weightNamesMismatch(
				missing: expectedNames.subtracting(actualNames).sorted(),
				unexpected: actualNames.subtracting(expectedNames).sorted()
			)
		}

		for expectedWeight in expected {
			guard let actual = actualByName[expectedWeight.name] else {
				preconditionFailure("The equality check above guarantees every expected weight is present.")
			}
			let expectedByteCount = UInt64(expectedWeight.shape.reduce(1, *)) * 2
			guard actual.dataType == .float16,
				actual.shape == expectedWeight.shape,
				actual.byteCount == expectedByteCount
			else {
				throw NativeModelFasterRCNNRegistryError.invalidWeight(
					name: expectedWeight.name,
					expectedShape: expectedWeight.shape,
					actualShape: actual.shape,
					actualType: actual.dataType.serializedValue,
					actualByteCount: actual.byteCount
				)
			}
		}

		let ordered = weights.sorted { $0.offset < $1.offset }
		var cursor: UInt64 = 0
		for weight in ordered {
			guard weight.offset == cursor else {
				throw NativeModelFasterRCNNRegistryError.weightBlobIsNotContiguous(weight: weight.name)
			}
			let (next, overflow) = cursor.addingReportingOverflow(weight.byteCount)
			guard overflow == false else {
				throw NativeModelFasterRCNNRegistryError.weightBlobIsNotContiguous(weight: weight.name)
			}
			cursor = next
		}
		return cursor
	}

	private static func weightsByName(_ weights: [NativeModelWeight]) throws -> [String: NativeModelWeight] {
		var result: [String: NativeModelWeight] = [:]
		for weight in weights {
			guard result.updateValue(weight, forKey: weight.name) == nil else {
				throw NativeModelFasterRCNNRegistryError.duplicateWeightName
			}
		}
		return result
	}

	private static func expectedWeights() -> [ExpectedWeight] {
		var result: [ExpectedWeight] = []
		func convolution(_ name: String, output: Int, input: Int, kernel: Int, hasBias: Bool = false) {
			result.append(ExpectedWeight(name: "\(name).weight", shape: [output, input, kernel, kernel]))
			if hasBias { result.append(ExpectedWeight(name: "\(name).bias", shape: [output])) }
		}
		func batchNorm(_ name: String, channels: Int) {
			for suffix in ["weight", "bias", "running_mean", "running_var"] {
				result.append(ExpectedWeight(name: "\(name).\(suffix)", shape: [channels]))
			}
		}

		convolution("backbone.body.conv1", output: 64, input: 3, kernel: 7)
		batchNorm("backbone.body.bn1", channels: 64)

		let blocks = [3, 4, 6, 3]
		var inputChannels = 64
		for (stageIndex, blockCount) in blocks.enumerated() {
			let planes = 64 << stageIndex
			let outputChannels = planes * 4
			for block in 0..<blockCount {
				let prefix = "backbone.body.layer\(stageIndex + 1).\(block)"
				convolution("\(prefix).conv1", output: planes, input: inputChannels, kernel: 1)
				batchNorm("\(prefix).bn1", channels: planes)
				convolution("\(prefix).conv2", output: planes, input: planes, kernel: 3)
				batchNorm("\(prefix).bn2", channels: planes)
				convolution("\(prefix).conv3", output: outputChannels, input: planes, kernel: 1)
				batchNorm("\(prefix).bn3", channels: outputChannels)
				if block == 0 {
					convolution("\(prefix).downsample.0", output: outputChannels, input: inputChannels, kernel: 1)
					batchNorm("\(prefix).downsample.1", channels: outputChannels)
				}
				inputChannels = outputChannels
			}
		}

		for (index, input) in [256, 512, 1_024, 2_048].enumerated() {
			convolution("backbone.fpn.inner_blocks.\(index).0", output: architecture.fpnChannels, input: input, kernel: 1)
			batchNorm("backbone.fpn.inner_blocks.\(index).1", channels: architecture.fpnChannels)
			convolution("backbone.fpn.layer_blocks.\(index).0", output: architecture.fpnChannels, input: architecture.fpnChannels, kernel: 3)
			batchNorm("backbone.fpn.layer_blocks.\(index).1", channels: architecture.fpnChannels)
		}

		for index in 0..<2 {
			convolution("rpn.head.conv.\(index).0", output: architecture.fpnChannels, input: architecture.fpnChannels, kernel: 3, hasBias: true)
		}
		convolution("rpn.head.cls_logits", output: architecture.anchorAspectRatios.count, input: architecture.fpnChannels, kernel: 1, hasBias: true)
		convolution("rpn.head.bbox_pred", output: architecture.anchorAspectRatios.count * 4, input: architecture.fpnChannels, kernel: 1, hasBias: true)

		for index in 0..<4 {
			convolution("roi_heads.box_head.\(index).0", output: architecture.fpnChannels, input: architecture.fpnChannels, kernel: 3)
			batchNorm("roi_heads.box_head.\(index).1", channels: architecture.fpnChannels)
		}
		result.append(ExpectedWeight(name: "roi_heads.box_head.5.weight", shape: [1_024, 12_544]))
		result.append(ExpectedWeight(name: "roi_heads.box_head.5.bias", shape: [1_024]))
		result.append(ExpectedWeight(name: "roi_heads.box_predictor.cls_score.weight", shape: [2, 1_024]))
		result.append(ExpectedWeight(name: "roi_heads.box_predictor.cls_score.bias", shape: [2]))
		result.append(ExpectedWeight(name: "roi_heads.box_predictor.bbox_pred.weight", shape: [8, 1_024]))
		result.append(ExpectedWeight(name: "roi_heads.box_predictor.bbox_pred.bias", shape: [8]))
		return result
	}

	// MARK: - Graph construction

	private struct Activation {
		let name: String
		let channels: Int
		let height: Int
		let width: Int
	}

	private struct GraphBuilder {
		static let coordinatesOutput = "frcnn_raw_coordinates"
		static let confidenceOutput = "frcnn_raw_confidence"

		let sourceWeights: [String: NativeModelWeight]
		let sourceWeightByteCount: UInt64
		var operations: [NativeModelOperation] = []
		var synthesizedWeights: [NativeModelWeight] = []
		var synthesizedWeightData = Data()

		mutating func makeGraph() throws -> NativeModelGraph {
			let canvas = NativeModelFasterRCNNRegistry.architecture.canvas
			let image = Activation(name: "image", channels: 3, height: canvas.height, width: canvas.width)
			let c2ToC5 = try resNetFeatures(from: image)
			let fpn = try fpnFeatures(from: c2ToC5)
			let rpnLogits = try rpnLogits(for: fpn)
			let candidateScores = try proposalScores(from: rpnLogits)
			let anchors = try anchors(for: fpn)
			let proposal = try selectProvisionalProposals(scores: candidateScores, anchors: anchors)

			return NativeModelGraph(
				formatVersion: NativeModelGraph.exactNDFormatVersion,
				producer: NativeModelGraphProducer(name: "aiarcheology-adaf-fasterrcnn", version: "1"),
				inputs: [NativeModelTensor(name: image.name, dataType: .float32, shape: [1, image.channels, image.height, image.width])],
				weights: sourceWeights.values.sorted { $0.offset < $1.offset } + synthesizedWeights,
				operations: operations,
				outputs: [proposal.coordinates, proposal.confidence]
			)
		}

		mutating func resNetFeatures(from image: Activation) throws -> [Activation] {
			var current = try convolution(
				image, module: "backbone.body.conv1", output: "frcnn.backbone.stem.conv", outputChannels: 64,
				kernel: 7, stride: 2, padding: 3
			)
			current = try batchNorm(current, module: "backbone.body.bn1", output: "frcnn.backbone.stem.bn")
			current = relu(current, output: "frcnn.backbone.stem.relu")
			current = pool(current, output: "frcnn.backbone.stem.pool", kernel: 3, stride: 2, padding: 1)

			let blocks = [3, 4, 6, 3]
			var features: [Activation] = []
			for (stageIndex, blockCount) in blocks.enumerated() {
				let planes = 64 << stageIndex
				let stride = stageIndex == 0 ? 1 : 2
				for block in 0..<blockCount {
					let prefix = "backbone.body.layer\(stageIndex + 1).\(block)"
					let blockStride = block == 0 ? stride : 1
					let residual = current
					var path = try convolution(
						current, module: "\(prefix).conv1", output: "frcnn.\(prefix).conv1", outputChannels: planes,
						kernel: 1, stride: 1, padding: 0
					)
					path = try batchNorm(path, module: "\(prefix).bn1", output: "frcnn.\(prefix).bn1")
					path = relu(path, output: "frcnn.\(prefix).relu1")
					path = try convolution(
						path, module: "\(prefix).conv2", output: "frcnn.\(prefix).conv2", outputChannels: planes,
						kernel: 3, stride: blockStride, padding: 1
					)
					path = try batchNorm(path, module: "\(prefix).bn2", output: "frcnn.\(prefix).bn2")
					path = relu(path, output: "frcnn.\(prefix).relu2")
					path = try convolution(
						path, module: "\(prefix).conv3", output: "frcnn.\(prefix).conv3", outputChannels: planes * 4,
						kernel: 1, stride: 1, padding: 0
					)
					path = try batchNorm(path, module: "\(prefix).bn3", output: "frcnn.\(prefix).bn3")

					let shortcut: Activation
					if block == 0 {
						var projected = try convolution(
							residual, module: "\(prefix).downsample.0", output: "frcnn.\(prefix).downsample.conv",
							outputChannels: planes * 4, kernel: 1, stride: blockStride, padding: 0
						)
						projected = try batchNorm(projected, module: "\(prefix).downsample.1", output: "frcnn.\(prefix).downsample.bn")
						shortcut = projected
					} else {
						shortcut = residual
					}
					current = relu(add(path, shortcut, output: "frcnn.\(prefix).out"), output: "frcnn.\(prefix).relu3")
				}
				features.append(current)
			}
			return features
		}

		mutating func fpnFeatures(from c2ToC5: [Activation]) throws -> [Activation] {
			guard c2ToC5.count == 4 else { preconditionFailure("ResNet-50 always has four FPN source levels.") }
			var inner = try fpnBlock(c2ToC5[3], module: "backbone.fpn.inner_blocks.3", output: "frcnn.fpn.inner5", kernel: 1)
			var output = try fpnBlock(inner, module: "backbone.fpn.layer_blocks.3", output: "frcnn.fpn.p5", kernel: 3)
			var result = [Activation](repeating: output, count: 4)
			result[3] = output

			for index in stride(from: 2, through: 0, by: -1) {
				let lateral = try fpnBlock(c2ToC5[index], module: "backbone.fpn.inner_blocks.\(index)", output: "frcnn.fpn.lateral\(index + 2)", kernel: 1)
				let upsampled = upsample(inner, output: "frcnn.fpn.up\(index + 3)")
				inner = add(lateral, upsampled, output: "frcnn.fpn.inner\(index + 2)")
				output = try fpnBlock(inner, module: "backbone.fpn.layer_blocks.\(index)", output: "frcnn.fpn.p\(index + 2)", kernel: 3)
				result[index] = output
			}
			let p6 = pool(result[3], output: "frcnn.fpn.p6", kernel: 1, stride: 2, padding: 0)
			return result + [p6]
		}

		mutating func rpnLogits(for features: [Activation]) throws -> [Activation] {
			var result: [Activation] = []
			for (index, feature) in features.enumerated() {
				var hidden = try convolution(
					feature, module: "rpn.head.conv.0.0", output: "frcnn.rpn.p\(index + 2).conv0",
					outputChannels: NativeModelFasterRCNNRegistry.architecture.fpnChannels, kernel: 3, stride: 1, padding: 1, hasBias: true
				)
				hidden = relu(hidden, output: "frcnn.rpn.p\(index + 2).relu0")
				hidden = try convolution(
					hidden, module: "rpn.head.conv.1.0", output: "frcnn.rpn.p\(index + 2).conv1",
					outputChannels: NativeModelFasterRCNNRegistry.architecture.fpnChannels, kernel: 3, stride: 1, padding: 1, hasBias: true
				)
				hidden = relu(hidden, output: "frcnn.rpn.p\(index + 2).relu1")
				let logits = try convolution(
					hidden, module: "rpn.head.cls_logits", output: "frcnn.rpn.p\(index + 2).objectness",
					outputChannels: NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.count, kernel: 1, stride: 1, padding: 0, hasBias: true
				)
				// The regression head is part of the closed registry even though AIA-0686 is where its
				// decoded boxes replace the anchor-only loadability path below.
				_ = try convolution(
					hidden, module: "rpn.head.bbox_pred", output: "frcnn.rpn.p\(index + 2).deltas",
					outputChannels: NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.count * 4, kernel: 1, stride: 1, padding: 0, hasBias: true
				)
				result.append(logits)
			}
			return result
		}

		mutating func proposalScores(from logits: [Activation]) throws -> String {
			var flattened: [String] = []
			for (index, level) in logits.enumerated() {
				let count = level.channels * level.height * level.width
				let reshaped = reshape(level.name, output: "frcnn.rpn.p\(index + 2).flat", shape: [1, count])
				flattened.append(sigmoid(reshaped, output: "frcnn.rpn.p\(index + 2).scores", shape: [1, count]))
			}
			let candidateCount = flattenedCandidateCount(logits)
			return concatenate(flattened, output: "frcnn.rpn.candidate_scores", shape: [1, candidateCount], axis: 1)
		}

		mutating func anchors(for features: [Activation]) throws -> String {
			let values = try normalizedAnchors(for: features)
			let count = values.count / 4
			return constant(values: values, output: "frcnn.rpn.anchors", shape: [1, count, 4])
		}

		mutating func selectProvisionalProposals(scores: String, anchors: String) throws -> (coordinates: String, confidence: String) {
			let candidateCount = flattenedCandidateCountForCanvas()
			let proposalCount = NativeModelFasterRCNNRegistry.architecture.proposalCount
			precondition(candidateCount >= proposalCount, "The pinned canvas must produce at least the fixed top-K proposal budget.")
			let values = "frcnn.rpn.top_scores"
			let indices = "frcnn.rpn.top_indices"
			operations.append(NativeModelOperation(
				name: "frcnn.rpn.top_k", kind: .topK, inputs: [scores],
				outputs: [
					NativeModelTensor(name: values, dataType: .float32, shape: [1, proposalCount]),
					NativeModelTensor(name: indices, dataType: .float32, shape: [1, proposalCount])
				], attributes: ["k": .integer(proposalCount), "axis": .integer(1)]
			))
			let gathered = "frcnn.rpn.selected_anchor_rank4"
			operations.append(NativeModelOperation(
				name: "frcnn.rpn.gather_anchors", kind: .gather, inputs: [anchors, indices],
				outputs: [NativeModelTensor(name: gathered, dataType: .float32, shape: [1, 1, proposalCount, 4])],
				attributes: ["axis": .integer(1)]
			))
			let coordinates = reshape(gathered, output: Self.coordinatesOutput, shape: [proposalCount, 4])
			let confidence = reshape(values, output: Self.confidenceOutput, shape: [proposalCount, 1])
			return (coordinates, confidence)
		}

		func flattenedCandidateCount(_ logits: [Activation]) -> Int {
			logits.reduce(0) { $0 + $1.channels * $1.height * $1.width }
		}

		func flattenedCandidateCountForCanvas() -> Int {
			// The FPN levels produced by the fixed 1344 canvas are 336, 168, 84, 42, 21.
			let sides = [336, 168, 84, 42, 21]
			return sides.reduce(0) { $0 + NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.count * $1 * $1 }
		}

		func normalizedAnchors(for features: [Activation]) throws -> [Float] {
			let canvas = NativeModelFasterRCNNRegistry.architecture.canvas
			let expectedSides = [336, 168, 84, 42, 21]
			guard features.map(\.width) == expectedSides, features.map(\.height) == expectedSides else {
				throw NativeModelFasterRCNNRegistryError.unexpectedFeatureGrid(
					widths: features.map(\.width), heights: features.map(\.height)
				)
			}
			var values: [Float] = []
			values.reserveCapacity(flattenedCandidateCountForCanvas() * 4)
			for (level, feature) in features.enumerated() {
				let strideX = Double(canvas.width) / Double(feature.width)
				let strideY = Double(canvas.height) / Double(feature.height)
				let size = Double(NativeModelFasterRCNNRegistry.architecture.anchorSizes[level])
				for ratio in NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios {
					let width = size * sqrt(1 / ratio) / Double(canvas.width)
					let height = size * sqrt(ratio) / Double(canvas.height)
					for row in 0..<feature.height {
						for column in 0..<feature.width {
							values.append(Float(Double(column) * strideX / Double(canvas.width)))
							values.append(Float(Double(row) * strideY / Double(canvas.height)))
							values.append(Float(width))
							values.append(Float(height))
						}
					}
				}
			}
			return values
		}

		mutating func fpnBlock(_ input: Activation, module: String, output: String, kernel: Int) throws -> Activation {
			var result = try convolution(
				input, module: "\(module).0", output: "\(output).conv", outputChannels: NativeModelFasterRCNNRegistry.architecture.fpnChannels,
				kernel: kernel, stride: 1, padding: kernel == 1 ? 0 : 1
			)
			result = try batchNorm(result, module: "\(module).1", output: output)
			return result
		}

		mutating func convolution(
			_ input: Activation,
			module: String,
			output: String,
			outputChannels: Int,
			kernel: Int,
			stride: Int,
			padding: Int,
			hasBias: Bool = false
		) throws -> Activation {
			try requireWeight("\(module).weight", shape: [outputChannels, input.channels, kernel, kernel])
			var inputs = [input.name, "\(module).weight"]
			if hasBias {
				try requireWeight("\(module).bias", shape: [outputChannels])
				inputs.append("\(module).bias")
			}
			let height = outputDimension(input.height, kernel: kernel, stride: stride, padding: padding)
			let width = outputDimension(input.width, kernel: kernel, stride: stride, padding: padding)
			let activation = Activation(name: output, channels: outputChannels, height: height, width: width)
			operations.append(NativeModelOperation(
				name: output, kind: .convolution2D, inputs: inputs,
				outputs: [tensor(activation)],
				attributes: [
					"kernelSize": .integers([kernel, kernel]), "strides": .integers([stride, stride]),
					"padding": .integers([padding, padding]), "dilations": .integers([1, 1]), "groups": .integer(1)
				]
			))
			return activation
		}

		mutating func batchNorm(_ input: Activation, module: String, output: String) throws -> Activation {
			for suffix in ["weight", "bias", "running_mean", "running_var"] {
				try requireWeight("\(module).\(suffix)", shape: [input.channels])
			}
			let activation = Activation(name: output, channels: input.channels, height: input.height, width: input.width)
			operations.append(NativeModelOperation(
				name: output, kind: .batchNormalization,
				inputs: [input.name, "\(module).weight", "\(module).bias", "\(module).running_mean", "\(module).running_var"],
				outputs: [tensor(activation)], attributes: ["epsilon": .floatingPoint(1e-5)]
			))
			return activation
		}

		mutating func constant(values: [Float], output: String, shape: [Int]) -> String {
			let name = "\(output).values"
			let payload = values.withUnsafeBytes { Data($0) }
			synthesizedWeights.append(NativeModelWeight(
				name: name, dataType: .float32, shape: shape,
				offset: sourceWeightByteCount + UInt64(synthesizedWeightData.count), byteCount: UInt64(payload.count)
			))
			synthesizedWeightData.append(payload)
			operations.append(NativeModelOperation(
				name: output, kind: .constantND, inputs: [name],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: [:]
			))
			return output
		}

		mutating func requireWeight(_ name: String, shape: [Int]) throws {
			guard let weight = sourceWeights[name], weight.shape == shape else {
				throw NativeModelFasterRCNNRegistryError.graphRequestedUnknownWeight(name: name, shape: shape)
			}
		}

		mutating func relu(_ input: Activation, output: String) -> Activation {
			recordUnary(.relu, input: input, output: output)
		}

		mutating func sigmoid(_ input: String, output: String, shape: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .sigmoid, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: [:]
			))
			return output
		}

		mutating func pool(_ input: Activation, output: String, kernel: Int, stride: Int, padding: Int) -> Activation {
			let activation = Activation(
				name: output, channels: input.channels,
				height: outputDimension(input.height, kernel: kernel, stride: stride, padding: padding),
				width: outputDimension(input.width, kernel: kernel, stride: stride, padding: padding)
			)
			operations.append(NativeModelOperation(
				name: output, kind: .maxPool2D, inputs: [input.name], outputs: [tensor(activation)],
				attributes: ["kernelSize": .integers([kernel, kernel]), "strides": .integers([stride, stride]), "padding": .integers([padding, padding])]
			))
			return activation
		}

		mutating func upsample(_ input: Activation, output: String) -> Activation {
			let activation = Activation(name: output, channels: input.channels, height: input.height * 2, width: input.width * 2)
			operations.append(NativeModelOperation(
				name: output, kind: .upsample2D, inputs: [input.name], outputs: [tensor(activation)],
				attributes: ["scalingFactor": .integers([2, 2])]
			))
			return activation
		}

		mutating func add(_ lhs: Activation, _ rhs: Activation, output: String) -> Activation {
			precondition(lhs.channels == rhs.channels && lhs.height == rhs.height && lhs.width == rhs.width)
			let activation = Activation(name: output, channels: lhs.channels, height: lhs.height, width: lhs.width)
			operations.append(NativeModelOperation(name: output, kind: .add, inputs: [lhs.name, rhs.name], outputs: [tensor(activation)], attributes: [:]))
			return activation
		}

		mutating func reshape(_ input: String, output: String, shape: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .reshapeND, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: ["shape": .integers(shape)]
			))
			return output
		}

		mutating func concatenate(_ inputs: [String], output: String, shape: [Int], axis: Int) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .concatenateND, inputs: inputs,
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: ["axis": .integer(axis)]
			))
			return output
		}

		mutating func recordUnary(_ kind: NativeModelOperationKind, input: Activation, output: String) -> Activation {
			let activation = Activation(name: output, channels: input.channels, height: input.height, width: input.width)
			operations.append(NativeModelOperation(name: output, kind: kind, inputs: [input.name], outputs: [tensor(activation)], attributes: [:]))
			return activation
		}

		func tensor(_ activation: Activation) -> NativeModelTensor {
			NativeModelTensor(name: activation.name, dataType: .float32, shape: [1, activation.channels, activation.height, activation.width])
		}

		func outputDimension(_ input: Int, kernel: Int, stride: Int, padding: Int) -> Int {
			(input + 2 * padding - kernel) / stride + 1
		}
	}
}

public enum NativeModelFasterRCNNRegistryError: Error, Equatable, LocalizedError, Sendable {
	case checkpointIsNotPinnedDetector
	case unsupportedModel(architecture: String, predictorLogitCount: Int)
	case duplicateWeightName
	case weightNamesMismatch(missing: [String], unexpected: [String])
	case invalidWeight(name: String, expectedShape: [Int], actualShape: [Int], actualType: String, actualByteCount: UInt64)
	case weightBlobIsNotContiguous(weight: String)
	case weightDataLengthMismatch(expected: UInt64, actual: UInt64)
	case graphRequestedUnknownWeight(name: String, shape: [Int])
	case unexpectedFeatureGrid(widths: [Int], heights: [Int])

	public var errorDescription: String? {
		switch self {
		case .checkpointIsNotPinnedDetector:
			"The checkpoint is not the pinned ADAF Faster R-CNN detector."
		case .unsupportedModel(let architecture, let predictorLogitCount):
			"The registry supports fasterrcnn_resnet50_fpn_v2 with 2 predictor logits, not \(architecture) with \(predictorLogitCount)."
		case .duplicateWeightName:
			"The extracted checkpoint declares a duplicate weight name."
		case .weightNamesMismatch(let missing, let unexpected):
			"The pinned Faster R-CNN weight table differs (missing: \(missing.joined(separator: ", ")); unexpected: \(unexpected.joined(separator: ", ")))."
		case .invalidWeight(let name, let expectedShape, let actualShape, let actualType, let actualByteCount):
			"Weight '\(name)' must be fp16 \(expectedShape), got \(actualType) \(actualShape) / \(actualByteCount) bytes."
		case .weightBlobIsNotContiguous(let weight):
			"The extracted Faster R-CNN weight blob is not contiguous at '\(weight)'."
		case .weightDataLengthMismatch(let expected, let actual):
			"The extracted Faster R-CNN weight data is \(actual) bytes, expected \(expected)."
		case .graphRequestedUnknownWeight(let name, let shape):
			"The pinned Faster R-CNN graph requested weight '\(name)' with shape \(shape), but the registry did not validate it."
		case .unexpectedFeatureGrid(let widths, let heights):
			"The pinned FPN grid must be [336, 168, 84, 42, 21], got widths \(widths) and heights \(heights)."
		}
	}
}
