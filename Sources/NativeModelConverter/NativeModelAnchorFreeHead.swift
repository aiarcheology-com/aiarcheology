//
//  NativeModelAnchorFreeHead.swift
//  NativeModelConverter
//
//  Reshapes an already-decoded anchor-free detection tensor into the coordinates/confidence pair
//  Core ML's non-maximum-suppression stage consumes.
//

import Foundation

/// Adapts the decoded output of an anchor-free detector (YOLOv8/YOLO11 and relatives) to the
/// `coordinates`/`confidence` interface the suppression stage reads.
///
/// Unlike the anchor-based head, these detectors bake the decode into their exported graph: the
/// tensor that reaches here is already `[1, 4 + classes, boxes]` with box centres/sizes in place and
/// per-class scores pushed through sigmoid. There is no objectness channel, no anchor table, and no
/// softmax to apply. What remains is purely structural — split geometry from scores, then move the
/// box axis into rows so row *i* of both outputs describes the same box — plus an optional
/// pixels→normalized rescale for graphs whose boxes are still in input-pixel units.
///
/// Like `NativeModelYOLOHead`, it is a *planner*: it appends generic operations and plain constants,
/// so no coordinate arithmetic leaks into the reader or the emitter.
public enum NativeModelAnchorFreeHead {

	/// Whether the graph already emits normalized boxes, or boxes still measured in input pixels that
	/// this planner must divide down.
	public enum CoordinateMode: Equatable, Sendable {
		/// Boxes are already 0–1; no rescale is planned.
		case normalizedByGraph
		/// Boxes are in pixels of a `width`×`height` input and must be divided to reach 0–1.
		case pixelsOfInput(width: Int, height: Int)
	}

	/// The decode, ready to append to a graph.
	public struct Plan: Equatable, Sendable {
		public let operations: [NativeModelOperation]
		public let weights: [NativeModelWeight]
		/// Constant payload to append to the graph's weight blob, at the offset the plan was built for.
		public let weightData: Data
		public let interface: NativeModelDetectionInterface
	}

	/// The largest box count the planner accepts. A 640² v8/v11 head emits 8400 boxes; the ceiling is
	/// far above any real head and exists only to decline a crafted tensor whose box axis is huge —
	/// bytes-cheap to declare but expensive to materialize as the `[4, N, 1]` pixel-scale constant.
	/// The anchor-based head's `maximumGridSize` is a square-grid check that has no analogue here, so
	/// this flat cap on the box axis is its anchor-free counterpart.
	public static let maximumBoxCount = 200_000

	public enum PlanError: Error, Equatable, LocalizedError, Sendable {
		case notAPredictionTensor(shape: [Int])
		case tooFewChannels(channels: Int)
		case classCountMismatch(channels: Int, labels: Int)
		case tooManyBoxes(count: Int)
		case noLabels
		case invalidCoordinateScale(width: Int, height: Int)

		public var errorDescription: String? {
			switch self {
			case .notAPredictionTensor(let shape):
				"An anchor-free head needs a decoded [1, 4 + classes, boxes] prediction tensor; got \(shape)."
			case .tooFewChannels(let channels):
				"A prediction tensor needs at least four box channels plus one class; got \(channels)."
			case .classCountMismatch(let channels, let labels):
				"A tensor with \(channels) channels does not match 4 box channels + \(labels) class labels."
			case .tooManyBoxes(let count):
				"A \(count)-box tensor exceeds the supported maximum of \(maximumBoxCount) boxes."
			case .noLabels: "An anchor-free head requires at least one class label."
			case .invalidCoordinateScale(let width, let height):
				"Pixel-space boxes need a positive input size to normalize by; got \(width)×\(height)."
			}
		}
	}

