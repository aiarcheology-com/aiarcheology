//
//  DeepConfiguration.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI
import CoreData

extension DeepConfiguration: CoreDataManageable {
}

extension DeepConfiguration: CoreDataManagableWithState {
	func validationReport() -> CoreDataManagableValidationReport {
		guard lifeCycle == .draft || lifeCycle == .ready else { return .init(issues: nil) }
		
		var issues: [CoreDataManagableValidationIssue] = []
		
		if file == nil || file?.absoluteString.isEmpty == true {
			issues.append(.init(key: "file", message: "Model file is required."))
		}
		if modelTypeString.isEmptyOrNil == true {
			issues.append(.init(key: "modelType", message: "Model type is required."))
		}
		if annotationColor_.isNil == true {
			issues.append(.init(key: "annotationColor_", message: "Annotation color is required."))
		}
		if phaseOutTime < 0.2 {
			issues.append(.init(key: "phaseOutTime", message: "Phase-out time must be ≥ 0.2s."))
		}
		
		return .init(issues: issues)
	}
	
	// Indicates whether this configuration is temporary and should be cleaned up if abandoned
	var shouldDeleteOnAbandon: Bool {
		return lifeCycle == .draft || lifeCycle == .empty
	}
}

// WARN: The class definition (public class DeepConfiguration) is generated from the Core data
extension DeepConfiguration {
    public static var rootDirectory: FileManager.SearchPathDirectory { .documentDirectory }
	
    public var file: URL? {
        guard let file_ else { return nil }

        if demo.enabled {
            return Bundle.main.url(forResource: file_.deletingPathExtension().lastPathComponent,
                                   withExtension: file_.pathExtension)
        } else {
            return try? file_.completePath(to: DeepConfiguration.rootDirectory, isDirectory: false)
        }
    }
	
	public var annotationColor: Color {
		get {
			Color.unarchived(from: annotationColor_, fallback: .clear)
		}
		set {
			annotationColor_ = newValue.archivedData()
		}
	}
	
	public var selectedSymbol: AnnotationSymbol {
		get {
			AnnotationSymbol(rawValue: selectedSymbol_ ?? "Circle") ?? .circle
		}
		set {
			selectedSymbol_ = newValue.rawValue
		}
	}

	/// The selected app-provided annotation sound. Unknown legacy/future values fall back to the
	/// default sound so a corrupted identifier never makes a persisted model unplayable.
	public var annotationSound: AnnotationSound {
		get { AnnotationSound(rawValue: annotationSoundIdentifier ?? "") ?? .chime }
		set { annotationSoundIdentifier = newValue.rawValue }
	}

	/// Value-only sound choice copied into driver parameters before it crosses actor boundaries.
	public var annotationSoundConfiguration: AnnotationSoundConfiguration {
		AnnotationSoundConfiguration(
			isEnabled: annotationSoundEnabled,
			sound: annotationSound,
			volume: annotationSoundVolume
		)
	}
	
	public var creationDate: String {
		return DateFormatter.longDateFormater.string(from: creationDate_ ?? .now)
	}
	
	public var modelType: DeepDriverType {
		get {
			DeepDriverType(rawValue: modelTypeString ?? "detect") ?? .detector
		}
		set {
			modelTypeString = newValue.rawValue
		}
	}

	/// No stored value means Automatic, preserving Core ML's `.all` default for existing models.
	/// An unavailable stored selection is not rewritten: the runtime falls back for that load while
	/// the preference remains available if the configuration returns to a capable device.
	var computeUnit: ModelComputeUnit {
		get { computeUnitString.flatMap(ModelComputeUnit.init(rawValue:)) ?? .automatic }
		set { computeUnitString = newValue == .automatic ? nil : newValue.rawValue }
	}

	/// The catalog provider from which this model was acquired, when it originated in Open Catalog.
	/// Manual file and URL imports have no catalog source and therefore leave the configuration row
	/// absent.
	public var catalogSource: String? {
		get { CatalogSourceStore.source(for: entityId) }
		set { CatalogSourceStore.setSource(newValue, for: entityId) }
	}
	
	static func == (lhs: DeepConfiguration, rhs: DeepConfiguration) -> Bool {
		guard lhs.entityId == rhs.entityId else { return false }
		guard lhs.file == rhs.file else { return false }
		guard lhs.modelDescription == rhs.modelDescription else { return false }
		guard lhs.modelTypeString == rhs.modelTypeString else { return false }
		guard lhs.computeUnit == rhs.computeUnit else { return false }
		guard lhs.author == rhs.author else { return false }
		guard lhs.license == rhs.license else { return false }
		guard lhs.creationDate == rhs.creationDate else { return false }
		guard lhs.annotationColor == rhs.annotationColor else { return false }
		guard lhs.phaseOutTime == rhs.phaseOutTime else { return false }
		guard lhs.selectedSymbol == rhs.selectedSymbol else { return false }
		guard lhs.annotationSoundConfiguration == rhs.annotationSoundConfiguration else { return false }
		guard lhs.enabled == rhs.enabled else { return false }
		return true
	}
}

// Add the validations using the core data's api:
extension DeepConfiguration {
	public override func validateForInsert() throws {
		try super.validateForInsert()
		if lifeCycle == .ready {
			try throwIfInvalid()
		}
	}
	
	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		if lifeCycle == .ready {
			try throwIfInvalid()
		}
	}
}

