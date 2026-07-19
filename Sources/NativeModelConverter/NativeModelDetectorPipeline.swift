//
//  NativeModelDetectorPipeline.swift
//  NativeModelConverter
//
//  Emits the Core ML *pipeline* wrapper that turns a raw-output detection network into a model
//  Vision reads as an object detector.
//

import Foundation

/// How a converted detection graph is exposed to Vision.
///
/// A detector cannot be a single neural network: Vision only produces
/// `VNRecognizedObjectObservation` for a model whose final stage is Core ML's built-in
/// non-maximum-suppression model. So the emitter writes a two-stage pipeline — the converted
/// network, then NMS — and the app's existing detector driver needs no changes, because
/// `ModelLoadingService.inferType` recognizes a detector purely from outputs named `coordinates`
/// and `confidence`.
///
/// `coordinatesBlobName` must carry **center-x, center-y, width, height, normalized to 0–1**, and
/// row *i* of it must describe the same box as row *i* of `confidenceBlobName`. Both invariants
/// survive compilation silently when broken, so they are asserted numerically in the tests rather
/// than trusted.
public struct NativeModelDetectionInterface: Equatable, Sendable {
	/// Class labels, one per column of the confidence matrix.
	public let labels: [String]
	/// Rows in both stage-one outputs — the number of candidate boxes before suppression.
	public let boxCount: Int
	/// The graph output holding `[boxCount, 4]` box geometry.
	public let coordinatesBlobName: String
	/// The graph output holding `[boxCount, labels.count]` per-class confidence.
	public let confidenceBlobName: String
	/// Default suppression IoU; also exposed as an optional model input so the app can tune it.
	public let iouThreshold: Double
	/// Default score floor; also exposed as an optional model input.
	public let confidenceThreshold: Double

	public init(
		labels: [String],
		boxCount: Int,
		coordinatesBlobName: String,
		confidenceBlobName: String,
		iouThreshold: Double = 0.45,
		confidenceThreshold: Double = 0.25
	) {
		self.labels = labels
		self.boxCount = boxCount
		self.coordinatesBlobName = coordinatesBlobName
		self.confidenceBlobName = confidenceBlobName
		self.iouThreshold = iouThreshold
		self.confidenceThreshold = confidenceThreshold
	}

	/// The suppressed outputs. These exact names are what makes the model read as a detector.
	static let coordinatesOutputName = "coordinates"
	static let confidenceOutputName = "confidence"
	static let iouThresholdInputName = "iouThreshold"
	static let confidenceThresholdInputName = "confidenceThreshold"
}

/// Builds the Core ML `Pipeline` and `NonMaximumSuppression` protobuf messages.
///
/// Every field number below was verified by decoding a known-good detector that this app already
/// ships and runs (`Demo Models/HroudaDetector15.mlpackage`, a Turi Create export) rather than from
/// memory — an incorrect number here produces a model that still compiles and then misbehaves
/// silently. The decoded layout is recorded per field.
enum NativeModelDetectorPipelineBuilder {
	/// `Model.pipeline` in the model's type oneof.
	static let pipelineModelField = 202
	/// `Model.nonMaximumSuppression` in the same oneof. Note this is 610, *not* the 612 that a
	/// reading of the neighbouring preprocessing models might suggest.
	static let nonMaximumSuppressionModelField = 610
	/// Core ML `ArrayFeatureType.ArrayDataType.DOUBLE`. The reference detector declares both
	/// detection tensors as double at every stage boundary, so the emitter matches it.
	static let doubleArrayDataType: UInt64 = 65_600

