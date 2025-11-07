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
}

// WARN: The class definition (public class DeepConfiguration) is generated from the Core data
extension DeepConfiguration {
	public static var rootDirectory: FileManager.SearchPathDirectory {
		get { .documentDirectory }
	}

	public var file: URL? {
		get {
			guard let file_ else { return nil}

			if demo.enabled {
				return Bundle.main.url(forResource: file_.deletingPathExtension().lastPathComponent,
									   withExtension: file_.pathExtension)
			} else {
				return try? file_.completePath(to: DeepConfiguration.rootDirectory, isDirectory: false)
			}
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
		return
			lhs.entityId == rhs.entityId &&
			lhs.file == rhs.file &&
			lhs.modelDescription == rhs.modelDescription &&
			lhs.modelTypeString == rhs.modelTypeString &&
			lhs.author == rhs.author &&
			lhs.creationDate == rhs.creationDate &&
			lhs.annotationColor == rhs.annotationColor &&
			lhs.phaseOutTime == rhs.phaseOutTime &&
			lhs.selectedSymbol == rhs.selectedSymbol &&
			lhs.enabled == rhs.enabled
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
