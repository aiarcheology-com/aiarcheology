//
//  NativeModelFasterRCNNRegistry.swift
//  NativeModelConverter
//
//  The pinned ADAF Faster R-CNN architecture and its loadable Core ML graph (AIA-0685 through AIA-0687).
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

	/// Builds the graph skeleton from the closed architecture registry.
	///
	/// This graph deliberately remains a structural, not numerical, claim. Its RPN still selects
	/// anchor candidates rather than consuming the regression and ROI-head paths; that replacement is
	/// a later assembled-graph step. It does emit the boundary-corrected ROI alignment construction for
	/// one selected candidate at each pooled FPN level, so the real artifact carries the replicated ring
	/// and feature-pixel shift without materialising the host-side ROI batch in its primary graph. The
	/// terminal path is nevertheless complete: candidates are corners in the graph IR, converted
	/// immediately before the first Core ML NMS layer, and pass through both measured ADAF suppression
	/// passes. The post-suppression score mask makes Core ML's false zero-survivor slot padding again;
	/// AIA-0688 is where a reference oracle may change parity provenance.
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
			let anchorCorners = try anchorCorners(for: fpn)
			let candidates = try selectTerminalCandidates(scores: candidateScores, corners: anchorCorners)
			emitROIEdgeAlignment(features: fpn, selectedCorners: candidates.corners)
			let proposal = terminalSuppressions(corners: candidates.corners, scores: candidates.scores)

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

		mutating func anchorCorners(for features: [Activation]) throws -> String {
			let values = try normalizedAnchorCorners(for: features)
			let count = values.count / 4
			return constant(values: values, output: "frcnn.rpn.anchor_corners", shape: [1, count, 4])
		}

		/// Selects the fixed terminal candidate budget while retaining the graph IR's corner convention.
		/// The previous loadability graph exposed its synthesized anchors in NMS centre-size order, which
		/// made it dangerously easy to hand the next operation coordinates whose convention was implicit.
		/// This boundary now names corners until `cornerBoxesToCentreSize` immediately precedes the first
		/// NMS layer.
		mutating func selectTerminalCandidates(scores: String, corners: String) throws -> (corners: String, scores: String) {
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
			let gathered = "frcnn.rpn.selected_corner_rank4"
			operations.append(NativeModelOperation(
				name: "frcnn.rpn.gather_corners", kind: .gather, inputs: [corners, indices],
				outputs: [NativeModelTensor(name: gathered, dataType: .float32, shape: [1, 1, proposalCount, 4])],
				attributes: ["axis": .integer(1)]
			))
			return (
				reshape(gathered, output: "frcnn.rpn.selected_corners", shape: [1, proposalCount, 4]),
				reshape(values, output: "frcnn.rpn.selected_scores", shape: [1, proposalCount, 1])
			)
		}

		/// Emits the edge-corrected `roi_align` construction at every FPN level that torchvision's
		/// `MultiScaleRoIAlign` pools (`P2` through `P5`). `P6` feeds the RPN but is not a box-head pool
		/// level. The primary graph carries one real selected candidate at each level: that pins the exact
		/// operation sequence and keeps the primary's structural-loadability budget separate from the
		/// fixed-52 host-side ROI chunk measured in AIA-0670. The future chunk replaces this bounded path
		/// with its batch input; it must preserve this ring and shift exactly.
		///
		/// `CropResize` zeros samples outside its feature tensor where torchvision's `roi_align` clamps.
		/// Prepending/appending the actual border cells makes the ring replicate instead, and adding
		/// `1 / spatialScale` image pixels makes the original feature origin `[1, 1]` in that ring. The
		/// candidate corners are normalized in the current structural RPN path, so they are first restored
		/// to the 1344-image frame and reordered from `[x0, y0, x1, y1]` to CropResize's `[y0, x0, y1, x1]`.
		mutating func emitROIEdgeAlignment(features: [Activation], selectedCorners: String) {
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

				let selected = sliceND(
					selectedCorners, output: "\(prefix).selected_corners",
					begin: [0, index, 0], end: [1, index + 1, 4], shape: [1, 1, 4]
				)
				let imageCorners = binary(
					.multiply, selected, imageScale, output: "\(prefix).image_corners", shape: [1, 1, 4]
				)
				let components = ["x0", "y0", "x1", "y1"].map { "\(prefix).corner_\($0)" }
				operations.append(NativeModelOperation(
					name: "\(prefix).split_corners", kind: .splitND, inputs: [imageCorners],
					outputs: components.map { NativeModelTensor(name: $0, dataType: .float32, shape: [1, 1, 1]) },
					attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
				))
				let cropCorners = concatenate(
					[components[1], components[0], components[3], components[2]], output: "\(prefix).crop_corners",
					shape: [1, 1, 4], axis: 2
				)
				let boxes = reshape(cropCorners, output: "\(prefix).boxes", shape: [1, 1, 4, 1, 1])
				let spatialScale = Double(feature.width) / Double(NativeModelFasterRCNNRegistry.architecture.canvas.width)
				let shift = constant(
					values: [Float](repeating: Float(1 / spatialScale), count: 4), output: "\(prefix).feature_pixel_shift",
					shape: [1, 1, 4, 1, 1]
				)
				let shiftedBoxes = binary(
					.add, boxes, shift, output: "\(prefix).shifted_boxes", shape: [1, 1, 4, 1, 1]
				)
				let cropped = "\(prefix).crop_resize"
				operations.append(NativeModelOperation(
					name: cropped, kind: .cropResize, inputs: [ring, shiftedBoxes],
					outputs: [NativeModelTensor(name: cropped, dataType: .float32, shape: [1, 1, feature.channels, 14, 14])],
					attributes: [
						"targetHeight": .integer(14), "targetWidth": .integer(14),
						"spatialScale": .floatingPoint(spatialScale)
					]
				))
				let pooled = "\(prefix).roi_align"
				operations.append(NativeModelOperation(
					name: pooled, kind: .averagePool2D, inputs: [cropped],
					outputs: [NativeModelTensor(name: pooled, dataType: .float32, shape: [1, 1, feature.channels, 7, 7])],
					attributes: [
						"kernelSize": .integers([2, 2]), "strides": .integers([2, 2]), "padding": .integers([0, 0])
					]
				))
			}
		}

		/// Applies both measured terminal passes. In this structural loadability slice the first pass applies
		/// torchvision's 0.05 / 0.5 / top-100 values to RPN objectness scores; torchvision itself applies
		/// its score floor to ROI-head class scores. The second is ADAF's additional class-agnostic 0.2 pass.
		/// They are intentionally separate: M3a observed different results in all 200 trials when one 0.2
		/// pass replaced the pair.
		mutating func terminalSuppressions(corners: String, scores: String) -> (coordinates: String, confidence: String) {
			let scoreThreshold = 0.05
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
			let componentShape = [1, count, 1]
			let components = ["x0", "y0", "x1", "y1"].map { "frcnn.postprocess.corner_\($0)" }
			operations.append(NativeModelOperation(
				name: "frcnn.postprocess.split_corners", kind: .splitND, inputs: [corners],
				outputs: components.map { NativeModelTensor(name: $0, dataType: .float32, shape: componentShape) },
				attributes: ["axis": .integer(2), "splitSizes": .integers([1, 1, 1, 1])]
			))
			let half = constant(values: [Float](repeating: 0.5, count: count), output: "frcnn.postprocess.half", shape: componentShape)
			let centerXSum = binary(.add, components[0], components[2], output: "frcnn.postprocess.center_x_sum", shape: componentShape)
			let centerYSum = binary(.add, components[1], components[3], output: "frcnn.postprocess.center_y_sum", shape: componentShape)
			let centerX = binary(.multiply, centerXSum, half, output: "frcnn.postprocess.center_x", shape: componentShape)
			let centerY = binary(.multiply, centerYSum, half, output: "frcnn.postprocess.center_y", shape: componentShape)
			let width = binary(.subtract, components[2], components[0], output: "frcnn.postprocess.width", shape: componentShape)
			let height = binary(.subtract, components[3], components[1], output: "frcnn.postprocess.height", shape: componentShape)
			return concatenate(
				[centerX, centerY, width, height], output: "frcnn.postprocess.centre_size",
				shape: [1, count, 4], axis: 2
			)
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

		func flattenedCandidateCount(_ logits: [Activation]) -> Int {
			logits.reduce(0) { $0 + $1.channels * $1.height * $1.width }
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
				for ratio in NativeModelFasterRCNNRegistry.architecture.anchorAspectRatios {
					let width = size * sqrt(1 / ratio) / Double(canvas.width)
					let height = size * sqrt(ratio) / Double(canvas.height)
					for row in 0..<feature.height {
						for column in 0..<feature.width {
							let centerX = Double(column) * strideX / Double(canvas.width)
							let centerY = Double(row) * strideY / Double(canvas.height)
							values.append(Float(centerX - width / 2))
							values.append(Float(centerY - height / 2))
							values.append(Float(centerX + width / 2))
							values.append(Float(centerY + height / 2))
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