// MARK: - Snapshot helper to avoid sending NSManagedObject across actors
extension DeepConfiguration {
	/// The name a model is displayed under; nil OR blank-after-trim falls back (AIA-0472).
	static func displayName(from modelDescription: String?) -> String {
		let trimmed = modelDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return trimmed.isEmpty ? "Unnamed Model" : trimmed
	}

	@MainActor
	func toDriverParams() -> DeepDriverParams {
		DeepDriverParams(
			annotationColor: annotationColor,
			computeUnit: computeUnit,
			entityId: entityId,
			// Same fallback the drawer uses for a nameless model (modelDescription is optional in the
			// schema and not required by validation, so this is a normal path, not an edge case).
			// Blank-after-trim counts as nameless too — a whitespace name would render an empty
			// attribution header, which is exactly what the fallback exists to prevent.
			modelName: Self.displayName(from: modelDescription),
			file: file,
			phaseOutTime: phaseOutTime,
			selectedSymbol: selectedSymbol,
			annotationSound: annotationSoundConfiguration,
			flashEnabled: flashOnFindingEnabled,
			flashSize: flashSize
		)
	}

	// MARK: - Per-model presentation preferences (AIA-0374, AIA-0702)
	//
	// Stored in UserDefaults keyed by entityId, NOT Core Data: the public schema is still 0.0.0
	// and 0.0.1 must retain its tested migration from it. Promotion to real attributes is tracked
	// in AIA-0375; the accessors below keep call sites identical for that future schema work.

	static let flashSizeRange: ClosedRange<Double> = 2.0...24.0
	static let flashEnabledDefault = true
	static let flashSizeDefault = 8.0
	static let detectionConfidenceThresholdRange: ClosedRange<Double> = 0...1
	static let detectionConfidenceThresholdDefault = 0.0

	/// Whether this classify model's findings pulse the frame. Defaults on.
	public var flashOnFindingEnabled: Bool {
		get {
			(UserDefaults.standard.object(forKey: Self.flashKey(.enabled, entityId)) as? Bool)
				?? Self.flashEnabledDefault
		}
		set {
			objectWillChange.send()
			UserDefaults.standard.set(newValue, forKey: Self.flashKey(.enabled, entityId))
		}
	}

	/// This model's flash border width (pt), clamped to the slider bounds on read.
	public var flashSize: Double {
		get {
			let stored = UserDefaults.standard.object(forKey: Self.flashKey(.size, entityId)) as? Double
			return min(max(stored ?? Self.flashSizeDefault, Self.flashSizeRange.lowerBound), Self.flashSizeRange.upperBound)
		}
		set {
			objectWillChange.send()
			UserDefaults.standard.set(newValue, forKey: Self.flashKey(.size, entityId))
		}
	}

	/// The display-only post-Vision confidence floor for this detection configuration. A missing
	/// value is deliberately 0% so existing models keep rendering every observation they receive.
	public var detectionConfidenceThreshold: Double {
		get { Self.detectionConfidenceThreshold(for: entityId) }
		set {
			objectWillChange.send()
			let clamped = min(max(newValue, Self.detectionConfidenceThresholdRange.lowerBound), Self.detectionConfidenceThresholdRange.upperBound)
			UserDefaults.standard.set(clamped, forKey: Self.detectionConfidenceKey(entityId))
		}
	}

	/// Reads the presentation threshold by identity so a retained detection frame can be filtered
	/// again immediately when the setting changes, without reloading the model or rerunning Vision.
	static func detectionConfidenceThreshold(for entityId: UUID) -> Double {
		let stored = UserDefaults.standard.object(forKey: detectionConfidenceKey(entityId)) as? Double
		return min(
			max(stored ?? detectionConfidenceThresholdDefault, detectionConfidenceThresholdRange.lowerBound),
			detectionConfidenceThresholdRange.upperBound
		)
	}

	/// Removes per-model presentation preferences when the configuration is deleted, so orphaned
	/// UserDefaults keys do not accumulate. These remain outside Core Data by design.
	public func removePresentationDefaults() {
		UserDefaults.standard.removeObject(forKey: Self.flashKey(.enabled, entityId))
		UserDefaults.standard.removeObject(forKey: Self.flashKey(.size, entityId))
		UserDefaults.standard.removeObject(forKey: Self.detectionConfidenceKey(entityId))
	}

	private enum FlashDefaultKey: String {
		case enabled, size
	}

	private static func flashKey(_ suffix: FlashDefaultKey, _ id: UUID) -> String {
		"deepConfiguration.flash.\(suffix.rawValue).\(id.uuidString)"
	}

	private static func detectionConfidenceKey(_ id: UUID) -> String {
		"deepConfiguration.detection.confidence.\(id.uuidString)"
	}
}

// MARK: - The drawer's model list (AIA-0970)

extension DeepConfiguration {

	/// The models the drawer lists: ready configurations, newest first. One definition for the
	/// drawer's `@FetchRequest` and the headless build's drawer screen, so both show the same models
	/// in the same order.
	static func drawerListFetchRequest() -> NSFetchRequest<DeepConfiguration> {
		let request: NSFetchRequest<DeepConfiguration> = DeepConfiguration.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \DeepConfiguration.creationDate_, ascending: false)]
		request.predicate = NSPredicate(
			format: "%K == %@",
			#keyPath(DeepConfiguration.lifeCycleString),
			CoreDataManageableState.ready.rawValue
		)
		return request
	}
}
