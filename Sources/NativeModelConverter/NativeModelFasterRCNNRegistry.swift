//
//  NativeModelFasterRCNNRegistry.swift
//  NativeModelConverter
//
//  The pinned ADAF Faster R-CNN architecture and its loadable Core ML graph (AIA-0685 through AIA-0687).
//

import CryptoKit
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
		public let terminalDetectionCount: Int
		public let predictorLogitCount: Int
		public let fpnChannels: Int
		public let anchorSizes: [Int]
		public let anchorAspectRatios: [Double]

		fileprivate init(
			identifier: String,
			canvas: NativeModelImageSize,
			proposalCount: Int,
			terminalDetectionCount: Int,
			predictorLogitCount: Int,
			fpnChannels: Int,
			anchorSizes: [Int],
			anchorAspectRatios: [Double]
		) {
			self.identifier = identifier
			self.canvas = canvas
			self.proposalCount = proposalCount
			self.terminalDetectionCount = terminalDetectionCount
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
		terminalDetectionCount: 100,
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

	/// The ADAF production emission contract. Unlike ``Conversion``, this describes promoted bytes
	/// without materialising them: the source checkpoint extraction remains a file and synthesized
	/// constants remain their small independent segment.
	struct StreamingConversion {
		let graph: NativeModelGraph
		let weights: NativeModelADAFPromotedWeights
		let interface: NativeModelDetectionInterface
		let targetInfo: NativeModelDetectionTargetInfo
		let targetSemanticsIntent: NativeModelTargetSemanticsIntent
	}

	/// Builds the graph skeleton from the closed architecture registry.
	///
	/// The primary intentionally evaluates the complete fixed-K prediction path: RPN deltas become
	/// proposals, every proposal is ROI-aligned through the FPN level chosen by torchvision's level
	/// mapper, then the checkpoint's box head and predictor produce the class score and box delta that
	/// feed the two measured terminal suppression passes. The later host-side chunk loop must preserve
	/// this sequence; it is a memory optimisation, not a second detector implementation.
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
			boxCount: architecture.terminalDetectionCount,
			coordinatesBlobName: GraphBuilder.coordinatesOutput,
			confidenceBlobName: GraphBuilder.confidenceOutput,
			suppressionOwnership: .graph
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
		weightData: Data,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws -> Conversion {
		try cancellationCheck?()
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
		let emission = try promoteWeightsForStablePrecision(
			template.graph,
			data: combined,
			checkingCancellation: cancellationCheck
		)
		return Conversion(
			graph: emission.graph,
			weights: emission.data,
			interface: template.interface,
			targetInfo: template.targetInfo,
			targetSemanticsIntent: template.targetSemanticsIntent
		)
	}

	/// Creates the bounded-memory production path for a pinned ADAF detector.
	///
	/// The historic ``conversion(checkpoint:extraction:weightData:)`` overload stays as an
	/// in-memory reference for the dense artifact parity test. App conversion must use this overload:
	/// it never maps the extracted fp16 file, joins it with synthesized bytes, or constructs a full
	/// Float32 blob.
	static func streamingConversion(
		checkpoint: PyTorchCheckpoint,
		extraction: PyTorchWeightExtraction,
		weightURL: URL,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws -> StreamingConversion {
		try cancellationCheck?()
		guard case let .objectDetection(model) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			throw NativeModelFasterRCNNRegistryError.checkpointIsNotPinnedDetector
		}
		let template = try template(for: model, weights: extraction.weights)
		guard extraction.byteCount == template.sourceWeightByteCount else {
			throw NativeModelFasterRCNNRegistryError.weightDataLengthMismatch(
				expected: template.sourceWeightByteCount,
				actual: extraction.byteCount
			)
		}
		let weights = try NativeModelADAFPromotedWeights(
			graph: template.graph,
			sourceWeightByteCount: template.sourceWeightByteCount,
			synthesizedWeightData: template.synthesizedWeightData,
			weightURL: weightURL,
			checkingCancellation: cancellationCheck
		)
		return StreamingConversion(
			graph: weights.graph,
			weights: weights,
			interface: template.interface,
			targetInfo: template.targetInfo,
			targetSemanticsIntent: template.targetSemanticsIntent
		)
	}

	/// Core ML executes a Float16-weight neural-network layer in reduced precision even with
	/// `.cpuOnly`. The detector's terminal NMS can make that otherwise small difference select a
	/// different overlapping proposal. Preserve the extractor's deliberately quantised binary16
	/// *values*, but widen their graph representation back to Float32 so the CPU oracle and measured
	/// GPU path retain the intended accumulation. The Neural Engine may still use its documented
	/// half-precision path. Strict device-parity tests load this graph on CPU because a sub-millipoint
	/// ROI-head difference can flip a greedy terminal-NMS choice onto a different overlapping
	/// proposal, which is a device-visible box shift; product runtime placement remains an app choice.
	/// The decoder itself is not
	/// the amplifier: after the `[10, 10, 5, 5]` BoxCoder division the measured delta moves a box by
	/// roughly 0.1 px, not the 3.9135 px observed on device.
	private static func promoteWeightsForStablePrecision(
		_ graph: NativeModelGraph,
		data: Data,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> (graph: NativeModelGraph, data: Data) {
		var promotedWeights: [NativeModelWeight] = []
		var promotedData = Data()
		let orderedWeights = graph.weights.sorted(by: { $0.offset < $1.offset })
		promotedWeights.reserveCapacity(orderedWeights.count)
		promotedData.reserveCapacity(data.count + orderedWeights.reduce(into: 0) { total, weight in
			if weight.dataType == .float16 { total += Int(weight.byteCount) }
		})
		for weight in orderedWeights {
			try cancellationCheck?()
			let start = Int(weight.offset)
			let end = start + Int(weight.byteCount)
			let bytes = data[start..<end]
			let offset = UInt64(promotedData.count)
			switch weight.dataType {
			case .float16:
				for (elementIndex, index) in stride(from: bytes.startIndex, to: bytes.endIndex, by: 2).enumerated() {
					if elementIndex.isMultiple(of: 4_096) {
						try cancellationCheck?()
					}
					let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
					var value = Float(Float16(bitPattern: bits)).bitPattern.littleEndian
					withUnsafeBytes(of: &value) { promotedData.append(contentsOf: $0) }
				}
				promotedWeights.append(NativeModelWeight(
					name: weight.name, dataType: .float32, shape: weight.shape, offset: offset,
					byteCount: weight.byteCount * 2
				))
			case .float32:
				promotedData.append(contentsOf: bytes)
				promotedWeights.append(NativeModelWeight(
					name: weight.name, dataType: weight.dataType, shape: weight.shape, offset: offset,
					byteCount: weight.byteCount
				))
			case .unsupported:
				preconditionFailure("the Faster R-CNN graph contains only floating-point weights")
			}
		}
		return (
			NativeModelGraph(
				formatVersion: graph.formatVersion, producer: graph.producer, inputs: graph.inputs,
				weights: promotedWeights, operations: graph.operations, outputs: graph.outputs
			),
			promotedData
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
		private static let boxTransformClip = log(1_000.0 / 16.0)
		private static let strictTorchvisionScoreFloor = Double(Float(0.05).nextUp)

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
			let rpn = try rpnPredictions(for: fpn)
			let anchorCorners = try anchorCorners(for: fpn)
			let proposals = try rpnProposals(predictions: rpn, anchorCorners: anchorCorners)
			let pooled = emitROIEdgeAlignment(features: fpn, proposalCorners: proposals.corners, count: proposals.count)
			let boxHead = try roiBoxHead(from: pooled, count: proposals.count)
			let detections = decodeROIHead(boxHead, proposals: proposals.corners, count: proposals.count)
			let proposal = terminalSuppressions(corners: detections.corners, scores: detections.scores)

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

		struct RPNPrediction {
			let scores: String
			let deltas: String
			let count: Int
		}

		struct Proposals {
			let corners: String
			let scores: String
			let count: Int
		}

		struct ROIBoxHeadPrediction {
			let scores: String
			let deltas: String
		}

		mutating func rpnPredictions(for features: [Activation]) throws -> [RPNPrediction] {
			var result: [RPNPrediction] = []
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
				let deltas = try convolution(
					hidden, module: "rpn.head.bbox_pred", output: "frcnn.rpn.p\(index + 2).deltas",
					outputChannels: NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.count * 4, kernel: 1, stride: 1, padding: 0, hasBias: true
				)
				let anchorsPerLocation = NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.count
				let count = anchorsPerLocation * feature.height * feature.width
				let scoreRank5 = reshape(
					logits.name, output: "frcnn.rpn.p\(index + 2).objectness_rank5",
					shape: [1, anchorsPerLocation, 1, feature.height, feature.width]
				)
				let scoreGrid = transpose(
					scoreRank5, output: "frcnn.rpn.p\(index + 2).objectness_grid",
					shape: [1, feature.height, feature.width, anchorsPerLocation, 1], permutation: [0, 3, 4, 1, 2]
				)
				let deltaRank5 = reshape(
					deltas.name, output: "frcnn.rpn.p\(index + 2).deltas_rank5",
					shape: [1, anchorsPerLocation, 4, feature.height, feature.width]
				)
				let deltaGrid = transpose(
					deltaRank5, output: "frcnn.rpn.p\(index + 2).deltas_grid",
					shape: [1, feature.height, feature.width, anchorsPerLocation, 4], permutation: [0, 3, 4, 1, 2]
				)
				result.append(RPNPrediction(
					scores: sigmoid(
						reshape(scoreGrid, output: "frcnn.rpn.p\(index + 2).flat_objectness", shape: [1, count]),
						output: "frcnn.rpn.p\(index + 2).scores", shape: [1, count]
					),
					deltas: reshape(deltaGrid, output: "frcnn.rpn.p\(index + 2).flat_deltas", shape: [1, count, 4]),
					count: count
				))
			}
			return result
		}

		mutating func anchorCorners(for features: [Activation]) throws -> String {
			let values = try normalizedAnchorCorners(for: features)
			let count = values.count / 4
			return constant(values: values, output: "frcnn.rpn.anchor_corners", shape: [1, count, 4])
		}

		/// Torchvision first takes the best 1,000 logits **per FPN level**, decodes those anchors,
		/// suppresses each level at 0.7, then takes the best 1,000 of the joined survivors. Doing one
		/// global top-K looks similar on a heatmap but starves coarse levels before NMS gets a say.
		mutating func rpnProposals(predictions: [RPNPrediction], anchorCorners: String) throws -> Proposals {
			precondition(predictions.count == NativeModelFasterRCNNRegistry.architecture.anchorSizes.count)
			var cornersByLevel: [String] = []
			var scoresByLevel: [String] = []
			var anchorOffset = 0

			for (level, prediction) in predictions.enumerated() {
				let prefix = "frcnn.rpn.p\(level + 2)"
				let candidateCount = min(NativeModelFasterRCNNRegistry.architecture.proposalCount, prediction.count)
				let top = topK(
					prediction.scores, output: "\(prefix).pre_nms", inputCount: prediction.count, k: candidateCount
				)
				let selectedDeltas = gatherRows(
					prediction.deltas, indices: top.indices, output: "\(prefix).selected_deltas",
					rowCount: candidateCount, columnCount: 4
				)
				let levelAnchors = sliceND(
					anchorCorners, output: "\(prefix).anchor_corners",
					begin: [0, anchorOffset, 0], end: [1, anchorOffset + prediction.count, 4],
					shape: [1, prediction.count, 4]
				)
				let selectedAnchors = gatherRows(
					levelAnchors, indices: top.indices, output: "\(prefix).selected_anchors",
					rowCount: candidateCount, columnCount: 4
				)
				let decoded = decodeBoxes(
					deltas: selectedDeltas, referenceCorners: selectedAnchors, count: candidateCount,
					weights: [1, 1, 1, 1], clip: Self.boxTransformClip, prefix: "\(prefix).decode"
				)
				let centreSize = cornerBoxesToCentreSize(
					decoded, count: candidateCount, prefix: "\(prefix).nms_input"
				)
				let suppressed = suppress(
					boxes: centreSize,
					scores: reshape(top.values, output: "\(prefix).selected_scores", shape: [1, candidateCount, 1]),
					name: "\(prefix).nms", iouThreshold: 0.7, scoreThreshold: 0, maxBoxes: candidateCount
				)
				cornersByLevel.append(centreSizeToCornerBoxes(
					suppressed.boxes, count: candidateCount, prefix: "\(prefix).nms_output"
				))
				scoresByLevel.append(suppressed.scores)
				anchorOffset += prediction.count
			}

			let joinedCount = cornersByLevel.count * NativeModelFasterRCNNRegistry.architecture.proposalCount
			let joinedCorners = concatenate(
				cornersByLevel, output: "frcnn.rpn.joined_corners", shape: [1, joinedCount, 4], axis: 1
			)
			let joinedScores = concatenate(
				scoresByLevel, output: "frcnn.rpn.joined_scores", shape: [1, joinedCount, 1], axis: 1
			)
			let top = topK(
				reshape(joinedScores, output: "frcnn.rpn.joined_score_vector", shape: [1, joinedCount]),
				output: "frcnn.rpn.post_nms", inputCount: joinedCount,
				k: NativeModelFasterRCNNRegistry.architecture.proposalCount
			)
			return Proposals(
				corners: gatherRows(
					joinedCorners, indices: top.indices, output: "frcnn.rpn.proposal_corners",
					rowCount: NativeModelFasterRCNNRegistry.architecture.proposalCount, columnCount: 4
				),
				scores: reshape(
					top.values, output: "frcnn.rpn.proposal_scores",
					shape: [1, NativeModelFasterRCNNRegistry.architecture.proposalCount, 1]
				),
				count: NativeModelFasterRCNNRegistry.architecture.proposalCount
			)
		}

		mutating func topK(_ input: String, output: String, inputCount: Int, k: Int) -> (values: String, indices: String) {
			precondition(k > 0 && k <= inputCount)
			let values = "\(output).values"
			let indices = "\(output).indices"
			operations.append(NativeModelOperation(
				name: output, kind: .topK, inputs: [input],
				outputs: [
					NativeModelTensor(name: values, dataType: .float32, shape: [1, k]),
					NativeModelTensor(name: indices, dataType: .float32, shape: [1, k])
				], attributes: ["k": .integer(k), "axis": .integer(1)]
			))
			return (values, indices)
		}

		mutating func gatherRows(
			_ data: String,
			indices: String,
			output: String,
			rowCount: Int,
			columnCount: Int
		) -> String {
			let rank4 = "\(output).rank4"
			operations.append(NativeModelOperation(
				name: "\(output).gather", kind: .gather, inputs: [data, indices],
				outputs: [NativeModelTensor(name: rank4, dataType: .float32, shape: [1, 1, rowCount, columnCount])],
				attributes: ["axis": .integer(1)]
			))
			return reshape(rank4, output: output, shape: [1, rowCount, columnCount])
		}

		/// Emits `MultiScaleRoIAlign` for the full proposal set. `P6` feeds the RPN only. Every P2--P5
		/// crop is materialised and masked by torchvision's level mapper; that deliberate fixed-K cost is
		/// the numerical oracle path, not the later host-side chunk implementation.
		///
		/// `CropResize` zeroes samples outside its feature tensor whereas torchvision clamps them. The
		/// replicate ring plus one feature-pixel box shift turns that into the required clamp semantics.
		mutating func emitROIEdgeAlignment(features: [Activation], proposalCorners: String, count: Int) -> String {
			let roiFeatures = Array(features.prefix(4))
			precondition(roiFeatures.count == 4, "Faster R-CNN pools P2 through P5 exactly.")
			let imageScale = constant(
				values: [
					Float(NativeModelFasterRCNNRegistry.architecture.canvas.width),
					Float(NativeModelFasterRCNNRegistry.architecture.canvas.height),
					Float(NativeModelFasterRCNNRegistry.architecture.canvas.width),
					Float(NativeModelFasterRCNNRegistry.architecture.canvas.height)
				],
				output: "frcnn.roi.image_scale", shape: [1, 1, 4]
			)
			let imageCorners = binary(
				.multiply, proposalCorners, imageScale, output: "frcnn.roi.image_corners", shape: [1, count, 4]
			)
			let components = ["x0", "y0", "x1", "y1"].map { "frcnn.roi.corner_\($0)" }
			operations.append(NativeModelOperation(
				name: "frcnn.roi.split_corners", kind: .splitND, inputs: [imageCorners],
				outputs: components.map { NativeModelTensor(name: $0, dataType: .float32, shape: [1, count, 1]) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let cropCorners = concatenate(
				[components[1], components[0], components[3], components[2]], output: "frcnn.roi.crop_corners",
				shape: [1, count, 4], axis: 2
			)
			let boxes = reshape(cropCorners, output: "frcnn.roi.boxes", shape: [count, 1, 4, 1, 1])
			let levelMasks = roiLevelMasks(proposalCorners: proposalCorners, count: count)
			var selectedPools: [String] = []

			for (index, feature) in roiFeatures.enumerated() {
				let level = index + 2
				let prefix = "frcnn.roi.p\(level)"
				let featureRank5 = reshape(
					feature.name, output: "\(prefix).features_rank5",
					shape: [1, 1, feature.channels, feature.height, feature.width]
				)
				let left = sliceND(
					featureRank5, output: "\(prefix).ring_left",
					begin: [0, 0, 0, 0, 0], end: [1, 1, feature.channels, feature.height, 1],
					shape: [1, 1, feature.channels, feature.height, 1]
				)
				let right = sliceND(
					featureRank5, output: "\(prefix).ring_right",
					begin: [0, 0, 0, 0, feature.width - 1], end: [1, 1, feature.channels, feature.height, feature.width],
					shape: [1, 1, feature.channels, feature.height, 1]
				)
				let ringColumns = concatenate(
					[left, featureRank5, right], output: "\(prefix).ring_columns",
					shape: [1, 1, feature.channels, feature.height, feature.width + 2], axis: 4
				)
				let top = sliceND(
					ringColumns, output: "\(prefix).ring_top",
					begin: [0, 0, 0, 0, 0], end: [1, 1, feature.channels, 1, feature.width + 2],
					shape: [1, 1, feature.channels, 1, feature.width + 2]
				)
				let bottom = sliceND(
					ringColumns, output: "\(prefix).ring_bottom",
					begin: [0, 0, 0, feature.height - 1, 0], end: [1, 1, feature.channels, feature.height, feature.width + 2],
					shape: [1, 1, feature.channels, 1, feature.width + 2]
				)
				let ring = concatenate(
					[top, ringColumns, bottom], output: "\(prefix).replicate_ring",
					shape: [1, 1, feature.channels, feature.height + 2, feature.width + 2], axis: 3
				)

				let spatialScale = Double(feature.width) / Double(NativeModelFasterRCNNRegistry.architecture.canvas.width)
				let shift = constant(
					values: [Float](repeating: Float(1 / spatialScale), count: 4), output: "\(prefix).feature_pixel_shift",
					shape: [1, 1, 4, 1, 1]
				)
				let shiftedBoxes = binary(
					.add, boxes, shift, output: "\(prefix).shifted_boxes", shape: [count, 1, 4, 1, 1]
				)
				let cropped = "\(prefix).crop_resize"
				operations.append(NativeModelOperation(
					name: cropped, kind: .cropResize, inputs: [ring, shiftedBoxes],
					outputs: [NativeModelTensor(name: cropped, dataType: .float32, shape: [count, 1, feature.channels, 14, 14])],
					attributes: [
						"targetHeight": .integer(14), "targetWidth": .integer(14),
						"spatialScale": .floatingPoint(spatialScale)
					]
				))
				let pooled = "\(prefix).roi_align"
				operations.append(NativeModelOperation(
					name: pooled, kind: .averagePool2D, inputs: [cropped],
					outputs: [NativeModelTensor(name: pooled, dataType: .float32, shape: [count, 1, feature.channels, 7, 7])],
					attributes: [
						"kernelSize": .integers([2, 2]), "strides": .integers([2, 2]), "padding": .integers([0, 0])
					]
				))
				selectedPools.append(binary(
					.multiply, pooled, levelMasks[index], output: "\(prefix).selected_roi_align",
					shape: [count, 1, feature.channels, 7, 7]
				))
			}
			var selected = selectedPools[0]
			for (index, pool) in selectedPools.dropFirst().enumerated() {
				selected = binary(
					.add, selected, pool, output: "frcnn.roi.selected_pool_\(index + 1)",
					shape: [count, 1, NativeModelFasterRCNNRegistry.architecture.fpnChannels, 7, 7]
				)
			}
			return selected
		}

		/// `LevelMapper` uses `floor(4 + log2(sqrt(area) / 224) + eps)`, clamped to P2--P5.
		/// Working as `log(width) + log(height)` avoids a fp16 area overflow before the square root.
		mutating func roiLevelMasks(proposalCorners: String, count: Int) -> [String] {
			let shape = [1, count, 1]
			let components = ["x0", "y0", "x1", "y1"].map { "frcnn.roi.level.\($0)" }
			operations.append(NativeModelOperation(
				name: "frcnn.roi.level.split_corners", kind: .splitND, inputs: [proposalCorners],
				outputs: components.map { NativeModelTensor(name: $0, dataType: .float32, shape: shape) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let width = binary(.subtract, components[2], components[0], output: "frcnn.roi.level.width", shape: shape)
			let height = binary(.subtract, components[3], components[1], output: "frcnn.roi.level.height", shape: shape)
			let pixelScale = constant(
				values: [Float](repeating: Float(NativeModelFasterRCNNRegistry.architecture.canvas.width), count: count),
				output: "frcnn.roi.level.pixel_scale", shape: shape
			)
			let minSpan = constant(
				values: [Float](repeating: 1 / Float(NativeModelFasterRCNNRegistry.architecture.canvas.width), count: count),
				output: "frcnn.roi.level.minimum_span", shape: shape
			)
			let widthPixels = binary(
				.multiply,
				binary(.maximumND, width, minSpan, output: "frcnn.roi.level.safe_width", shape: shape),
				pixelScale, output: "frcnn.roi.level.width_pixels", shape: shape
			)
			let heightPixels = binary(
				.multiply,
				binary(.maximumND, height, minSpan, output: "frcnn.roi.level.safe_height", shape: shape),
				pixelScale, output: "frcnn.roi.level.height_pixels", shape: shape
			)
			let logArea = binary(
				.add,
				unary(.naturalLogarithm, widthPixels, output: "frcnn.roi.level.log_width", shape: shape),
				unary(.naturalLogarithm, heightPixels, output: "frcnn.roi.level.log_height", shape: shape),
				output: "frcnn.roi.level.log_area", shape: shape
			)
			let factor = constant(
				values: [Float](repeating: Float(0.5 / log(2)), count: count), output: "frcnn.roi.level.log2_factor", shape: shape
			)
			let offset = constant(
				values: [Float](repeating: Float(4 - log(224) / log(2) + 1e-6), count: count),
				output: "frcnn.roi.level.offset", shape: shape
			)
			let unbounded = binary(
				.add, binary(.multiply, logArea, factor, output: "frcnn.roi.level.scaled_log_area", shape: shape), offset,
				output: "frcnn.roi.level.unbounded", shape: shape
			)
			let minimum = constant(values: [Float](repeating: 2, count: count), output: "frcnn.roi.level.minimum", shape: shape)
			let maximum = constant(values: [Float](repeating: 5, count: count), output: "frcnn.roi.level.maximum", shape: shape)
			let level = binary(
				.minimumND,
				binary(.maximumND, unary(.floor, unbounded, output: "frcnn.roi.level.floor", shape: shape), minimum,
					output: "frcnn.roi.level.clamp_min", shape: shape), maximum,
				output: "frcnn.roi.level.index", shape: shape
			)
			return (2...5).map { levelNumber in
				let lower = greaterOrEqual(
					level, threshold: Double(levelNumber), output: "frcnn.roi.p\(levelNumber).level_at_least",
					shape: shape
				)
				let membership: String
				if levelNumber == 5 {
					membership = lower
				} else {
					let upper = greaterOrEqual(
						level, threshold: Double(levelNumber + 1), output: "frcnn.roi.p\(levelNumber).level_above",
						shape: shape
					)
					membership = binary(.subtract, lower, upper, output: "frcnn.roi.p\(levelNumber).level_mask", shape: shape)
				}
				return reshape(membership, output: "frcnn.roi.p\(levelNumber).level_weight", shape: [count, 1, 1, 1, 1])
			}
		}

		mutating func roiBoxHead(from pooled: String, count: Int) throws -> ROIBoxHeadPrediction {
			let shape = [count, 1, NativeModelFasterRCNNRegistry.architecture.fpnChannels, 7, 7]
			var features = pooled
			for index in 0..<4 {
				let prefix = "frcnn.roi.box_head.\(index)"
				features = try convolutionND(
					features, shape: shape, module: "roi_heads.box_head.\(index).0", output: "\(prefix).conv",
					outputChannels: NativeModelFasterRCNNRegistry.architecture.fpnChannels, kernel: 3, hasBias: false
				)
				features = try batchNormND(
					features, shape: shape, module: "roi_heads.box_head.\(index).1", output: "\(prefix).bn"
				)
				features = unary(.relu, features, output: "\(prefix).relu", shape: shape)
			}
			let flattened = reshape(features, output: "frcnn.roi.box_head.flatten", shape: [count, 1, 12_544, 1, 1])
			let fc = try linearND(
				flattened, inputChannels: 12_544, outputChannels: 1_024, count: count,
				module: "roi_heads.box_head.5", output: "frcnn.roi.box_head.fc"
			)
			let activated = unary(.relu, fc, output: "frcnn.roi.box_head.fc_relu", shape: [count, 1, 1_024, 1, 1])
			let logits = try linearND(
				activated, inputChannels: 1_024, outputChannels: 2, count: count,
				module: "roi_heads.box_predictor.cls_score", output: "frcnn.roi.predictor.class_logits"
			)
			let deltas = try linearND(
				activated, inputChannels: 1_024, outputChannels: 8, count: count,
				module: "roi_heads.box_predictor.bbox_pred", output: "frcnn.roi.predictor.box_deltas"
			)
			let classScores = softmax(
				reshape(logits, output: "frcnn.roi.predictor.class_logits_rows", shape: [1, count, 2]),
				output: "frcnn.roi.predictor.class_scores", shape: [1, count, 2], axis: 2
			)
			let foregroundScores = sliceND(
				classScores, output: "frcnn.roi.predictor.foreground_scores",
				begin: [0, 0, 1], end: [1, count, 2], shape: [1, count, 1]
			)
			let foregroundDeltas = sliceND(
				reshape(deltas, output: "frcnn.roi.predictor.box_deltas_classes", shape: [1, count, 2, 4]),
				output: "frcnn.roi.predictor.foreground_deltas_class", begin: [0, 0, 1, 0], end: [1, count, 2, 4],
				shape: [1, count, 1, 4]
			)
			return ROIBoxHeadPrediction(
				scores: foregroundScores,
				deltas: reshape(foregroundDeltas, output: "frcnn.roi.predictor.foreground_deltas", shape: [1, count, 4])
			)
		}

		mutating func decodeROIHead(_ prediction: ROIBoxHeadPrediction, proposals: String, count: Int) -> (corners: String, scores: String) {
			(
				decodeBoxes(
					deltas: prediction.deltas, referenceCorners: proposals, count: count,
					weights: [10, 10, 5, 5], clip: Self.boxTransformClip, prefix: "frcnn.roi.decode"
				),
				prediction.scores
			)
		}

		/// Applies torchvision's ROI-score / 0.5-IoU / top-100 pass, then ADAF's separate 0.2-IoU pass.
		/// The source comparison is strictly `score > 0.05`; Core ML's threshold is inclusive, so the
		/// smallest representable Float32 above 0.05 carries that strictness into both layers.
		mutating func terminalSuppressions(corners: String, scores: String) -> (coordinates: String, confidence: String) {
			let scoreThreshold = Self.strictTorchvisionScoreFloor
			let firstBoxes = cornerBoxesToCentreSize(corners, count: NativeModelFasterRCNNRegistry.architecture.proposalCount)
			let first = suppress(
				boxes: firstBoxes, scores: scores, name: "frcnn.postprocess.torchvision_nms",
				iouThreshold: 0.5, scoreThreshold: scoreThreshold,
				maxBoxes: NativeModelFasterRCNNRegistry.architecture.terminalDetectionCount
			)
			let second = suppress(
				boxes: first.boxes, scores: first.scores, name: "frcnn.postprocess.adaf_nms",
				iouThreshold: 0.2, scoreThreshold: 0,
				maxBoxes: NativeModelFasterRCNNRegistry.architecture.terminalDetectionCount
			)
			let count = NativeModelFasterRCNNRegistry.architecture.terminalDetectionCount
			let masked = maskEmptyTile(
				boxes: second.boxes, scores: second.scores, count: count, scoreThreshold: scoreThreshold
			)
			return (
				reshape(masked.boxes, output: Self.coordinatesOutput, shape: [count, 4]),
				reshape(masked.scores, output: Self.confidenceOutput, shape: [count, 1])
			)
		}

		/// Core ML NMS reports one valid slot when nothing clears its score floor, carrying the highest
		/// sub-threshold input rather than padding. Apply the real first-pass floor to the *final* score
		/// and box blobs: the second 0.2-IoU pass may retain a valid first-pass survivor at score exactly
		/// 0.05, but can never turn a sub-threshold score into one. The same comparison also zeroes padded
		/// rows, so the Vision adapter's tiny positive threshold emits no phantom observation.
		mutating func maskEmptyTile(
			boxes: String,
			scores: String,
			count: Int,
			scoreThreshold: Double
		) -> (boxes: String, scores: String) {
			let scoreShape = [1, count, 1]
			let survivors = "frcnn.postprocess.survivors"
			operations.append(NativeModelOperation(
				name: survivors, kind: .greaterOrEqual, inputs: [scores],
				outputs: [NativeModelTensor(name: survivors, dataType: .float32, shape: scoreShape)],
				attributes: ["threshold": .floatingPoint(scoreThreshold)]
			))
			let maskedScores = "frcnn.postprocess.masked_scores"
			operations.append(NativeModelOperation(
				name: maskedScores, kind: .multiply, inputs: [scores, survivors],
				outputs: [NativeModelTensor(name: maskedScores, dataType: .float32, shape: scoreShape)], attributes: [:]
			))
			let boxMask = concatenate(
				[String](repeating: survivors, count: 4), output: "frcnn.postprocess.box_mask",
				shape: [1, count, 4], axis: 2
			)
			let maskedBoxes = "frcnn.postprocess.masked_boxes"
			operations.append(NativeModelOperation(
				name: maskedBoxes, kind: .multiply, inputs: [boxes, boxMask],
				outputs: [NativeModelTensor(name: maskedBoxes, dataType: .float32, shape: [1, count, 4])], attributes: [:]
			))
			return (maskedBoxes, maskedScores)
		}

		/// Converts `[x0, y0, x1, y1]` to Core ML NMS's mandatory `[cx, cy, width, height]` exactly at
		/// the operator boundary. No other graph operation after this point reads these values as corners.
		mutating func cornerBoxesToCentreSize(_ corners: String, count: Int) -> String {
			cornerBoxesToCentreSize(corners, count: count, prefix: "frcnn.postprocess")
		}

		mutating func cornerBoxesToCentreSize(_ corners: String, count: Int, prefix: String) -> String {
			let componentShape = [1, count, 1]
			let components = ["x0", "y0", "x1", "y1"].map { "\(prefix).corner_\($0)" }
			operations.append(NativeModelOperation(
				name: "\(prefix).split_corners", kind: .splitND, inputs: [corners],
				outputs: components.map { NativeModelTensor(name: $0, dataType: .float32, shape: componentShape) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let half = constant(values: [Float](repeating: 0.5, count: count), output: "\(prefix).half", shape: componentShape)
			let centerXSum = binary(.add, components[0], components[2], output: "\(prefix).center_x_sum", shape: componentShape)
			let centerYSum = binary(.add, components[1], components[3], output: "\(prefix).center_y_sum", shape: componentShape)
			let centerX = binary(.multiply, centerXSum, half, output: "\(prefix).center_x", shape: componentShape)
			let centerY = binary(.multiply, centerYSum, half, output: "\(prefix).center_y", shape: componentShape)
			let width = binary(.subtract, components[2], components[0], output: "\(prefix).width", shape: componentShape)
			let height = binary(.subtract, components[3], components[1], output: "\(prefix).height", shape: componentShape)
			return concatenate(
				[centerX, centerY, width, height], output: "\(prefix).centre_size",
				shape: [1, count, 4], axis: 2
			)
		}

		mutating func centreSizeToCornerBoxes(_ centreSize: String, count: Int, prefix: String) -> String {
			let shape = [1, count, 1]
			let components = ["cx", "cy", "width", "height"].map { "\(prefix).\($0)" }
			operations.append(NativeModelOperation(
				name: "\(prefix).split_centre_size", kind: .splitND, inputs: [centreSize],
				outputs: components.map { NativeModelTensor(name: $0, dataType: .float32, shape: shape) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let half = constant(values: [Float](repeating: 0.5, count: count), output: "\(prefix).half", shape: shape)
			let halfWidth = binary(.multiply, components[2], half, output: "\(prefix).half_width", shape: shape)
			let halfHeight = binary(.multiply, components[3], half, output: "\(prefix).half_height", shape: shape)
			let x0 = binary(.subtract, components[0], halfWidth, output: "\(prefix).x0", shape: shape)
			let y0 = binary(.subtract, components[1], halfHeight, output: "\(prefix).y0", shape: shape)
			let x1 = binary(.add, components[0], halfWidth, output: "\(prefix).x1", shape: shape)
			let y1 = binary(.add, components[1], halfHeight, output: "\(prefix).y1", shape: shape)
			return concatenate([x0, y0, x1, y1], output: "\(prefix).corners", shape: [1, count, 4], axis: 2)
		}

		mutating func suppress(
			boxes: String,
			scores: String,
			name: String,
			iouThreshold: Double,
			scoreThreshold: Double,
			maxBoxes: Int
		) -> (boxes: String, scores: String) {
			let boxesOutput = "\(name).boxes"
			let scoresOutput = "\(name).scores"
			operations.append(NativeModelOperation(
				name: name, kind: .nonMaximumSuppression, inputs: [boxes, scores],
				outputs: [
					NativeModelTensor(name: boxesOutput, dataType: .float32, shape: [1, maxBoxes, 4]),
					NativeModelTensor(name: scoresOutput, dataType: .float32, shape: [1, maxBoxes, 1]),
					NativeModelTensor(name: "\(name).indices", dataType: .float32, shape: [1, maxBoxes]),
					NativeModelTensor(name: "\(name).valid_count", dataType: .float32, shape: [1])
				],
				attributes: [
					"iouThreshold": .floatingPoint(iouThreshold),
					"scoreThreshold": .floatingPoint(scoreThreshold),
					"maxBoxes": .integer(maxBoxes),
					"perClassSuppression": .boolean(false)
				]
			))
			return (boxesOutput, scoresOutput)
		}

		/// Torchvision's `BoxCoder.decode_single`: deltas are divided by the caller's weights, scale the
		/// reference centre/size, and exponentials are clipped before expansion. Coordinates remain
		/// normalized to the fixed canvas, so the final per-coordinate [0, 1] clip is exact and shared
		/// by RPN and ROI decoding.
		mutating func decodeBoxes(
			deltas: String,
			referenceCorners: String,
			count: Int,
			weights: [Float],
			clip: Double,
			prefix: String
		) -> String {
			precondition(weights.count == 4)
			let shape = [1, count, 1]
			let anchor = ["x0", "y0", "x1", "y1"].map { "\(prefix).reference_\($0)" }
			operations.append(NativeModelOperation(
				name: "\(prefix).split_reference", kind: .splitND, inputs: [referenceCorners],
				outputs: anchor.map { NativeModelTensor(name: $0, dataType: .float32, shape: shape) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let delta = ["x", "y", "w", "h"].map { "\(prefix).delta_\($0)" }
			operations.append(NativeModelOperation(
				name: "\(prefix).split_deltas", kind: .splitND, inputs: [deltas],
				outputs: delta.map { NativeModelTensor(name: $0, dataType: .float32, shape: shape) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let half = constant(values: [Float](repeating: 0.5, count: count), output: "\(prefix).half", shape: shape)
			let referenceWidth = binary(.subtract, anchor[2], anchor[0], output: "\(prefix).reference_width", shape: shape)
			let referenceHeight = binary(.subtract, anchor[3], anchor[1], output: "\(prefix).reference_height", shape: shape)
			let referenceCenterX = binary(
				.multiply, binary(.add, anchor[0], anchor[2], output: "\(prefix).reference_center_x_sum", shape: shape), half,
				output: "\(prefix).reference_center_x", shape: shape
			)
			let referenceCenterY = binary(
				.multiply, binary(.add, anchor[1], anchor[3], output: "\(prefix).reference_center_y_sum", shape: shape), half,
				output: "\(prefix).reference_center_y", shape: shape
			)
			let inverseCoderWeightX = constant(
				values: [Float](repeating: 1 / weights[0], count: count), output: "\(prefix).inverse_weight_x", shape: shape
			)
			let inverseCoderWeightY = constant(values: [Float](repeating: 1 / weights[1], count: count), output: "\(prefix).inverse_weight_y", shape: shape)
			let inverseCoderWeightW = constant(values: [Float](repeating: 1 / weights[2], count: count), output: "\(prefix).inverse_weight_w", shape: shape)
			let inverseCoderWeightH = constant(values: [Float](repeating: 1 / weights[3], count: count), output: "\(prefix).inverse_weight_h", shape: shape)
			let dx = binary(.multiply, delta[0], inverseCoderWeightX, output: "\(prefix).dx", shape: shape)
			let dy = binary(.multiply, delta[1], inverseCoderWeightY, output: "\(prefix).dy", shape: shape)
			let dw = binary(.multiply, delta[2], inverseCoderWeightW, output: "\(prefix).dw", shape: shape)
			let dh = binary(.multiply, delta[3], inverseCoderWeightH, output: "\(prefix).dh", shape: shape)
			let clipTensor = constant(values: [Float](repeating: Float(clip), count: count), output: "\(prefix).clip", shape: shape)
			let clippedDW = binary(.minimumND, dw, clipTensor, output: "\(prefix).clipped_dw", shape: shape)
			let clippedDH = binary(.minimumND, dh, clipTensor, output: "\(prefix).clipped_dh", shape: shape)
			let centerX = binary(
				.add, binary(.multiply, dx, referenceWidth, output: "\(prefix).center_x_offset", shape: shape), referenceCenterX,
				output: "\(prefix).center_x", shape: shape
			)
			let centerY = binary(
				.add, binary(.multiply, dy, referenceHeight, output: "\(prefix).center_y_offset", shape: shape), referenceCenterY,
				output: "\(prefix).center_y", shape: shape
			)
			let width = binary(
				.multiply, unary(.exponential, clippedDW, output: "\(prefix).exp_dw", shape: shape), referenceWidth,
				output: "\(prefix).width", shape: shape
			)
			let height = binary(
				.multiply, unary(.exponential, clippedDH, output: "\(prefix).exp_dh", shape: shape), referenceHeight,
				output: "\(prefix).height", shape: shape
			)
			let halfWidth = binary(.multiply, width, half, output: "\(prefix).half_width", shape: shape)
			let halfHeight = binary(.multiply, height, half, output: "\(prefix).half_height", shape: shape)
			let unbounded = [
				binary(.subtract, centerX, halfWidth, output: "\(prefix).x0", shape: shape),
				binary(.subtract, centerY, halfHeight, output: "\(prefix).y0", shape: shape),
				binary(.add, centerX, halfWidth, output: "\(prefix).x1", shape: shape),
				binary(.add, centerY, halfHeight, output: "\(prefix).y1", shape: shape)
			]
			let lower = constant(values: [Float](repeating: 0, count: count), output: "\(prefix).lower_bound", shape: shape)
			let upper = constant(values: [Float](repeating: 1, count: count), output: "\(prefix).upper_bound", shape: shape)
			let clipped = unbounded.enumerated().map { index, component in
				binary(
					.maximumND, binary(.minimumND, component, upper, output: "\(prefix).clip_upper_\(index)", shape: shape), lower,
					output: "\(prefix).clip_lower_\(index)", shape: shape
				)
			}
			return concatenate(clipped, output: "\(prefix).corners", shape: [1, count, 4], axis: 2)
		}

		func flattenedCandidateCountForCanvas() -> Int {
			// The FPN levels produced by the fixed 1344 canvas are 336, 168, 84, 42, 21.
			let sides = [336, 168, 84, 42, 21]
			return sides.reduce(0) { $0 + NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.count * $1 * $1 }
		}

		func normalizedAnchorCorners(for features: [Activation]) throws -> [Float] {
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
				// `AnchorGenerator.grid_anchors`: construct the *rounded* base anchors first, then
				// add every row-major grid shift. The flat RPN heads use location-major / ratio-minor
				// ordering, so a ratio-major constant would pair each logit with the wrong anchor.
				let baseCorners: [(x0: Double, y0: Double, x1: Double, y1: Double)] =
					NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios.map { ratio in
						let halfWidth = (size * sqrt(1 / ratio) / 2).rounded(.toNearestOrAwayFromZero)
						let halfHeight = (size * sqrt(ratio) / 2).rounded(.toNearestOrAwayFromZero)
						return (-halfWidth, -halfHeight, halfWidth, halfHeight)
					}
				for row in 0..<feature.height {
					for column in 0..<feature.width {
						let centerX = Double(column) * strideX / Double(canvas.width)
						let centerY = Double(row) * strideY / Double(canvas.height)
						for base in baseCorners {
							values.append(Float(centerX + base.x0 / Double(canvas.width)))
							values.append(Float(centerY + base.y0 / Double(canvas.height)))
							values.append(Float(centerX + base.x1 / Double(canvas.width)))
							values.append(Float(centerY + base.y1 / Double(canvas.height)))
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

		// These parameters map one-for-one to a Core ML convolution descriptor. A configuration value
		// would make each call site less auditable against the pinned PyTorch module and tensor shape.
		// swiftlint:disable:next function_parameter_count
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

		/// The ROI primary uses Core ML's sequence dimension for its fixed proposal batch. These helpers
		/// retain that rank instead of coercing it through `Activation`, whose `[1, C, H, W]` invariant is
		/// deliberately only for backbone/FPN tensors.
		mutating func convolutionND(
			_ input: String,
			shape: [Int],
			module: String,
			output: String,
			outputChannels: Int,
			kernel: Int,
			hasBias: Bool
		) throws -> String {
			precondition(shape.count == 5 && shape[2] > 0)
			try requireWeight("\(module).weight", shape: [outputChannels, shape[2], kernel, kernel])
			var inputs = [input, "\(module).weight"]
			if hasBias {
				try requireWeight("\(module).bias", shape: [outputChannels])
				inputs.append("\(module).bias")
			}
			var outputShape = shape
			outputShape[2] = outputChannels
			operations.append(NativeModelOperation(
				name: output, kind: .convolution2D, inputs: inputs,
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: outputShape)],
				attributes: [
					"kernelSize": .integers([kernel, kernel]), "strides": .integers([1, 1]),
					"padding": .integers([kernel == 1 ? 0 : 1, kernel == 1 ? 0 : 1]),
					"dilations": .integers([1, 1]), "groups": .integer(1)
				]
			))
			return output
		}

		mutating func batchNormND(_ input: String, shape: [Int], module: String, output: String) throws -> String {
			precondition(shape.count == 5)
			for suffix in ["weight", "bias", "running_mean", "running_var"] {
				try requireWeight("\(module).\(suffix)", shape: [shape[2]])
			}
			operations.append(NativeModelOperation(
				name: output, kind: .batchNormalization,
				inputs: [input, "\(module).weight", "\(module).bias", "\(module).running_mean", "\(module).running_var"],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: ["epsilon": .floatingPoint(1e-5)]
			))
			return output
		}

		mutating func linearND(
			_ input: String,
			inputChannels: Int,
			outputChannels: Int,
			count: Int,
			module: String,
			output: String
		) throws -> String {
			try requireWeight("\(module).weight", shape: [outputChannels, inputChannels])
			try requireWeight("\(module).bias", shape: [outputChannels])
			operations.append(NativeModelOperation(
				name: output, kind: .linear, inputs: [input, "\(module).weight", "\(module).bias"],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: [count, 1, outputChannels, 1, 1])], attributes: [:]
			))
			return output
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

		mutating func softmax(_ input: String, output: String, shape: [Int], axis: Int) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .softmax, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: ["axis": .integer(axis)]
			))
			return output
		}

		mutating func unary(_ kind: NativeModelOperationKind, _ input: String, output: String, shape: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: kind, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: [:]
			))
			return output
		}

		mutating func greaterOrEqual(_ input: String, threshold: Double, output: String, shape: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .greaterOrEqual, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)],
				attributes: ["threshold": .floatingPoint(threshold)]
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

		mutating func transpose(_ input: String, output: String, shape: [Int], permutation: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .transposeND, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)],
				attributes: ["permutation": .integers(permutation)]
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

		mutating func sliceND(_ input: String, output: String, begin: [Int], end: [Int], shape: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: .sliceND, inputs: [input],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)],
				attributes: [
					"beginIds": .integers(begin), "endIds": .integers(end),
					"strides": .integers([Int](repeating: 1, count: begin.count))
				]
			))
			return output
		}

		mutating func binary(_ kind: NativeModelOperationKind, _ lhs: String, _ rhs: String, output: String, shape: [Int]) -> String {
			operations.append(NativeModelOperation(
				name: output, kind: kind, inputs: [lhs, rhs],
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)], attributes: [:]
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

/// Promotes ADAF's extracted Float16 weights when the protobuf writer reaches each weight field.
///
/// The object owns no mapped source `Data`: each requested field seeks the extraction file and
/// widens no more than ``chunkByteCount`` emitted bytes at a time. The graph is transformed once to
/// point at the logical Float32 layout, which is small metadata rather than model-sized storage.
final class NativeModelADAFPromotedWeights: @unchecked Sendable {
	static let chunkByteCount = 1 * 1_024 * 1_024

	private enum Origin {
		case extracted(offset: UInt64)
		case synthesized(offset: UInt64)
	}

	let graph: NativeModelGraph
	private(set) var sha256: String
	private let sourceURL: URL
	private let sourceWeightByteCount: UInt64
	private let synthesizedWeightData: Data
	private let originalWeightsByName: [String: NativeModelWeight]
	private let originsByName: [String: Origin]

	init(
		graph sourceGraph: NativeModelGraph,
		sourceWeightByteCount: UInt64,
		synthesizedWeightData: Data,
		weightURL: URL,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler?
	) throws {
		let actualSourceByteCount = (try? FileManager.default.attributesOfItem(atPath: weightURL.path)[.size] as? NSNumber)?
			.uint64Value ?? 0
		guard actualSourceByteCount == sourceWeightByteCount else {
			throw NativeModelFasterRCNNRegistryError.weightDataLengthMismatch(
				expected: sourceWeightByteCount,
				actual: actualSourceByteCount
			)
		}

		let orderedWeights = sourceGraph.weights.sorted { $0.offset < $1.offset }
		var promotedWeights: [NativeModelWeight] = []
		var originalByName: [String: NativeModelWeight] = [:]
		var origins: [String: Origin] = [:]
		var promotedOffset: UInt64 = 0
		promotedWeights.reserveCapacity(orderedWeights.count)
		originalByName.reserveCapacity(orderedWeights.count)
		origins.reserveCapacity(orderedWeights.count)

		for weight in orderedWeights {
			try cancellationCheck?()
			guard originalByName.updateValue(weight, forKey: weight.name) == nil else {
				throw NativeModelFasterRCNNRegistryError.duplicateWeightName
			}
			let (sourceEnd, sourceOverflow) = weight.offset.addingReportingOverflow(weight.byteCount)
			guard !sourceOverflow else {
				throw NativeModelFasterRCNNRegistryError.weightBlobIsNotContiguous(weight: weight.name)
			}

			let origin: Origin
			if sourceEnd <= sourceWeightByteCount {
				guard weight.dataType == .float16, weight.byteCount.isMultiple(of: 2) else {
					throw NativeModelFasterRCNNRegistryError.invalidWeight(
						name: weight.name,
						expectedShape: weight.shape,
						actualShape: weight.shape,
						actualType: weight.dataType.serializedValue,
						actualByteCount: weight.byteCount
					)
				}
				origin = .extracted(offset: weight.offset)
			} else {
				guard weight.offset >= sourceWeightByteCount,
					sourceEnd - sourceWeightByteCount <= UInt64(synthesizedWeightData.count),
					weight.dataType == .float32
				else {
					throw NativeModelFasterRCNNRegistryError.weightBlobIsNotContiguous(weight: weight.name)
				}
				origin = .synthesized(offset: weight.offset - sourceWeightByteCount)
			}
			origins[weight.name] = origin

			let promotedByteCount: UInt64
			switch weight.dataType {
			case .float16:
				let (doubled, overflow) = weight.byteCount.multipliedReportingOverflow(by: 2)
				guard !overflow else {
					throw NativeModelFasterRCNNRegistryError.weightBlobIsNotContiguous(weight: weight.name)
				}
				promotedByteCount = doubled
			case .float32:
				promotedByteCount = weight.byteCount
			case .unsupported:
				preconditionFailure("The closed Faster R-CNN registry contains floating-point weights only.")
			}
			promotedWeights.append(NativeModelWeight(
				name: weight.name,
				dataType: .float32,
				shape: weight.shape,
				offset: promotedOffset,
				byteCount: promotedByteCount
			))
			let (nextOffset, overflow) = promotedOffset.addingReportingOverflow(promotedByteCount)
			guard !overflow else {
				throw NativeModelFasterRCNNRegistryError.weightBlobIsNotContiguous(weight: weight.name)
			}
			promotedOffset = nextOffset
		}

		self.sourceURL = weightURL
		self.sourceWeightByteCount = sourceWeightByteCount
		self.synthesizedWeightData = synthesizedWeightData
		self.originalWeightsByName = originalByName
		self.originsByName = origins
		self.sha256 = ""
		self.graph = NativeModelGraph(
			formatVersion: sourceGraph.formatVersion,
			producer: sourceGraph.producer,
			inputs: sourceGraph.inputs,
			weights: promotedWeights,
			operations: sourceGraph.operations,
			outputs: sourceGraph.outputs
		)

		var digest = SHA256()
		for weight in orderedWeights {
			try stream(weightNamed: weight.name, checkingCancellation: cancellationCheck) { chunk in
				digest.update(data: chunk)
			}
		}
		sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
	}

	func payload(
		for promotedWeight: NativeModelWeight,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler?
	) throws -> CoreMLProtobufDeferredPayload {
		guard let original = originalWeightsByName[promotedWeight.name],
			promotedWeight.dataType == .float32,
			promotedWeight.byteCount == promotedByteCount(for: original)
		else {
			throw NativeModelCoreMLEmissionError.missingWeight(promotedWeight.name)
		}
		return CoreMLProtobufDeferredPayload(byteCount: promotedWeight.byteCount) { [self] handle in
			try stream(weightNamed: original.name, checkingCancellation: cancellationCheck) { chunk in
				try handle.write(contentsOf: chunk)
			}
		}
	}

	private func promotedByteCount(for weight: NativeModelWeight) -> UInt64 {
		switch weight.dataType {
		case .float16: weight.byteCount * 2
		case .float32: weight.byteCount
		case .unsupported: 0
		}
	}

	private func stream(
		weightNamed name: String,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler?,
		receive: (Data) throws -> Void
	) throws {
		guard let original = originalWeightsByName[name], let origin = originsByName[name] else {
			throw NativeModelCoreMLEmissionError.missingWeight(name)
		}
		switch origin {
		case .extracted(let offset):
			let handle = try FileHandle(forReadingFrom: sourceURL)
			defer { try? handle.close() }
			try handle.seek(toOffset: offset)
			var remaining = original.byteCount
			while remaining > 0 {
				try cancellationCheck?()
				let inputCount = min(Int(remaining), Self.chunkByteCount / 2)
				guard let input = try handle.read(upToCount: inputCount), input.count == inputCount else {
					throw NativeModelFasterRCNNRegistryError.weightDataLengthMismatch(
						expected: sourceWeightByteCount,
						actual: offset + (original.byteCount - remaining)
					)
				}
				var promoted = Data()
				promoted.reserveCapacity(input.count * 2)
				for (elementIndex, index) in stride(from: input.startIndex, to: input.endIndex, by: 2).enumerated() {
					if elementIndex.isMultiple(of: 4_096) { try cancellationCheck?() }
					let bits = UInt16(input[index]) | UInt16(input[index + 1]) << 8
					var value = Float(Float16(bitPattern: bits)).bitPattern.littleEndian
					withUnsafeBytes(of: &value) { promoted.append(contentsOf: $0) }
				}
				try receive(promoted)
				remaining -= UInt64(inputCount)
			}
		case .synthesized(let offset):
			var remaining = original.byteCount
			var cursor = offset
			while remaining > 0 {
				try cancellationCheck?()
				let count = min(Int(remaining), Self.chunkByteCount)
				let start = Int(cursor)
				let end = start + count
				try receive(Data(synthesizedWeightData[start..<end]))
				cursor += UInt64(count)
				remaining -= UInt64(count)
			}
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
