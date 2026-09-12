//
//  DeepConfigurationTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import CoreData
import SwiftUI
@testable import ML_Browser

@MainActor
final class DeepConfigurationTests: XCTestCase {
    
    var dataController: DataController!
    var context: NSManagedObjectContext!
    
    override func setUp() async throws {
        try await super.setUp()
        dataController = DataController(inMemory: true)
        context = dataController.container.viewContext
    }
    
    override func tearDown() async throws {
        context = nil
        dataController = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createValidConfiguration() -> DeepConfiguration {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.file_ = URL(string: "file:///model.mlpackage")
        config.modelTypeString = "detect"
        config.phaseOutTime = 0.5
        config.annotationColor = .red
        config.lifeCycle = .draft
        return config
    }

	private func detectedObject(confidence: Float) -> DetectedObject {
		DetectedObject(
			uuid: UUID(),
			labels: [DetectedObject.Label(identifier: "artifact", confidence: confidence)],
			confidence: confidence,
			boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			regionIndex: 0
		)
	}
    
    // MARK: - Initialization Tests
    
    func testDeepConfiguration_Creation_HasDefaultLifeCycle() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        // Default lifeCycleString maps to empty state
        XCTAssertEqual(config.lifeCycle, .empty)
    }
    
    func testDeepConfiguration_SetProperties_ValuesArePersisted() throws {
        let config = DeepConfiguration(context: context)
        let uuid = UUID()
        config.entityId = uuid
        config.author = "Test Author"
        config.license = "MIT"
        config.modelDescription = "Test Description"
        config.modelVersion = "1.0"
        config.demo = false
        config.enabled = true
        config.phaseOutTime = 1.5
        config.computeUnit = .processorOnly
		config.annotationSoundEnabled = true
		config.annotationSound = .croak
		config.annotationSoundVolume = 0.73

        try DeepConfiguration.save(in: context)
        context.refresh(config, mergeChanges: false)

        XCTAssertEqual(config.entityId, uuid)
        XCTAssertEqual(config.author, "Test Author")
        XCTAssertEqual(config.license, "MIT")
        XCTAssertEqual(config.modelDescription, "Test Description")
        XCTAssertEqual(config.modelVersion, "1.0")
        XCTAssertFalse(config.demo)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.phaseOutTime, 1.5)
        XCTAssertEqual(config.computeUnit, .processorOnly)
		XCTAssertTrue(config.annotationSoundEnabled)
		XCTAssertEqual(config.annotationSound, .croak)
		XCTAssertEqual(config.annotationSoundConfiguration.volume, 0.73, accuracy: 0.0001)
    }

	func testAnnotationSound_DefaultsOffAtTwentyPercentAndClampsInvalidVolume() {
		let config = createValidConfiguration()

		XCTAssertFalse(config.annotationSoundConfiguration.isEnabled)
		XCTAssertEqual(config.annotationSound, .chime)
		XCTAssertEqual(config.annotationSoundConfiguration.volume, 0.2, accuracy: 0.0001)

		config.annotationSoundVolume = 9
		XCTAssertEqual(config.annotationSoundConfiguration.volume, 1, accuracy: 0.0001)
		config.annotationSoundVolume = -1
		XCTAssertEqual(config.annotationSoundConfiguration.volume, 0, accuracy: 0.0001)
	}

	func testAnnotationSound_PersistsAfterContextResetAndRefetch() throws {
		let config = createValidConfiguration()
		let id = config.entityId
		config.annotationSoundEnabled = true
		config.annotationSound = .pulse
		config.annotationSoundVolume = 0.61
		try DeepConfiguration.save(in: context)

		// A reset drops the managed object cache. The fetched values must come from the persistent
		// Core Data store, not from ConfigurationForm's in-memory object.
		context.reset()
		let fetched = try XCTUnwrap(DeepConfiguration.select(id, in: context))
		XCTAssertTrue(fetched.annotationSoundEnabled)
		XCTAssertEqual(fetched.annotationSound, .pulse)
		XCTAssertEqual(fetched.annotationSoundConfiguration.volume, 0.61, accuracy: 0.0001)
	}

	func testAnnotationSoundCatalog_ProducesDistinctValidWAVData() {
		let files = AnnotationSound.allCases.map(AnnotationSoundCatalog.audioData(for:))

		XCTAssertEqual(files.count, 11)
		XCTAssertEqual(files.count, Set(files).count)
		for data in files {
			XCTAssertGreaterThan(data.count, 44)
			XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
			XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
		}
	}

	func testAnnotationSoundPlayerRetention_TracksPlaybackDuration() {
		let catalogRetention = AnnotationSoundPlayer.playerRetentionNanoseconds(
			for: AnnotationSoundCatalog.duration
		)
		let longerToneRetention = AnnotationSoundPlayer.playerRetentionNanoseconds(
			for: AnnotationSoundCatalog.duration + 1
		)

		XCTAssertGreaterThan(catalogRetention, UInt64(AnnotationSoundCatalog.duration * 1_000_000_000))
		XCTAssertGreaterThan(longerToneRetention, catalogRetention)
	}

    func testDeepConfiguration_EqualityTreatsLicenseAsConfigurationState() {
        let entityID = UUID()
        let creationDate = Date(timeIntervalSinceReferenceDate: 123)
        let first = DeepConfiguration(context: context)
        let second = DeepConfiguration(context: context)

        for configuration in [first, second] {
            configuration.entityId = entityID
            configuration.file_ = URL(string: "file:///model.mlpackage")
            configuration.modelDescription = "Model"
            configuration.modelTypeString = "detect"
            configuration.author = "Author"
            configuration.creationDate_ = creationDate
            configuration.annotationColor = .red
            configuration.phaseOutTime = 0.5
            configuration.selectedSymbol = .circle
            configuration.enabled = true
        }
        first.license = "MIT"
        second.license = "Apache-2.0"

        XCTAssertFalse(first == second)
    }

    func testComputeUnit_DefaultsToAutomaticWithoutPersistingANewValue() {
        let configuration = DeepConfiguration(context: context)
        configuration.entityId = UUID()

        XCTAssertNil(configuration.computeUnitString)
        XCTAssertEqual(configuration.computeUnit, .automatic)

        configuration.computeUnit = .automatic
        XCTAssertNil(configuration.computeUnitString)

        configuration.computeUnit = .graphicsProcessor
        XCTAssertEqual(configuration.computeUnitString, ModelComputeUnit.graphicsProcessor.rawValue)
        XCTAssertEqual(configuration.computeUnit, .graphicsProcessor)
    }

	func testDetectionConfidenceThreshold_DefaultsToZeroAndClampsItsStoredValue() {
		let configuration = createValidConfiguration()
		defer { configuration.removePresentationDefaults() }

		XCTAssertEqual(configuration.detectionConfidenceThreshold, 0)

		configuration.detectionConfidenceThreshold = 0.57
		XCTAssertEqual(configuration.detectionConfidenceThreshold, 0.57, accuracy: 0.0001)

		configuration.detectionConfidenceThreshold = 2
		XCTAssertEqual(configuration.detectionConfidenceThreshold, 1)
	}

	func testDetectionConfidenceThreshold_IsIsolatedPerConfiguration() {
		let first = createValidConfiguration()
		let second = createValidConfiguration()
		defer {
			first.removePresentationDefaults()
			second.removePresentationDefaults()
		}

		first.detectionConfidenceThreshold = 0.6

		XCTAssertEqual(first.detectionConfidenceThreshold, 0.6, accuracy: 0.0001)
		XCTAssertEqual(second.detectionConfidenceThreshold, 0)
	}

	func testDetectionPresentation_DefaultShowsEveryObservation() {
		let configuration = createValidConfiguration()
		defer { configuration.removePresentationDefaults() }
		let low = detectedObject(confidence: 0.01)
		let high = detectedObject(confidence: 0.99)

		let displayed = DetectionPresentation.filteredResults([
			(observations: [low, high], params: configuration.toDriverParams())
		])

		XCTAssertEqual(displayed.flatMap(\.observations).map(\.uuid), [low.uuid, high.uuid])
	}

	func testDetectionPresentation_BelowThresholdIsAbsentAndCannotBePicked() {
		let configuration = createValidConfiguration()
		defer { configuration.removePresentationDefaults() }
		configuration.detectionConfidenceThreshold = 0.6
		let low = detectedObject(confidence: 0.59)
		let raw: [DetectionResult] = [(observations: [low], params: configuration.toDriverParams())]

		let displayed = DetectionPresentation.filteredResults(raw)

		XCTAssertTrue(displayed.isEmpty, "The shared pre-presentation filter covers every annotation symbol.")
		XCTAssertNil(FindingCapture.detection(at: CGPoint(x: 20, y: 80), in: CGSize(width: 100, height: 100), results: displayed))
	}

	func testDetectionPresentation_ConfidenceAtThresholdRemainsVisible() {
		let configuration = createValidConfiguration()
		defer { configuration.removePresentationDefaults() }
		configuration.detectionConfidenceThreshold = 0.6
		let exact = detectedObject(confidence: 0.6)

		let displayed = DetectionPresentation.filteredResults([
			(observations: [exact], params: configuration.toDriverParams())
		])

		XCTAssertEqual(displayed.flatMap(\.observations).map(\.uuid), [exact.uuid])
	}

	func testDetectionPresentation_ExistingFrameReevaluatesPerModelThresholdsImmediately() {
		let first = createValidConfiguration()
		let second = createValidConfiguration()
		defer {
			first.removePresentationDefaults()
			second.removePresentationDefaults()
		}
		let firstObject = detectedObject(confidence: 0.5)
		let secondObject = detectedObject(confidence: 0.5)
		let raw: [DetectionResult] = [
			(observations: [firstObject], params: first.toDriverParams()),
			(observations: [secondObject], params: second.toDriverParams())
		]
		first.detectionConfidenceThreshold = 0.6

		XCTAssertEqual(DetectionPresentation.filteredResults(raw).flatMap(\.observations).map(\.uuid), [secondObject.uuid])

		first.detectionConfidenceThreshold = 0.4
		XCTAssertEqual(
			DetectionPresentation.filteredResults(raw).flatMap(\.observations).map(\.uuid),
			[firstObject.uuid, secondObject.uuid],
			"The same retained frame must be re-filtered; a model reload would lose the hidden observation."
		)
	}

    func testCatalogSource_IsSharedWithCatalogDownloadByConfigurationID() {
        let id = UUID()
        let item = DownloadItem.create(in: context)
        item.entityId = id
        item.catalogSource = "  Hugging Face  "
        defer { item.catalogSource = nil }

        let config = DeepConfiguration(context: context)
        config.entityId = id

        XCTAssertEqual(config.catalogSource, "Hugging Face")

        config.catalogSource = " \n "

        XCTAssertNil(config.catalogSource)
    }

    func testCatalogSource_IsRemovedWhenUnimportedDownloadIsDeleted() {
        let item = DownloadItem.create(in: context)
        let id = item.entityId
        item.catalogSource = "Hugging Face"

        DownloadItem.delete(item, in: context, deleteModel: false)

        XCTAssertNil(CatalogSourceStore.source(for: id))
    }

    func testCatalogSource_IsRemovedWhenConfigurationWithoutDownloadIsDeleted() {
        let repository = ModelConfigurationRepository(dataController: dataController)
        let configuration = repository.create()
        let id = configuration.entityId
        configuration.catalogSource = "Hugging Face"

        repository.delete(configuration)

        XCTAssertNil(CatalogSourceStore.source(for: id))
    }

    func testCatalogSource_IsKeptUntilMatchingDownloadIsDeleted() {
        let id = UUID()
        let item = DownloadItem.create(in: context)
        item.entityId = id
        item.catalogSource = "Hugging Face"
        let repository = ModelConfigurationRepository(dataController: dataController)
        let configuration = repository.create()
        configuration.entityId = id

        repository.delete(configuration)

        XCTAssertEqual(item.catalogSource, "Hugging Face")

        DownloadItem.delete(item, in: context, deleteModel: false)

        XCTAssertNil(CatalogSourceStore.source(for: id))
    }
    
    // MARK: - LifeCycle Tests
    
    func testLifeCycle_SetToDraft_UpdatesLifeCycleString() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.lifeCycle = .draft
        
        XCTAssertEqual(config.lifeCycle, .draft)
        XCTAssertEqual(config.lifeCycleString, "draft")
    }
    
    func testLifeCycle_SetToReady_UpdatesLifeCycleString() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.lifeCycle = .ready
        
        XCTAssertEqual(config.lifeCycle, .ready)
        XCTAssertEqual(config.lifeCycleString, "ready")
    }
    
    func testLifeCycle_SetToEmpty_UpdatesLifeCycleString() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.lifeCycle = .empty
        
        XCTAssertEqual(config.lifeCycle, .empty)
        XCTAssertEqual(config.lifeCycleString, "empty")
    }
    
    func testLifeCycle_SetToDeprecated_UpdatesLifeCycleString() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.lifeCycle = .deprecated
        
        XCTAssertEqual(config.lifeCycle, .deprecated)
        XCTAssertEqual(config.lifeCycleString, "deprecated")
    }
    
    // MARK: - Validation Tests
    
    func testValidationReport_ValidConfig_IsValid() {
        let config = createValidConfiguration()
        
        let report = config.validationReport()
        
        XCTAssertTrue(report.isValid, "Valid config should pass validation. Issues: \(report.issues ?? [])")
    }
    
    func testValidationReport_MissingFile_IsNotValid() {
        let config = createValidConfiguration()
        config.file_ = nil
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "file" } ?? false)
    }
    
    func testValidationReport_EmptyFile_IsNotValid() {
        let config = createValidConfiguration()
        config.file_ = URL(string: "")
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "file" } ?? false)
    }
    
    func testValidationReport_MissingModelType_IsNotValid() {
        let config = createValidConfiguration()
        config.modelTypeString = nil
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "modelType" } ?? false)
    }
    
    func testValidationReport_EmptyModelType_IsNotValid() {
        let config = createValidConfiguration()
        config.modelTypeString = ""
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "modelType" } ?? false)
    }
    
    func testValidationReport_MissingAnnotationColor_IsNotValid() {
        let config = createValidConfiguration()
        config.annotationColor_ = nil
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "annotationColor_" } ?? false)
    }
    
    func testValidationReport_PhaseOutTimeTooLow_IsNotValid() {
        let config = createValidConfiguration()
        config.phaseOutTime = 0.1
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "phaseOutTime" } ?? false)
    }
    
    func testValidationReport_PhaseOutTimeAtBoundary_IsValid() {
        let config = createValidConfiguration()
        config.phaseOutTime = 0.2
        
        let report = config.validationReport()
        
        XCTAssertTrue(report.isValid)
    }
    
    func testValidationReport_ReadyLifeCycle_SkipsValidation() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .ready
        // All fields invalid
        config.file_ = nil
        config.modelTypeString = nil
        config.annotationColor_ = nil
        config.phaseOutTime = 0.0
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
    }
    
    func testValidationReport_DeprecatedLifeCycle_SkipsValidation() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .deprecated
        // All fields invalid
        config.file_ = nil
        config.modelTypeString = nil
        
        let report = config.validationReport()
        
        // Deprecated state skips validation
        XCTAssertTrue(report.isValid)
    }
    
    func testValidationReport_UndefinedLifeCycle_SkipsValidation() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        // Default is undefined
        config.file_ = nil
        config.modelTypeString = nil
        
        let report = config.validationReport()
        
        // Undefined state skips validation
        XCTAssertTrue(report.isValid)
    }
    
    // MARK: - ModelType Tests
    
    func testModelType_Detector_SetsCorrectString() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.modelType = .detector
        
        XCTAssertEqual(config.modelTypeString, "detect")
        XCTAssertEqual(config.modelType, .detector)
    }
    
    func testModelType_Classificator_SetsCorrectString() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.modelType = .classificator
        
        XCTAssertEqual(config.modelTypeString, "classify")
        XCTAssertEqual(config.modelType, .classificator)
    }
    
    func testModelType_UnknownString_DefaultsToDetector() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.modelTypeString = "unknown_type"
        
        // Unknown strings that don't match any raw value default to .detector
        XCTAssertEqual(config.modelType, .detector)
    }
    
    func testModelType_NilString_DefaultsToDetector() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.modelTypeString = nil
        
        // Nil string defaults to "detect" which is .detector
        XCTAssertEqual(config.modelType, .detector)
    }
    
    // MARK: - AnnotationColor Tests
    
    func testAnnotationColor_SetColor_PersistsValue() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.annotationColor = .blue
        
        XCTAssertNotNil(config.annotationColor_)
    }
    
    func testAnnotationColor_NilData_ReturnsClear() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.annotationColor_ = nil
        
        // Clear color has opacity 0
        XCTAssertEqual(config.annotationColor, Color.clear)
    }
    
    // MARK: - SelectedSymbol Tests
    
    func testSelectedSymbol_SetCircle_PersistsValue() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.selectedSymbol = .circle
        
        XCTAssertEqual(config.selectedSymbol_!, "Circle")
        XCTAssertEqual(config.selectedSymbol, .circle)
    }
    
    func testSelectedSymbol_SetSquare_PersistsValue() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        
        config.selectedSymbol = .square
        
        XCTAssertEqual(config.selectedSymbol_!, "Square")
        XCTAssertEqual(config.selectedSymbol, .square)
    }
    
    func testSelectedSymbol_InvalidString_DefaultsToCircle() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.selectedSymbol_ = "InvalidSymbol"
        
        XCTAssertEqual(config.selectedSymbol, .circle)
    }
    
    func testSelectedSymbol_NilString_DefaultsToCircle() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.selectedSymbol_ = nil
        
        XCTAssertEqual(config.selectedSymbol, .circle)
    }
    
    // MARK: - ShouldDeleteOnAbandon Tests
    
    func testShouldDeleteOnAbandon_DraftState_ReturnsTrue() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .draft
        
        XCTAssertTrue(config.shouldDeleteOnAbandon)
    }
    
    func testShouldDeleteOnAbandon_EmptyState_ReturnsTrue() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .empty
        
        XCTAssertTrue(config.shouldDeleteOnAbandon)
    }
    
    func testShouldDeleteOnAbandon_ReadyState_ReturnsFalse() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .ready
        
        XCTAssertFalse(config.shouldDeleteOnAbandon)
    }
    
    func testShouldDeleteOnAbandon_DeprecatedState_ReturnsFalse() {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .deprecated
        
        XCTAssertFalse(config.shouldDeleteOnAbandon)
    }
    
    // MARK: - CRUD Operations Tests
    
    func testDeepConfiguration_Save_PersistsToContext() throws {
        let config = createValidConfiguration()
        config.author = "Persisted Author"
        
        try context.save()
        
        let fetchRequest: NSFetchRequest<DeepConfiguration> = DeepConfiguration.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "author == %@", "Persisted Author")
        
        let results = try context.fetch(fetchRequest)
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.author, "Persisted Author")
    }
    
    func testDeepConfiguration_Delete_RemovesFromContext() throws {
        let config = createValidConfiguration()
        config.author = "To Delete"
        try context.save()
        
        context.delete(config)
        try context.save()
        
        let fetchRequest: NSFetchRequest<DeepConfiguration> = DeepConfiguration.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "author == %@", "To Delete")
        
        let results = try context.fetch(fetchRequest)
        
        XCTAssertEqual(results.count, 0)
    }
    
    func testDeepConfiguration_Update_ModifiesExisting() throws {
        let config = createValidConfiguration()
        config.author = "Original Author"
        try context.save()
        
        config.author = "Updated Author"
        try context.save()
        
        let fetchRequest: NSFetchRequest<DeepConfiguration> = DeepConfiguration.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "entityId == %@", config.entityId as CVarArg)
        
        let results = try context.fetch(fetchRequest)
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.author, "Updated Author")
    }
    
    // MARK: - Lifecycle-Aware Validation Tests
    
    func testValidateForInsert_EmptyLifeCycle_DoesNotThrowForInvalidData() throws {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .empty
        // Missing required fields
        config.file_ = nil
        config.modelTypeString = nil
        
        // Should not throw during insert validation when lifeCycle is .empty
        XCTAssertNoThrow(try config.validateForInsert())
    }
    
    func testValidateForInsert_DraftLifeCycle_DoesNotThrowForInvalidData() throws {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .draft
        // Missing required fields
        config.file_ = nil
        config.modelTypeString = nil
        
        // Should not throw during insert validation when lifeCycle is .draft
        XCTAssertNoThrow(try config.validateForInsert())
    }
    
    func testValidateForInsert_ReadyLifeCycle_ThrowsForInvalidData() throws {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .ready
        // Missing required fields
        config.file_ = nil
        config.modelTypeString = nil
        
        // Should throw during insert validation when lifeCycle is .ready
        XCTAssertThrowsError(try config.validateForInsert())
    }
    
    func testValidateForInsert_ReadyLifeCycle_DoesNotThrowForValidData() throws {
        let config = createValidConfiguration()
        config.lifeCycle = .ready
        
        // Should not throw during insert validation when data is valid
        XCTAssertNoThrow(try config.validateForInsert())
    }
    
    func testValidateForUpdate_EmptyLifeCycle_DoesNotThrowForInvalidData() throws {
        let config = createValidConfiguration()
        try context.save()
        
        // Make invalid and change to empty lifecycle
        config.file_ = nil
        config.lifeCycle = .empty
        
        // Should not throw during update validation when lifeCycle is .empty
        XCTAssertNoThrow(try config.validateForUpdate())
    }
    
    func testValidateForUpdate_DraftLifeCycle_DoesNotThrowForInvalidData() throws {
        let config = createValidConfiguration()
        try context.save()
        
        // Make invalid but keep draft lifecycle
        config.file_ = nil
        config.lifeCycle = .draft
        
        // Should not throw during update validation when lifeCycle is .draft
        XCTAssertNoThrow(try config.validateForUpdate())
    }
    
    func testValidateForUpdate_ReadyLifeCycle_ThrowsForInvalidData() throws {
        let config = createValidConfiguration()
        config.lifeCycle = .ready
        try context.save()
        
        // Make invalid while in ready state
        config.file_ = nil
        
        // Should throw during update validation when lifeCycle is .ready
        XCTAssertThrowsError(try config.validateForUpdate())
    }
    
    func testValidateForUpdate_ReadyLifeCycle_DoesNotThrowForValidData() throws {
        let config = createValidConfiguration()
        config.lifeCycle = .ready
        try context.save()
        
        // Update with valid data
        config.author = "Updated Author"
        
        // Should not throw during update validation when data is valid
        XCTAssertNoThrow(try config.validateForUpdate())
    }
    
    func testValidateForUpdate_TransitioningToReady_ThrowsForInvalidData() throws {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.lifeCycle = .draft
        // Missing required fields
        config.file_ = nil
        config.modelTypeString = nil
        try context.save()
        
        // Transition to ready with invalid data
        config.lifeCycle = .ready
        
        // Should throw during update validation when transitioning to .ready with invalid data
        XCTAssertThrowsError(try config.validateForUpdate())
    }
    
    func testValidateForUpdate_TransitioningToReady_DoesNotThrowForValidData() throws {
        let config = createValidConfiguration()
        try context.save()
        
        // Transition to ready with valid data
        config.lifeCycle = .ready
        
        // Should not throw during update validation when transitioning to .ready with valid data
        XCTAssertNoThrow(try config.validateForUpdate())
    }
    
    // MARK: - CoreDataManagable Protocol Tests
    
    func testSelectAll_ReturnsAllConfigurations() throws {
        _ = createValidConfiguration()
        _ = createValidConfiguration()
        _ = createValidConfiguration()
        try context.save()
        
        let allConfigs = DeepConfiguration.selectAll(in: context)
        
        XCTAssertEqual(allConfigs.count, 3)
    }
    
    func testSelect_ByEntityId_ReturnsCorrectConfiguration() throws {
        let config = createValidConfiguration()
        config.author = "Target Config"
        try context.save()
        
        let selected = DeepConfiguration.select(config.entityId, in: context)
        
        XCTAssertNotNil(selected)
        XCTAssertEqual(selected?.author, "Target Config")
    }
    
    // MARK: - ToDriverParams Tests
    
    func testToDriverParams_CreatesCorrectParams() {
        let config = createValidConfiguration()
        config.annotationColor = .green
        config.phaseOutTime = 1.0
        config.selectedSymbol = .square
        
        let params = config.toDriverParams()

        XCTAssertEqual(params.entityId, config.entityId)
        XCTAssertEqual(params.phaseOutTime, 1.0)
        XCTAssertEqual(params.selectedSymbol, .square)
        XCTAssertEqual(params.computeUnit, .automatic)
    }

    func testToDriverParams_CarriesTheModelName() {
        let config = createValidConfiguration()
        config.modelDescription = "MobileNetV2"

        XCTAssertEqual(config.toDriverParams().modelName, "MobileNetV2")
    }

    func testToDriverParams_NamelessModelGetsTheDrawerFallbackName() {
        // modelDescription is optional in the schema and not required by validation, so a
        // nameless model is a normal path. The bubble must attribute it the same way the drawer
        // titles it, never as a blank header (AIA-0472).
        let config = createValidConfiguration()
        config.modelDescription = nil

        XCTAssertEqual(config.toDriverParams().modelName, "Unnamed Model")
    }

    func testToDriverParams_BlankModelDescriptionAlsoGetsTheFallbackName() {
        // A whitespace-only description would render an EMPTY attribution header — exactly what
        // the fallback exists to prevent, so blank-after-trim counts as nameless.
        let config = createValidConfiguration()
        config.modelDescription = "   \n"

        XCTAssertEqual(config.toDriverParams().modelName, "Unnamed Model")
    }
    
    // MARK: - Edge Cases
    
    func testDeepConfiguration_VeryLongAuthor_IsHandled() {
        let config = createValidConfiguration()
        let longAuthor = String(repeating: "A", count: 1000)
        config.author = longAuthor
        
        XCTAssertEqual(config.author, longAuthor)
    }
    
    func testDeepConfiguration_SpecialCharactersInDescription_IsHandled() {
        let config = createValidConfiguration()
        let specialDescription = "Model 📱 with émojis & spëcial-chars_123 日本語"
        config.modelDescription = specialDescription
        
        XCTAssertEqual(config.modelDescription, specialDescription)
    }
    
    func testDeepConfiguration_ZeroPhaseOutTime_IsInvalid() {
        let config = createValidConfiguration()
        config.phaseOutTime = 0.0
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "phaseOutTime" } ?? false)
    }
    
    func testDeepConfiguration_NegativePhaseOutTime_IsInvalid() {
        let config = createValidConfiguration()
        config.phaseOutTime = -1.0
        
        let report = config.validationReport()
        
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "phaseOutTime" } ?? false)
    }
}

