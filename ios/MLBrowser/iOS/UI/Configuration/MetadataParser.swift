//
//  MetadataParser.swift
//  MLBrowser
//
//  Created by Vladimír Cortes Slavík on 13.12.25.
//

import CoreML

/// Represents metadata keys from various ML model sources.
/// Supports standard CoreML keys plus custom keys from Ultralytics, Create ML, and Turi Create.
enum ExtendedMLModelMetadataKey: Hashable {
	case standard(MLModelMetadataKey)
	case custom(String)
	
	var key: String {
		switch self {
		case .standard(let key):
			return key.rawValue
		case .custom(let key):
			return key
		}
	}
	
	// Standard keys
	static let description = ExtendedMLModelMetadataKey.standard(.description)
	static let versionString = ExtendedMLModelMetadataKey.standard(.versionString)
	static let author = ExtendedMLModelMetadataKey.standard(.author)
	static let license = ExtendedMLModelMetadataKey.standard(.license)
	static let creatorDefined = ExtendedMLModelMetadataKey.standard(.creatorDefinedKey)
	
	// User defined keys from Ultralytics
	static let date = ExtendedMLModelMetadataKey.custom("date")
	static let confidenceThreshold = ExtendedMLModelMetadataKey.custom("Confidence threshold")
	static let iouThreshold = ExtendedMLModelMetadataKey.custom("IoU threshold")
	static let task = ExtendedMLModelMetadataKey.custom("task")
	static let imgsz = ExtendedMLModelMetadataKey.custom("imgsz")
	static let batch = ExtendedMLModelMetadataKey.custom("batch")
	static let names = ExtendedMLModelMetadataKey.custom("names")
	
	// User defined keys from Create ML
	static let createMLVersion = ExtendedMLModelMetadataKey.custom("com.apple.createml.version")
	static let createMLAppTag = ExtendedMLModelMetadataKey.custom("com.apple.createml.app.tag")
	static let iterations = ExtendedMLModelMetadataKey.custom("iterations")
	static let createMLAppVersion = ExtendedMLModelMetadataKey.custom("com.apple.createml.app.version")
	static let coreMLModelPreviewType = ExtendedMLModelMetadataKey.custom("com.apple.coreml.model.preview.type")
	
	// User defined keys from Turi Create (nested inside creatorDefinedKey)
	static let turiCreateType = ExtendedMLModelMetadataKey.custom("type")
	static let turiCreateVersion = ExtendedMLModelMetadataKey.custom("version")
	static let turiCreateClasses = ExtendedMLModelMetadataKey.custom("classes")
	static let turiCreateConfidenceThreshold = ExtendedMLModelMetadataKey.custom("confidence_threshold")
	static let turiCreateIouThreshold = ExtendedMLModelMetadataKey.custom("iou_threshold")
	static let turiCreateNmsThreshold = ExtendedMLModelMetadataKey.custom("non_maximum_suppression_threshold")
	static let turiCreateFrameworkVersion = ExtendedMLModelMetadataKey.custom("turicreate_version")
	static let turiCreateModel = ExtendedMLModelMetadataKey.custom("model")
	static let turiCreateTrainingIterations = ExtendedMLModelMetadataKey.custom("training_iterations")
}

/// Parses ML model metadata from various sources (Ultralytics, Create ML, Turi Create).
/// Handles different metadata structures and key naming conventions.
struct MLModelMetadataParser {
	private let metadata: [String: Any]
	private var creatorDefinedMetadata: [String: Any]?
	
	init(metadata rawMetadata: [MLModelMetadataKey: Any]) {
		self.metadata = rawMetadata.reduce(into: [String: Any]()) { result, pair in
			result[pair.key.rawValue] = pair.value
		}
		self.creatorDefinedMetadata = self.metadata[MLModelMetadataKey.creatorDefinedKey.rawValue] as? [String: Any]
	}
	
	func value(for key: ExtendedMLModelMetadataKey) -> Any? {
		switch key {
		case .standard(let standardKey):
			return metadata[standardKey.rawValue]
		case .custom(let customKey):
			return creatorDefinedMetadata?[customKey]
		}
	}
	
	/// Returns the model version from metadata.
	/// Priority: Standard versionString → Turi Create version
	var modelVersion: String? {
		// Try standard version string first
		if let version = self.value(for: .versionString) as? String, !version.isEmpty {
			return version
		}
		
		// Try Turi Create version (may be Int or String)
		if let version = self.value(for: .turiCreateVersion) {
			if let stringValue = version as? String {
				return stringValue
			}
			if let intValue = version as? Int {
				return String(intValue)
			}
		}
		
		return nil
	}
	
	/// Determines the driver type by checking metadata from different sources.
	/// Priority: Ultralytics "task" → Create ML "preview.type" → Turi Create "type"
	var task: DeepDriverType {
		// Try Ultralytics task key first, then Create ML preview type, then Turi Create type
		let taskValue = self.value(for: .task) as? String
			?? self.value(for: .coreMLModelPreviewType) as? String
			?? self.value(for: .turiCreateType) as? String
		
		guard let taskValue else { return .invalid }
		
		// Normalize to lowercase for case-insensitive matching
		switch taskValue.lowercased() {
		case "detect", "objectdetector":
			return .detector
		case "classify", "objectclassificator", "imageclassifier":
			return .classificator
		default:
			return .invalid
		}
	}
	
	/// Returns the class names/labels from the model metadata.
	/// Handles different formats: Ultralytics dict, Turi Create comma-separated string.
	var classNames: [String]? {
		// Ultralytics format: dictionary {0: "class1", 1: "class2", ...}
		if let namesDict = self.value(for: .names) as? [Int: String] {
			return namesDict.sorted { $0.key < $1.key }.map { $0.value }
		}
		
		// Turi Create format: comma-separated string "Bagel,Banana,Coffee,..."
		if let classesString = self.value(for: .turiCreateClasses) as? String {
			return classesString.split(separator: ",").map { String($0) }
		}
		
		return nil
	}
	
	/// Returns the confidence threshold from the model metadata.
	var confidenceThreshold: Double? {
		// Ultralytics format
		if let threshold = self.value(for: .confidenceThreshold) as? Double {
			return threshold
		}
		
		// Turi Create format (may be stored as String or Double)
		if let threshold = self.value(for: .turiCreateConfidenceThreshold) {
			if let doubleValue = threshold as? Double {
				return doubleValue
			}
			if let stringValue = threshold as? String, let doubleValue = Double(stringValue) {
				return doubleValue
			}
		}
		
		return nil
	}
	
	/// Returns the IoU threshold from the model metadata.
	var iouThreshold: Double? {
		// Ultralytics format
		if let threshold = self.value(for: .iouThreshold) as? Double {
			return threshold
		}
		
		// Turi Create format
		if let threshold = self.value(for: .turiCreateIouThreshold) {
			if let doubleValue = threshold as? Double {
				return doubleValue
			}
			if let stringValue = threshold as? String, let doubleValue = Double(stringValue) {
				return doubleValue
			}
		}
		
		return nil
	}
}
