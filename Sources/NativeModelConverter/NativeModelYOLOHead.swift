//
//  NativeModelYOLOHead.swift
//  NativeModelConverter
//
//  Synthesizes the box decode that YOLO-style detectors leave out of their exported graph.
//

import Foundation

/// Builds the operations that turn a raw YOLO grid tensor into the `coordinates`/`confidence`
/// pair Core ML's non-maximum-suppression stage consumes.
///
/// Detectors of this family export only the convolutional trunk: the graph ends at a
/// `[1, A·(5 + C), S, S]` tensor of *logits*, and the decode — sigmoid on the box centre and
/// objectness, exponential on the box size, anchor scaling, grid offsets, softmax over classes —
/// lives in the framework's post-processing rather than in the model. Core ML has no such
/// post-processing hook, so the decode is expressed here as ordinary layers.
///
/// It is deliberately a *planner*, not emitter logic: it appends generic operations to the graph and
/// hands back plain constants. No YOLO arithmetic leaks into the reader or the emitter, and anchors
/// arrive as caller-supplied configuration rather than being inferred.
public enum NativeModelYOLOHead {

	/// A prior box size, expressed in grid cells — the unit YOLO anchor tables are published in.
	public struct Anchor: Equatable, Sendable {
		public let width: Double
		public let height: Double

		public init(width: Double, height: Double) {
			self.width = width
			self.height = height
		}
	}

	/// The decode, ready to append to a graph.
	public struct Plan: Equatable, Sendable {
		public let operations: [NativeModelOperation]
		public let weights: [NativeModelWeight]
		/// Constant payload to append to the graph's weight blob, at the offset the plan was built for.
		public let weightData: Data
		public let interface: NativeModelDetectionInterface
	}

	/// The largest grid edge the planner will decode. Real YOLOv2-family heads use 13/26-cell grids;
	/// the cap exists because the decode materializes dense `2·A·S²`-element constants, so a crafted
	/// model declaring a huge grid — bytes-cheap on disk — would otherwise balloon memory during
	/// planning.
	public static let maximumGridSize = 128

	public enum PlanError: Error, Equatable, LocalizedError, Sendable {
		case notAGridTensor(shape: [Int])
		case gridTooLarge(size: Int)
		case channelMismatch(channels: Int, anchors: Int, labels: Int)
		case noAnchors
		case invalidAnchor(width: Double, height: Double)
		case noLabels

		public var errorDescription: String? {
			switch self {
			case .notAGridTensor(let shape):
				"A YOLO head needs a square [1, anchors · (5 + classes), size, size] grid; got \(shape)."
			case .gridTooLarge(let size):
				"A \(size)×\(size) grid exceeds the supported maximum of \(maximumGridSize)×\(maximumGridSize) cells."
			case .channelMismatch(let channels, let anchors, let labels):
				"A grid with \(channels) channels does not match \(anchors) anchors × (5 + \(labels) classes)."
			case .noAnchors: "A YOLO head requires at least one anchor."
			case .invalidAnchor(let width, let height):
				"Anchor \(width)×\(height) must have finite, positive dimensions."
			case .noLabels: "A YOLO head requires at least one class label."
			}
		}
	}

	/// Plans the decode for `grid`, which must be the `[1, A·(5 + C), S, S]` output of the trunk.
	///
	/// `weightOffset` is where the plan's constants will live in the graph's weight blob — normally
	/// the current blob length.
	public static func plan(
		grid: NativeModelTensor,
		anchors: [Anchor],
		labels: [String],
		weightOffset: UInt64,
		namePrefix: String = "yolo"
	) throws -> Plan {
		guard !anchors.isEmpty else { throw PlanError.noAnchors }
		// A non-finite or non-positive anchor would bake NaN/zero box sizes into the constants and
		// surface only as garbage geometry at inference.
		for anchor in anchors where !(anchor.width.isFinite && anchor.height.isFinite && anchor.width > 0 && anchor.height > 0) {
			throw PlanError.invalidAnchor(width: anchor.width, height: anchor.height)
		}
		guard !labels.isEmpty else { throw PlanError.noLabels }
		let shape = grid.shape
		guard shape.count == 4, shape[0] == 1, shape[2] > 0, shape[2] == shape[3] else {
			throw PlanError.notAGridTensor(shape: shape)
		}
		let size = shape[2]
		guard size <= Self.maximumGridSize else {
			throw PlanError.gridTooLarge(size: size)
		}
		let anchorCount = anchors.count
		let classCount = labels.count
		let attributeCount = 5 + classCount
		guard shape[1] == anchorCount * attributeCount else {
			throw PlanError.channelMismatch(channels: shape[1], anchors: anchorCount, labels: classCount)
		}

		let cells = size * size
		let boxCount = anchorCount * cells
		var builder = Builder(prefix: namePrefix, weightOffset: weightOffset)

		// Regroup the packed grid so each box attribute sits on its own channel:
		// [1, A·K, S, S] -> (A, K, S²) -> (K, A, S²). Box b is then anchor·S² + row·S + col
		// throughout, which is the order every constant below is generated in.
		let regrouped = builder.reshape(grid.name, to: [1, anchorCount, attributeCount, cells], shape: [anchorCount, attributeCount, cells], name: "grid_regrouped")
		let attributeMap = builder.transpose(regrouped, permutation: [0, 2, 1, 3], shape: [attributeCount, anchorCount, cells], name: "grid_attributes")

		let coordinates = builder.decodeBoxes(attributeMap: attributeMap, anchors: anchors, size: size)
		let confidence = builder.decodeScores(
			attributeMap: attributeMap, classCount: classCount, anchorCount: anchorCount, size: size
		)

		return Plan(
			operations: builder.operations,
			weights: builder.weights,
			weightData: builder.weightData,
			interface: NativeModelDetectionInterface(
				labels: labels,
				boxCount: boxCount,
				coordinatesBlobName: coordinates,
				confidenceBlobName: confidence
			)
		)
	}

