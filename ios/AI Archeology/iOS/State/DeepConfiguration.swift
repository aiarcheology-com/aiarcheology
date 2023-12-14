//
//  DeepConfiguration.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI

extension DeepConfiguration: CoreDataManageable {
}

// WARN: The class definition (public class DeepConfiguration) is generated from the Core data
extension DeepConfiguration {
	private static var dateFormatter: DateFormatter {
		let formater = DateFormatter()
		formater.dateStyle = .long
		return formater
	}

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
		return Self.dateFormatter.string(from: creationDate_ ?? .now)
	}

	public var modelTypeInternal: DeepDriverType {
		return DeepDriverType(rawValue: modelType ?? "detect") ?? .detector
	}

	static func == (lhs: DeepConfiguration, rhs: DeepConfiguration) -> Bool {
		return
			lhs.entityId == rhs.entityId &&
			lhs.file == rhs.file &&
			lhs.modelDescription == rhs.modelDescription &&
			lhs.modelType == rhs.modelType &&
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
		try validateDeepConfiguration()
	}

	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		try validateDeepConfiguration()
	}

	private func validateDeepConfiguration() throws {
		if file.isNil || file?.absoluteString.isEmpty == true {
			throw validationError(forKey: "file", error: "Model's file is required.")
		}
		if modelType.isEmptyOrNil == true {
			throw validationError(forKey: "modelType", error: "Model's modelType is required.")
		}
		if annotationColor_.isNil == true {
			throw validationError(forKey: "annotationColor_", error: "Model's annotationColor_ is required.")
		}
		if phaseOutTime < 0.2 {
			throw validationError(forKey: "phaseOutTime", error: "Model's phaseOutTime is required to be >= 0.")
		}
		if entityId.isNil || entityId?.uuidString.isEmpty == true {
			throw validationError(forKey: "entityId", error: "Model's entityId is required.")
		}
	}

	private func validationError(forKey key: String, error: String) -> NSError {
			// TODO: add the error codes
		return NSError(domain: "DeepConfiguration", code: 1000, userInfo: [
			NSLocalizedDescriptionKey: "Validation error - \(key): \(error)"
		])
	}
}
