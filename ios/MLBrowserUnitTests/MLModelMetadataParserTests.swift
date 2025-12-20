//
//  MLModelMetadataParserTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 13.12.25.
//

import XCTest
import CoreML
@testable import ML_Browser

// MARK: - ExtendedMLModelMetadataKey Tests

final class ExtendedMLModelMetadataKeyTests: XCTestCase {
	
	// MARK: - Key Property Tests
	
	func test_standardKey_returnsRawValue() {
		let key = ExtendedMLModelMetadataKey.standard(.description)
		XCTAssertEqual(key.key, MLModelMetadataKey.description.rawValue)
	}
	
	func test_customKey_returnsCustomString() {
		let key = ExtendedMLModelMetadataKey.custom("myCustomKey")
		XCTAssertEqual(key.key, "myCustomKey")
	}
	
	// MARK: - Static Key Tests
	
	func test_standardStaticKeys_areCorrect() {
		XCTAssertEqual(ExtendedMLModelMetadataKey.description.key, MLModelMetadataKey.description.rawValue)
		XCTAssertEqual(ExtendedMLModelMetadataKey.versionString.key, MLModelMetadataKey.versionString.rawValue)
		XCTAssertEqual(ExtendedMLModelMetadataKey.author.key, MLModelMetadataKey.author.rawValue)
		XCTAssertEqual(ExtendedMLModelMetadataKey.license.key, MLModelMetadataKey.license.rawValue)
		XCTAssertEqual(ExtendedMLModelMetadataKey.creatorDefined.key, MLModelMetadataKey.creatorDefinedKey.rawValue)
	}
	
	func test_ultralyticsKeys_areCorrect() {
		XCTAssertEqual(ExtendedMLModelMetadataKey.task.key, "task")
		XCTAssertEqual(ExtendedMLModelMetadataKey.names.key, "names")
		XCTAssertEqual(ExtendedMLModelMetadataKey.confidenceThreshold.key, "Confidence threshold")
		XCTAssertEqual(ExtendedMLModelMetadataKey.iouThreshold.key, "IoU threshold")
		XCTAssertEqual(ExtendedMLModelMetadataKey.date.key, "date")
		XCTAssertEqual(ExtendedMLModelMetadataKey.imgsz.key, "imgsz")
		XCTAssertEqual(ExtendedMLModelMetadataKey.batch.key, "batch")
	}
	
	func test_createMLKeys_areCorrect() {
		XCTAssertEqual(ExtendedMLModelMetadataKey.createMLVersion.key, "com.apple.createml.version")
		XCTAssertEqual(ExtendedMLModelMetadataKey.createMLAppTag.key, "com.apple.createml.app.tag")
		XCTAssertEqual(ExtendedMLModelMetadataKey.iterations.key, "iterations")
		XCTAssertEqual(ExtendedMLModelMetadataKey.createMLAppVersion.key, "com.apple.createml.app.version")
		XCTAssertEqual(ExtendedMLModelMetadataKey.coreMLModelPreviewType.key, "com.apple.coreml.model.preview.type")
	}
	
	func test_turiCreateKeys_areCorrect() {
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateType.key, "type")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateVersion.key, "version")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateClasses.key, "classes")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateConfidenceThreshold.key, "confidence_threshold")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateIouThreshold.key, "iou_threshold")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateNmsThreshold.key, "non_maximum_suppression_threshold")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateFrameworkVersion.key, "turicreate_version")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateModel.key, "model")
		XCTAssertEqual(ExtendedMLModelMetadataKey.turiCreateTrainingIterations.key, "training_iterations")
	}
	
	// MARK: - Hashable Tests
	
	func test_sameKeys_areEqual() {
		let key1 = ExtendedMLModelMetadataKey.custom("test")
		let key2 = ExtendedMLModelMetadataKey.custom("test")
		XCTAssertEqual(key1, key2)
	}
	
	func test_differentKeys_areNotEqual() {
		let key1 = ExtendedMLModelMetadataKey.custom("test1")
		let key2 = ExtendedMLModelMetadataKey.custom("test2")
		XCTAssertNotEqual(key1, key2)
	}
	
	func test_standardAndCustomWithSameValue_areNotEqual() {
		// Standard and custom keys are different even if the underlying string matches
		let standardKey = ExtendedMLModelMetadataKey.standard(.description)
		let customKey = ExtendedMLModelMetadataKey.custom(MLModelMetadataKey.description.rawValue)
		XCTAssertNotEqual(standardKey, customKey)
	}
}

// MARK: - MLModelMetadataParser Tests

final class MLModelMetadataParserTests: XCTestCase {
	
	// MARK: - Standard Metadata Tests
	