	/// Accumulates operations and constants while keeping blob naming and weight offsets consistent.
	private struct Builder {
		let prefix: String
		var operations: [NativeModelOperation] = []
		var weights: [NativeModelWeight] = []
		var weightData = Data()
		private let weightOffset: UInt64

		init(prefix: String, weightOffset: UInt64) {
			self.prefix = prefix
			self.weightOffset = weightOffset
		}

		private func name(_ suffix: String) -> String { "\(prefix)_\(suffix)" }

		/// Box geometry: centres from a sigmoid offset into the cell, sizes from an exponential
		/// scaling of the anchor. Both are normalized to 0–1 by folding 1/S into the constants, which
		/// avoids a separate scaling layer.
		mutating func decodeBoxes(attributeMap: String, anchors: [Anchor], size: Int) -> String {
			let anchorCount = anchors.count
			let cells = size * size
			let boxCount = anchorCount * cells
			let inverseSize = 1.0 / Double(size)

			let centreLogits = slice(attributeMap, from: 0, to: 2, shape: [2, anchorCount, cells], name: "centre_logits")
			let centreInCell = activation(centreLogits, kind: .sigmoid, shape: [2, anchorCount, cells], name: "centre_in_cell")
			let centreColumn = reshape(centreInCell, to: [1, 2, boxCount, 1], shape: [2, boxCount, 1], name: "centre_column")
			// centre = cellOrigin + offsetWithinCell / S, both already divided by S.
			let cellScale = constant(
				values: [Float](repeating: Float(inverseSize), count: 2 * boxCount),
				shape: [2, boxCount, 1], name: "cell_scale"
			)
			let scaledCentre = binary(.multiply, [centreColumn, cellScale], shape: [2, boxCount, 1], name: "centre_scaled")
			let cellOrigin = constant(
				values: Self.cellOrigins(size: size, anchorCount: anchorCount),
				shape: [2, boxCount, 1], name: "cell_origin"
			)
			let centre = binary(.add, [cellOrigin, scaledCentre], shape: [2, boxCount, 1], name: "centre")

			let sizeLogits = slice(attributeMap, from: 2, to: 4, shape: [2, anchorCount, cells], name: "size_logits")
			let sizeFactor = activation(sizeLogits, kind: .exponential, shape: [2, anchorCount, cells], name: "size_factor")
			// Back to the grid layout the anchor table is laid out in: channel = axis · A + anchor.
			let sizeGrid = reshape(sizeFactor, to: [1, 2 * anchorCount, size, size], shape: [2 * anchorCount, size, size], name: "size_grid")
			let anchorSizes = constant(
				values: Self.anchorSizes(anchors, size: size),
				shape: [2 * anchorCount, size, size], name: "anchor_sizes"
			)
			let scaledSize = binary(.multiply, [anchorSizes, sizeGrid], shape: [2 * anchorCount, size, size], name: "size_scaled")
			let sizeColumn = reshape(scaledSize, to: [1, 2, boxCount, 1], shape: [2, boxCount, 1], name: "size_column")

			// [centreX, centreY, width, height] per box — the order Core ML's suppression expects.
			let boxes = binary(.concatenate, [centre, sizeColumn], shape: [4, boxCount, 1], name: "boxes", attributes: ["axis": .integer(1)])
			return transpose(boxes, permutation: [0, 2, 1, 3], shape: [boxCount, 4, 1], name: "coordinates")
		}

