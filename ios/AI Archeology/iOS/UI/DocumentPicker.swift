//
//  DocumentPicker.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.11.23.
//

import Foundation
import SwiftUI
import UIKit

struct DocumentPicker: UIViewControllerRepresentable {
	var usedURLs: [URL]
	var onPick: (URL) -> Void
	@State private var showAlert = false

	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
		picker.allowsMultipleSelection = false
		picker.delegate = context.coordinator
		picker.presentationController?.presentedViewController.presentAlertIfNeeded(showAlert: $showAlert)
		return picker
	}

	func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
			// unused
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	class Coordinator: NSObject, UIDocumentPickerDelegate {
		var parent: DocumentPicker

		init(_ parent: DocumentPicker) {
			self.parent = parent
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			guard let url = urls.first else { return }

			if parent.usedURLs.contains(url) {
				parent.showAlert = true
				return
			}

			let fileManager = FileManager.default
			let fileName = url.lastPathComponent

			do {
				let applicationSupportDirectory = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
				let destinationURL = applicationSupportDirectory.appendingPathComponent(fileName)

				if fileManager.fileExists(atPath: destinationURL.path).not {
					try fileManager.copyItem(at: url, to: destinationURL)
				}

				parent.onPick(destinationURL)
			} catch {
				print("Error copying file: \(error)")
			}
		}
	}
}

extension UIViewController {
	func presentAlertIfNeeded(showAlert: Binding<Bool>) {
		if showAlert.wrappedValue {
			let alert = UIAlertController(title: "File Already Used", message: "The selected file is already in use. Please choose a different file.", preferredStyle: .alert)
			alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
				showAlert.wrappedValue = false
			})
			self.present(alert, animated: true)
		}
	}
}