	func test_value_forStandardKey_returnsValue() {
		let metadata: [MLModelMetadataKey: Any] = [
			.description: "Test model description",
			.author: "Test Author",
			.versionString: "1.0.0",
			.license: "MIT"
		]
		
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.value(for: .description) as? String, "Test model description")
		XCTAssertEqual(parser.value(for: .author) as? String, "Test Author")
		XCTAssertEqual(parser.value(for: .versionString) as? String, "1.0.0")
		XCTAssertEqual(parser.value(for: .license) as? String, "MIT")
	}
	
	func test_value_forMissingKey_returnsNil() {
		let metadata: [MLModelMetadataKey: Any] = [:]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertNil(parser.value(for: .description))
		XCTAssertNil(parser.value(for: .author))
	}
	
	// MARK: - Creator Defined Metadata Tests
	
	func test_value_forCustomKey_returnsCreatorDefinedValue() {
		let creatorDefined: [String: Any] = [
			"task": "detect",
			"names": ["class1", "class2"]
		]
		let metadata: [MLModelMetadataKey: Any] = [
			.creatorDefinedKey: creatorDefined
		]
		
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.value(for: .task) as? String, "detect")
	}
	
	func test_value_forCustomKey_withNoCreatorDefined_returnsNil() {
		let metadata: [MLModelMetadataKey: Any] = [
			.description: "Test"
		]
		
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertNil(parser.value(for: .task))
	}
	
	// MARK: - Task Property Tests (Ultralytics)
	
	func test_task_withUltralyticsDetect_returnsDetector() {
		let metadata = createMetadata(creatorDefined: ["task": "detect"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .detector)
	}
	
	func test_task_withUltralyticsClassify_returnsClassificator() {
		let metadata = createMetadata(creatorDefined: ["task": "classify"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .classificator)
	}
	
	// MARK: - Task Property Tests (Create ML)
	
	func test_task_withCreateMLObjectDetector_returnsDetector() {
		let metadata = createMetadata(creatorDefined: ["com.apple.coreml.model.preview.type": "objectDetector"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .detector)
	}
	
	func test_task_withCreateMLImageClassifier_returnsClassificator() {
		let metadata = createMetadata(creatorDefined: ["com.apple.coreml.model.preview.type": "imageClassifier"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .classificator)
	}
	
	// MARK: - Task Property Tests (Turi Create)
	
	func test_task_withTuriCreateObjectDetector_returnsDetector() {
		let metadata = createMetadata(creatorDefined: ["type": "ObjectDetector"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .detector)
	}
	
	func test_task_withTuriCreateObjectDetectorLowercase_returnsDetector() {
		let metadata = createMetadata(creatorDefined: ["type": "objectdetector"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .detector)
	}
	
	// MARK: - Task Property Tests (Priority)
	
	func test_task_prioritizesUltralyticsOverTuriCreate() {
		// If both Ultralytics and Turi Create keys are present, Ultralytics should win
		let metadata = createMetadata(creatorDefined: [
			"task": "classify",
			"type": "ObjectDetector"
		])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .classificator)
	}
	
	func test_task_fallsBackToTuriCreateWhenUltralyticsAbsent() {
		let metadata = createMetadata(creatorDefined: ["type": "ObjectDetector"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .detector)
	}
	
	func test_task_withUnknownType_returnsInvalid() {
		let metadata = createMetadata(creatorDefined: ["task": "unknown"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .invalid)
	}
	
	func test_task_withEmptyMetadata_returnsInvalid() {
		let metadata: [MLModelMetadataKey: Any] = [:]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .invalid)
	}
	
	// MARK: - Model Version Tests
	
	func test_modelVersion_withStandardVersionString_returnsVersion() {
		let metadata: [MLModelMetadataKey: Any] = [
			.versionString: "2.0.0"
		]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.modelVersion, "2.0.0")
	}
	
	func test_modelVersion_withEmptyStandardVersion_fallsBackToTuriCreate() {
		let metadata: [MLModelMetadataKey: Any] = [
			.versionString: "",
			.creatorDefinedKey: ["version": 1]
		]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.modelVersion, "1")
	}
	
	func test_modelVersion_withTuriCreateIntVersion_returnsStringVersion() {
		let metadata = createMetadata(creatorDefined: ["version": 1])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.modelVersion, "1")
	}
	
	func test_modelVersion_withTuriCreateStringVersion_returnsVersion() {
		let metadata = createMetadata(creatorDefined: ["version": "1.5"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.modelVersion, "1.5")
	}
	
	func test_modelVersion_withNoVersion_returnsNil() {
		let metadata: [MLModelMetadataKey: Any] = [:]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertNil(parser.modelVersion)
	}
	
	// MARK: - Class Names Tests
	
	func test_classNames_withUltralyticsDict_returnsOrderedArray() {
		let namesDict: [Int: String] = [0: "cat", 1: "dog", 2: "bird"]
		let metadata = createMetadata(creatorDefined: ["names": namesDict])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.classNames, ["cat", "dog", "bird"])
	}
	
	func test_classNames_withUltralyticsUnorderedDict_returnsSortedArray() {
		let namesDict: [Int: String] = [2: "bird", 0: "cat", 1: "dog"]
		let metadata = createMetadata(creatorDefined: ["names": namesDict])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.classNames, ["cat", "dog", "bird"])
	}
	
	func test_classNames_withTuriCreateCommaSeparated_returnsArray() {
		let metadata = createMetadata(creatorDefined: ["classes": "Bagel,Banana,Coffee,Croissant"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.classNames, ["Bagel", "Banana", "Coffee", "Croissant"])
	}
	
	func test_classNames_withNoClasses_returnsNil() {
		let metadata: [MLModelMetadataKey: Any] = [:]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertNil(parser.classNames)
	}
	
	// MARK: - Confidence Threshold Tests
	
	func test_confidenceThreshold_withUltralyticsDouble_returnsValue() {
		let metadata = createMetadata(creatorDefined: ["Confidence threshold": 0.5])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.confidenceThreshold, 0.5)
	}
	
	func test_confidenceThreshold_withTuriCreateDouble_returnsValue() {
		let metadata = createMetadata(creatorDefined: ["confidence_threshold": 0.25])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.confidenceThreshold, 0.25)
	}
	
	func test_confidenceThreshold_withTuriCreateString_returnsConvertedValue() {
		let metadata = createMetadata(creatorDefined: ["confidence_threshold": "0.25"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.confidenceThreshold, 0.25)
	}
	
	func test_confidenceThreshold_withNoThreshold_returnsNil() {
		let metadata: [MLModelMetadataKey: Any] = [:]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertNil(parser.confidenceThreshold)
	}
	
	// MARK: - IoU Threshold Tests
	
	func test_iouThreshold_withUltralyticsDouble_returnsValue() {
		let metadata = createMetadata(creatorDefined: ["IoU threshold": 0.45])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.iouThreshold, 0.45)
	}
	
	func test_iouThreshold_withTuriCreateDouble_returnsValue() {
		let metadata = createMetadata(creatorDefined: ["iou_threshold": 0.45])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.iouThreshold, 0.45)
	}
	
	func test_iouThreshold_withTuriCreateString_returnsConvertedValue() {
		let metadata = createMetadata(creatorDefined: ["iou_threshold": "0.45"])
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.iouThreshold, 0.45)
	}
	
	func test_iouThreshold_withNoThreshold_returnsNil() {
		let metadata: [MLModelMetadataKey: Any] = [:]
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertNil(parser.iouThreshold)
	}
	
	// MARK: - Full Turi Create Model Metadata Test
	
	func test_turiCreateModel_fullMetadata() {
		// Simulates the actual Turi Create metadata structure from the dump
		let creatorDefined: [String: Any] = [
			"version": 1,
			"training_iterations": 4000,
			"non_maximum_suppression_threshold": 0.45,
			"feature": "image",
			"classes": "Bagel,Banana,Coffee,Croissant,Egg,Waffle",
			"include_non_maximum_suppression": "True",
			"type": "ObjectDetector",
			"iou_threshold": 0.45,
			"confidence_threshold": 0.25,
			"annotations": "annotation",
			"turicreate_version": "4.3.2",
			"max_iterations": 0,
			"model": "darknet-yolo"
		]
		
		let metadata: [MLModelMetadataKey: Any] = [
			.creatorDefinedKey: creatorDefined,
			.author: "Apple Inc.",
			.versionString: "",
			.license: "MIT",
			.description: "Object detector trained to identify 6 breakfast foods"
		]
		
		let parser = MLModelMetadataParser(metadata: metadata)
		
		XCTAssertEqual(parser.task, .detector)
		XCTAssertEqual(parser.modelVersion, "1")
		XCTAssertEqual(parser.classNames, ["Bagel", "Banana", "Coffee", "Croissant", "Egg", "Waffle"])
		XCTAssertEqual(parser.confidenceThreshold, 0.25)
		XCTAssertEqual(parser.iouThreshold, 0.45)
		XCTAssertEqual(parser.value(for: .author) as? String, "Apple Inc.")
		XCTAssertEqual(parser.value(for: .description) as? String, "Object detector trained to identify 6 breakfast foods")
		XCTAssertEqual(parser.value(for: .license) as? String, "MIT")
	}
	
	// MARK: - Helpers
	
	private func createMetadata(creatorDefined: [String: Any]) -> [MLModelMetadataKey: Any] {
		return [.creatorDefinedKey: creatorDefined]
	}
}
