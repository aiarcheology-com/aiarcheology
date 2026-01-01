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
			guard
				let colorData = annotationColor_,
				let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) else {
				return Color.clear
			}
			return Color(color)
		}
		set {
			let color = UIColor(newValue)
			annotationColor_ = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
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
	
	static func == (lhs: DeepConfiguration, rhs: DeepConfiguration) -> Bool {
		guard lhs.entityId == rhs.entityId else { return false }
		guard lhs.file == rhs.file else { return false }
		guard lhs.modelDescription == rhs.modelDescription else { return false }
		guard lhs.modelTypeString == rhs.modelTypeString else { return false }
		guard lhs.author == rhs.author else { return false }
		guard lhs.creationDate == rhs.creationDate else { return false }
		guard lhs.annotationColor == rhs.annotationColor else { return false }
		guard lhs.phaseOutTime == rhs.phaseOutTime else { return false }
		guard lhs.selectedSymbol == rhs.selectedSymbol else { return false }
		guard lhs.enabled == rhs.enabled else { return false }
		return true
	}
}

// Add the validations using the core data's api:
extension DeepConfiguration {
	public override func validateForInsert() throws {
		try super.validateForInsert()
		try throwIfInvalid()
	}
	
	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		try throwIfInvalid()
	}
}

// MARK: - Snapshot helper to avoid sending NSManagedObject across actors
extension DeepConfiguration {
	@MainActor
	func toDriverParams() -> DeepDriverParams {
		DeepDriverParams(
			annotationColor: annotationColor,
			entityId: entityId,
			file: file,
			phaseOutTime: phaseOutTime,
			selectedSymbol: selectedSymbol,
			demo: demo
		)
	}
}