// MARK: - CoreDataManagableValidationReport Tests

final class CoreDataManagableValidationReportTests: XCTestCase {
    
    func testValidationReport_WithNoIssues_IsValid() {
        let report = CoreDataManagableValidationReport(issues: nil)
        
        XCTAssertTrue(report.isValid)
    }
    
    func testValidationReport_WithEmptyIssues_IsValid() {
        let report = CoreDataManagableValidationReport(issues: [])
        
        XCTAssertTrue(report.isValid)
    }
    
    func testValidationReport_WithIssues_IsNotValid() {
        let issues = [CoreDataManagableValidationIssue(key: "test", message: "Test error")]
        let report = CoreDataManagableValidationReport(issues: issues)
        
        XCTAssertFalse(report.isValid)
    }
    
    func testValidationReport_MultipleIssues_IsNotValid() {
        let issues = [
            CoreDataManagableValidationIssue(key: "field1", message: "Error 1"),
            CoreDataManagableValidationIssue(key: "field2", message: "Error 2"),
            CoreDataManagableValidationIssue(key: "field3", message: "Error 3")
        ]
        let report = CoreDataManagableValidationReport(issues: issues)
        
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.issues?.count, 3)
    }
}

// MARK: - CoreDataManageableState Tests

final class CoreDataManageableStateTests: XCTestCase {
    
    func testState_UndefinedRawValue() {
        XCTAssertEqual(CoreDataManageableState.undefined.rawValue, "undefined")
    }
    
    func testState_EmptyRawValue() {
        XCTAssertEqual(CoreDataManageableState.empty.rawValue, "empty")
    }
    
    func testState_DraftRawValue() {
        XCTAssertEqual(CoreDataManageableState.draft.rawValue, "draft")
    }
    
    func testState_ReadyRawValue() {
        XCTAssertEqual(CoreDataManageableState.ready.rawValue, "ready")
    }
    
    func testState_DeprecatedRawValue() {
        XCTAssertEqual(CoreDataManageableState.deprecated.rawValue, "deprecated")
    }
    
    func testState_InitFromRawValue() {
        XCTAssertEqual(CoreDataManageableState(rawValue: "draft"), .draft)
        XCTAssertEqual(CoreDataManageableState(rawValue: "ready"), .ready)
        XCTAssertNil(CoreDataManageableState(rawValue: "invalid"))
    }
    
    func testState_CallAsFunction_ReturnsRawValue() {
        XCTAssertEqual(CoreDataManageableState.draft(), "draft")
        XCTAssertEqual(CoreDataManageableState.ready(), "ready")
    }
}