		/// Per-class confidence: objectness times the class distribution, which is how YOLO scores a
		/// box. The two are on different channel counts, so objectness is tiled first.
		mutating func decodeScores(attributeMap: String, classCount: Int, anchorCount: Int, size: Int) -> String {
			let cells = size * size
			let boxCount = anchorCount * cells
			let objectnessLogit = slice(attributeMap, from: 4, to: 5, shape: [1, anchorCount, cells], name: "objectness_logit")
			let objectness = activation(objectnessLogit, kind: .sigmoid, shape: [1, anchorCount, cells], name: "objectness")
			let classLogits = slice(attributeMap, from: 5, to: 5 + classCount, shape: [classCount, anchorCount, cells], name: "class_logits")
			let classProbabilities = activation(classLogits, kind: .softmaxChannel, shape: [classCount, anchorCount, cells], name: "class_probabilities")

			// A single-class head needs no tiling, and concat requires two inputs anyway.
			let weighted: String
			if classCount == 1 {
				weighted = binary(.multiply, [objectness, classProbabilities], shape: [classCount, anchorCount, cells], name: "weighted")
			} else {
				let tiled = binary(
					.concatenate, Array(repeating: objectness, count: classCount),
					shape: [classCount, anchorCount, cells], name: "objectness_tiled",
					attributes: ["axis": .integer(1)]
				)
				weighted = binary(.multiply, [tiled, classProbabilities], shape: [classCount, anchorCount, cells], name: "weighted")
			}
			let column = reshape(weighted, to: [1, classCount, boxCount, 1], shape: [classCount, boxCount, 1], name: "confidence_column")
			return transpose(column, permutation: [0, 2, 1, 3], shape: [boxCount, classCount, 1], name: "confidence")
		}

		// MARK: Constants

		/// Normalized cell origins in box order: `anchor · S² + row · S + column`, x channel then y.
		static func cellOrigins(size: Int, anchorCount: Int) -> [Float] {
			let inverseSize = Float(1.0 / Double(size))
			var values = [Float](repeating: 0, count: 2 * anchorCount * size * size)
			let boxCount = anchorCount * size * size
			for anchor in 0 ..< anchorCount {
				for row in 0 ..< size {
					for column in 0 ..< size {
						let box = anchor * size * size + row * size + column
						values[box] = Float(column) * inverseSize
						values[boxCount + box] = Float(row) * inverseSize
					}
				}
			}
			return values
		}

		/// Normalized anchor sizes replicated over every cell, laid out as channel = axis · A + anchor
		/// to match the reshaped size tensor.
		static func anchorSizes(_ anchors: [Anchor], size: Int) -> [Float] {
			let inverseSize = 1.0 / Double(size)
			var values = [Float](repeating: 0, count: 2 * anchors.count * size * size)
			for (index, anchor) in anchors.enumerated() {
				let width = Float(anchor.width * inverseSize)
				let height = Float(anchor.height * inverseSize)
				for cell in 0 ..< (size * size) {
					values[index * size * size + cell] = width
					values[(anchors.count + index) * size * size + cell] = height
				}
			}
			return values
		}

		// MARK: Operation helpers

		mutating func constant(values: [Float], shape: [Int], name suffix: String) -> String {
			let weightName = name("\(suffix)_values")
			let payload = values.withUnsafeBytes { Data($0) }
			weights.append(NativeModelWeight(
				name: weightName, dataType: .float32, shape: shape,
				offset: weightOffset + UInt64(weightData.count), byteCount: UInt64(payload.count)
			))
			weightData.append(payload)
			return record(.constant, inputs: [weightName], shape: shape, name: suffix)
		}

		mutating func reshape(_ input: String, to target: [Int], shape: [Int], name suffix: String) -> String {
			record(.reshape, inputs: [input], shape: shape, name: suffix, attributes: ["shape": .integers(target)])
		}

		mutating func transpose(_ input: String, permutation: [Int], shape: [Int], name suffix: String) -> String {
			record(.transpose, inputs: [input], shape: shape, name: suffix, attributes: ["permutation": .integers(permutation)])
		}

		mutating func slice(_ input: String, from start: Int, to end: Int, shape: [Int], name suffix: String) -> String {
			record(.sliceChannels, inputs: [input], shape: shape, name: suffix, attributes: [
				"startChannel": .integer(start), "endChannel": .integer(end)
			])
		}

		mutating func activation(_ input: String, kind: NativeModelOperationKind, shape: [Int], name suffix: String) -> String {
			record(kind, inputs: [input], shape: shape, name: suffix)
		}

		mutating func binary(
			_ kind: NativeModelOperationKind, _ inputs: [String], shape: [Int],
			name suffix: String, attributes: [String: NativeModelAttribute] = [:]
		) -> String {
			record(kind, inputs: inputs, shape: shape, name: suffix, attributes: attributes)
		}

		private mutating func record(
			_ kind: NativeModelOperationKind, inputs: [String], shape: [Int],
			name suffix: String, attributes: [String: NativeModelAttribute] = [:]
		) -> String {
			let output = name(suffix)
			operations.append(NativeModelOperation(
				name: output, kind: kind, inputs: inputs,
				outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)],
				attributes: attributes
			))
			return output
		}
	}
}
