//
//  DocumentPicker.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.11.23.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OSLog

struct DocumentPicker: UIViewControllerRepresentable {
	var usedURLs: [URL]
	let configurationId: UUID
	var onPick: (URL, UUID, ModelProvider) -> Void

	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let extensions: [UTType] = [
			UTType(filenameExtension: "mlmodel") ?? .item,
			UTType(filenameExtension: "mlpackage", conformingTo: .package) ?? .item
		]
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: extensions, asCopy: true)
		picker.allowsMultipleSelection = false
		picker.shouldShowFileExtensions = true
		picker.delegate = context.coordinator

		return picker
	}

	func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
			// unused
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self, configurationId: configurationId)
	}

	class Coordinator: NSObject, UIDocumentPickerDelegate, ModelProvider {
		var parent: DocumentPicker
		let configurationId: UUID

		init(_ parent: DocumentPicker, configurationId: UUID) {
			self.parent = parent
			self.configurationId = configurationId
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			guard let url = urls.first else { return }

			// TODO: Should we prevent the user from selecting the same file
			// more than once?
//			if parent.usedURLs.contains(url) {
//				DispatchQueue.main.async {
//					controller.presentAlertView(title: "File Already Used", message: "The selected file is already in use. Please choose a different file.")
//				}
//				return
//			}

			let fileManager = FileManager.default
			let fileName = url.lastPathComponent

			do {

				guard 
					let destinationDir = FileManager.deepConfigurationDirectory(id: configurationId)
				else {
                    let id = configurationId.uuidString
					Logger.ui.error("\(Logger.timestamp)Failed to create destination directory for configuration \(id, privacy: .public)")
					return
				}

				try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

				let destinationUrl = destinationDir.appendingPathComponent(fileName)
				if fileManager.fileExists(atPath: destinationUrl.path).not {
					try fileManager.copyItem(at: url, to: destinationUrl)
				}

				parent.onPick(destinationUrl, configurationId, self)
			} catch {
				Logger.ui.error("\(Logger.timestamp)Error copying file from document picker: \(error.localizedDescription, privacy: .public)")
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "documentPickerCopy"])
			}
		}

		// MARK: - ModelProvider
		func result(_ error: ModelProviderError, id: UUID) {
			// Not used
		}
	}
}

fileprivate extension UIViewController {
	func presentAlertView(title: String, message: String) {
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in })
		self.present(alert, animated: true)
	}
}
