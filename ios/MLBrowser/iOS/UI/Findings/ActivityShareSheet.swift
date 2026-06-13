//
//  ActivityShareSheet.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import SwiftUI
import UIKit

/// A share payload presented modally — the modal presentation itself is what
/// serializes exports/shares (a second one cannot start while this sheet is up).
/// `[Any]` activity items are not `Identifiable`, so this wrapper carries them
/// through `.sheet(item:)`.
struct FindingSharePayload: Identifiable {
	let id = UUID()
	let items: [Any]
}

/// Thin `UIViewControllerRepresentable` over `UIActivityViewController` — the
/// system share sheet. Share contract v1 is a plain `[Any]` of images / URLs
/// (no `LPLinkMetadata` rich preview; that is a named follow-up trade-off).
struct ActivityShareSheet: UIViewControllerRepresentable {
	let items: [Any]

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: items, applicationActivities: nil)
	}

	func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
		// Nothing to update — the items are fixed for the lifetime of the sheet.
	}
}