	/// Plans the adaptation for `output`, the detector's decoded `[1, 4 + classCount, N]` tensor.
	///
	/// Channels `0..<4` are box `(cx, cy, w, h)`; the remaining `classCount` channels are per-class
	/// scores already in `[0, 1]`. `weightOffset` is where the plan's constants live in the graph's
	/// weight blob — normally the current blob length.
	public static func plan(
		output: NativeModelTensor,
		classCount: Int,
		labels: [String],
		coordinateMode: CoordinateMode,
		weightOffset: UInt64,
		formatVersion: Int = NativeModelGraph.legacyFormatVersion,
		namePrefix: String = "af"
	) throws -> Plan {
		guard !labels.isEmpty else { throw PlanError.noLabels }
		let shape = output.shape
		// A decoded head is rank-3 `[1, channels, boxes]` with at least the four geometry channels and
		// one class channel, and more than one box. Anything else — a rank-4 grid, a stray classifier
		// tensor — is not something this head can split.
		guard shape.count == 3, shape[0] == 1, shape[1] >= 5, shape[2] > 1 else {
			throw PlanError.notAPredictionTensor(shape: shape)
		}
		let channels = shape[1]
		let boxCount = shape[2]
		guard classCount >= 1 else { throw PlanError.tooFewChannels(channels: 4 + classCount) }
		// The tensor's channel count and the label list must both agree with the declared class count;
		// a disagreement would slice scores against the wrong column boundary and pair boxes with the
		// wrong labels — silent at compile time.
		guard channels == 4 + classCount, labels.count == classCount else {
			throw PlanError.classCountMismatch(channels: channels, labels: labels.count)
		}
		guard boxCount <= Self.maximumBoxCount else {
			throw PlanError.tooManyBoxes(count: boxCount)
		}

		var builder = Builder(prefix: namePrefix, weightOffset: weightOffset, usesExactND: formatVersion == NativeModelGraph.exactNDFormatVersion)

		// Separate geometry from class scores along the channel axis of the packed `[1, C, N]` tensor.
		let boxSlice = builder.slice(output.name, from: 0, to: 4, shape: [1, 4, boxCount], name: "box")
		let scoreSlice = builder.slice(output.name, from: 4, to: 4 + classCount, shape: [1, classCount, boxCount], name: "scores")

		// Bring each attribute onto its own channel with the box axis behind it, so a following permute
		// turns box index into the row index the suppression stage expects.
		let boxColumnShape = builder.usesExactND ? [1, 4, boxCount, 1] : [4, boxCount, 1]
		let scoreColumnShape = builder.usesExactND ? [1, classCount, boxCount, 1] : [classCount, boxCount, 1]
		var box = builder.reshape(boxSlice, to: [1, 4, boxCount, 1], shape: boxColumnShape, name: "box_column")
		let scores = builder.reshape(scoreSlice, to: [1, classCount, boxCount, 1], shape: scoreColumnShape, name: "score_column")

		// Pixel-space boxes become 0–1 by scaling (cx, w) by 1/width and (cy, h) by 1/height. The scale
		// is a full `[4, N, 1]` constant — one factor per channel, repeated across every box — because
		// classic Core ML multiply is per-position, not broadcast per-channel here.
		if case let .pixelsOfInput(width, height) = coordinateMode {
			// A zero or negative input size cannot normalize pixels (it would bake infinities into the
			// scale constant); reject it rather than emit a NaN-producing model.
			guard width > 0, height > 0 else { throw PlanError.invalidCoordinateScale(width: width, height: height) }
			let scale = builder.constant(
				values: Self.inverseSizeScale(width: width, height: height, boxCount: boxCount),
				shape: boxColumnShape, name: "pixel_scale"
			)
			box = builder.binary(.multiply, [box, scale], shape: boxColumnShape, name: "box_normalized")
		}

		// [box, attribute, 1] — the row-major layout Core ML's suppression consumes.
		let coordinatesShape = builder.usesExactND ? [1, boxCount, 4, 1] : [boxCount, 4, 1]
		let confidenceShape = builder.usesExactND ? [1, boxCount, classCount, 1] : [boxCount, classCount, 1]
		let coordinates = builder.transpose(box, permutation: [0, 2, 1, 3], shape: coordinatesShape, name: "coordinates")
		let confidence = builder.transpose(scores, permutation: [0, 2, 1, 3], shape: confidenceShape, name: "confidence")

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

	/// Per-channel inverse-size factors laid out as channel = attribute, replicated over every box, to
	/// match the `[4, N, 1]` box tensor the multiply scales. cx and w take 1/width; cy and h take
	/// 1/height.
	static func inverseSizeScale(width: Int, height: Int, boxCount: Int) -> [Float] {
		let inverseWidth = 1 / Float(width)
		let inverseHeight = 1 / Float(height)
		let perChannel = [inverseWidth, inverseHeight, inverseWidth, inverseHeight]
		var values = [Float](repeating: 0, count: 4 * boxCount)
		for channel in 0 ..< 4 {
			for box in 0 ..< boxCount {
				values[channel * boxCount + box] = perChannel[channel]
			}
		}
		return values
	}

	/// Accumulates operations and constants while keeping blob naming and weight offsets consistent.
	/// Mirrors `NativeModelYOLOHead.Builder`; only the op helpers this thinner head needs are kept.
	private struct Builder {
		let prefix: String
		let usesExactND: Bool
		var operations: [NativeModelOperation] = []
		var weights: [NativeModelWeight] = []
		var weightData = Data()
		private let weightOffset: UInt64

		init(prefix: String, weightOffset: UInt64, usesExactND: Bool) {
			self.prefix = prefix
			self.weightOffset = weightOffset
			self.usesExactND = usesExactND
		}

		private func name(_ suffix: String) -> String { "\(prefix)_\(suffix)" }

		mutating func constant(values: [Float], shape: [Int], name suffix: String) -> String {
			let weightName = name("\(suffix)_values")
			let payload = values.withUnsafeBytes { Data($0) }
			weights.append(NativeModelWeight(
				name: weightName, dataType: .float32, shape: shape,
				offset: weightOffset + UInt64(weightData.count), byteCount: UInt64(payload.count)
			))
			weightData.append(payload)
			return record(usesExactND ? .constantND : .constant, inputs: [weightName], shape: shape, name: suffix)
		}

		mutating func reshape(_ input: String, to target: [Int], shape: [Int], name suffix: String) -> String {
			record(usesExactND ? .reshapeND : .reshape, inputs: [input], shape: shape, name: suffix, attributes: ["shape": .integers(target)])
		}

		mutating func transpose(_ input: String, permutation: [Int], shape: [Int], name suffix: String) -> String {
			record(usesExactND ? .transposeND : .transpose, inputs: [input], shape: shape, name: suffix, attributes: ["permutation": .integers(permutation)])
		}

		mutating func slice(_ input: String, from start: Int, to end: Int, shape: [Int], name suffix: String) -> String {
			if usesExactND {
				return record(.sliceND, inputs: [input], shape: shape, name: suffix, attributes: [
					"beginIds": .integers([0, start, 0]), "endIds": .integers([1, end, shape[2]]), "strides": .integers([1, 1, 1])
				])
			}
			return record(.sliceChannels, inputs: [input], shape: shape, name: suffix, attributes: [
				"startChannel": .integer(start), "endChannel": .integer(end)
			])
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