	/// Wraps already-encoded stage models in a `Pipeline` model.
	static func pipelineModel(specificationVersion: Int, description: Data, stages: [Data]) -> Data {
		let pipeline = CoreMLProtobufEncoder.message { pipeline in
			for stage in stages {
				// Pipeline.models = 1 (repeated Model).
				CoreMLProtobufEncoder.appendMessageField(1, value: stage, to: &pipeline)
			}
		}
		return CoreMLProtobufEncoder.message { model in
			CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(specificationVersion), to: &model)
			CoreMLProtobufEncoder.appendMessageField(2, value: description, to: &model)
			CoreMLProtobufEncoder.appendMessageField(pipelineModelField, value: pipeline, to: &model)
		}
	}

	/// The suppression stage: reads the network's raw boxes/scores and emits the pruned set.
	static func nonMaximumSuppressionModel(for interface: NativeModelDetectionInterface) -> Data {
		let suppression = CoreMLProtobufEncoder.message { nms in
			// pickTop = 1. An empty message keeps `perClass` at its proto3 default (false), which
			// suppresses across classes — matching the reference detector.
			CoreMLProtobufEncoder.appendMessageField(1, value: Data(), to: &nms)
			// stringClassLabels = 100 (StringVector, whose repeated string vector is field 1).
			let labelVector = CoreMLProtobufEncoder.message { vector in
				for label in interface.labels {
					CoreMLProtobufEncoder.appendStringField(1, value: label, to: &vector)
				}
			}
			CoreMLProtobufEncoder.appendMessageField(100, value: labelVector, to: &nms)
			CoreMLProtobufEncoder.appendDoubleField(110, value: interface.iouThreshold, to: &nms)
			CoreMLProtobufEncoder.appendDoubleField(111, value: interface.confidenceThreshold, to: &nms)
			// Feature-name wiring: 200/201 read the network's outputs, 202/203 name the optional
			// threshold inputs, 210/211 name what the pipeline finally publishes.
			CoreMLProtobufEncoder.appendStringField(200, value: interface.confidenceBlobName, to: &nms)
			CoreMLProtobufEncoder.appendStringField(201, value: interface.coordinatesBlobName, to: &nms)
			CoreMLProtobufEncoder.appendStringField(202, value: NativeModelDetectionInterface.iouThresholdInputName, to: &nms)
			CoreMLProtobufEncoder.appendStringField(203, value: NativeModelDetectionInterface.confidenceThresholdInputName, to: &nms)
			CoreMLProtobufEncoder.appendStringField(210, value: NativeModelDetectionInterface.confidenceOutputName, to: &nms)
			CoreMLProtobufEncoder.appendStringField(211, value: NativeModelDetectionInterface.coordinatesOutputName, to: &nms)
		}

		let description = CoreMLProtobufEncoder.message { description in
			CoreMLProtobufEncoder.appendMessageField(1, value: fixedDetectionFeature(
				named: interface.confidenceBlobName, rows: interface.boxCount, columns: interface.labels.count
			), to: &description)
			CoreMLProtobufEncoder.appendMessageField(1, value: fixedDetectionFeature(
				named: interface.coordinatesBlobName, rows: interface.boxCount, columns: 4
			), to: &description)
			// Required here, optional on the enclosing pipeline. Core ML rejects an optional feature
			// on a non-neural-network sub-model ("Features cannot be optional to this type of
			// model"); the pipeline supplies its defaults to this stage.
			CoreMLProtobufEncoder.appendMessageField(1, value: doubleFeature(
				named: NativeModelDetectionInterface.iouThresholdInputName, isOptional: false
			), to: &description)
			CoreMLProtobufEncoder.appendMessageField(1, value: doubleFeature(
				named: NativeModelDetectionInterface.confidenceThresholdInputName, isOptional: false
			), to: &description)
			for output in suppressedOutputFeatures(for: interface) {
				CoreMLProtobufEncoder.appendMessageField(10, value: output, to: &description)
			}
		}

		return CoreMLProtobufEncoder.message { model in
			// Specification version 3 is the first that includes the NMS model type.
			CoreMLProtobufEncoder.appendVarintField(1, value: 3, to: &model)
			CoreMLProtobufEncoder.appendMessageField(2, value: description, to: &model)
			CoreMLProtobufEncoder.appendMessageField(nonMaximumSuppressionModelField, value: suppression, to: &model)
		}
	}

	/// The pipeline's published outputs. Suppression removes a data-dependent number of boxes, so
	/// the row count must be declared as an unbounded range; a fixed row count would make Core ML
	/// reject every prediction that suppressed anything.
	static func suppressedOutputFeatures(for interface: NativeModelDetectionInterface) -> [Data] {
		[
			flexibleRowDetectionFeature(named: NativeModelDetectionInterface.confidenceOutputName, columns: interface.labels.count),
			flexibleRowDetectionFeature(named: NativeModelDetectionInterface.coordinatesOutputName, columns: 4)
		]
	}

	/// A `[rows, columns]` double multi-array feature.
	static func fixedDetectionFeature(named name: String, rows: Int, columns: Int) -> Data {
		let arrayType = CoreMLProtobufEncoder.message { arrayType in
			// ArrayFeatureType.shape = 1, packed.
			CoreMLProtobufEncoder.appendPackedVarintField(1, values: [UInt64(rows), UInt64(columns)], to: &arrayType)
			CoreMLProtobufEncoder.appendVarintField(2, value: doubleArrayDataType, to: &arrayType)
		}
		return featureDescription(named: name, featureType: CoreMLProtobufEncoder.message { featureType in
			CoreMLProtobufEncoder.appendMessageField(5, value: arrayType, to: &featureType)
		})
	}

	/// A `[?, columns]` double multi-array: unbounded rows, fixed columns.
	static func flexibleRowDetectionFeature(named name: String, columns: Int) -> Data {
		let shapeRange = CoreMLProtobufEncoder.message { shapeRange in
			// ShapeRange.sizeRanges is field 1 (repeated SizeRange). Within a SizeRange, `lowerBound`
			// is field 1 and `upperBound` is field 2 — those are field numbers, not values.
			// The row range therefore writes only field 2 = -1 (unbounded above) and leaves field 1
			// at its proto3 default of 0, i.e. "zero or more boxes may survive suppression".
			let rowRange = CoreMLProtobufEncoder.message { range in
				CoreMLProtobufEncoder.appendSignedVarintField(2, value: -1, to: &range)
			}
			let columnRange = CoreMLProtobufEncoder.message { range in
				CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(columns), to: &range)
				CoreMLProtobufEncoder.appendSignedVarintField(2, value: Int64(columns), to: &range)
			}
			CoreMLProtobufEncoder.appendMessageField(1, value: rowRange, to: &shapeRange)
			CoreMLProtobufEncoder.appendMessageField(1, value: columnRange, to: &shapeRange)
		}
		let arrayType = CoreMLProtobufEncoder.message { arrayType in
			CoreMLProtobufEncoder.appendVarintField(2, value: doubleArrayDataType, to: &arrayType)
			// ArrayFeatureType.shapeRange = 31. The reference model omits the fixed `shape` field
			// entirely when a range is present.
			CoreMLProtobufEncoder.appendMessageField(31, value: shapeRange, to: &arrayType)
		}
		return featureDescription(named: name, featureType: CoreMLProtobufEncoder.message { featureType in
			CoreMLProtobufEncoder.appendMessageField(5, value: arrayType, to: &featureType)
		})
	}

	/// A scalar double input, used for the two runtime-tunable thresholds. On the outer pipeline it
	/// must be optional — that is what lets Vision predict without supplying either — while the
	/// suppression sub-model must declare the same feature as required.
	static func doubleFeature(named name: String, isOptional: Bool) -> Data {
		let featureType = CoreMLProtobufEncoder.message { featureType in
			// FeatureType.doubleType = 2, FeatureType.isOptional = 1000.
			CoreMLProtobufEncoder.appendMessageField(2, value: Data(), to: &featureType)
			if isOptional {
				CoreMLProtobufEncoder.appendVarintField(1000, value: 1, to: &featureType)
			}
		}
		return featureDescription(named: name, featureType: featureType)
	}

	private static func featureDescription(named name: String, featureType: Data) -> Data {
		CoreMLProtobufEncoder.message { feature in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &feature)
			CoreMLProtobufEncoder.appendMessageField(3, value: featureType, to: &feature)
		}
	}
}
