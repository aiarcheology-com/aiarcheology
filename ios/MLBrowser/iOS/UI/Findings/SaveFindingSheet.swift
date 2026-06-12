//
//  SaveFindingSheet.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import SwiftUI
import CoreData

/// Everything captured at the moment the user marked a finding: the observation
/// (a tapped detection, or a synthetic one built around a manual pick), the
/// producing driver's params (nil for manual picks), the displayed frame
/// (snapshot + results, frame-coherent by construction) and the page URL.
struct FindingCapture: Identifiable {
	let observation: DetectedObject
	let params: DeepDriverParams?
	let frame: AppliedDetectionFrame
	let pageURL: URL?

	var id: UUID { observation.uuid }

	/// A Vision-normalized box centered on a manual tap (top-left view
	/// coordinates), clamped fully inside the unit rect so validation holds.
	/// The view and the snapshot share the same aspect, so view-normalized
	/// coordinates are snapshot-normalized coordinates.
	static func manualBox(at location: CGPoint, in size: CGSize, side: CGFloat = 64) -> CGRect {
		guard size.width > 0, size.height > 0 else {
			return CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
		}
		let width = min(side / size.width, 1)
		let height = min(side / size.height, 1)
		let centerX = location.x / size.width
		// Vision's origin is bottom-left; the tap arrives top-left.
		let centerY = 1 - location.y / size.height
		return CGRect(
			x: min(max(0, centerX - width / 2), 1 - width),
			y: min(max(0, centerY - height / 2), 1 - height),
			width: width,
			height: height
		)
	}
}

/// Save dialog for a tapped detection (AIA-0215): stores the finding as a Core Data
/// row plus a clean PNG of the displayed snapshot — the highlight is always drawn
/// live from the stored bounding box, never baked into the image.
struct SaveFindingSheet: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc

	let capture: FindingCapture

	/// Starts empty (user decision): suggestions cover both the detection's class
	/// and previously used labels.
	@State private var label = ""
	@State private var note = ""
	@State private var gps = ""
	@State private var suggestions: [String] = []
	@State private var saveFailed = false

	var body: some View {
		NavigationStack {
			Form {
				Section {
					preview
				}
				Section(L10n.Finding.page) {
					Text(capture.pageURL?.absoluteString ?? "")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Section(L10n.Finding.label) {
					TextField(L10n.Finding.labelPlaceholder, text: $label)
						.testability(Testability.TextField.saveFindingLabel)
					if suggestions.isEmpty.not {
						suggestionChips
					}
				}
				Section(L10n.Finding.note) {
					TextField(L10n.Finding.notePlaceholder, text: $note, axis: .vertical)
						.lineLimit(3...6)
						.testability(Testability.TextField.saveFindingNote)
				}
				Section(L10n.Finding.gps) {
					TextField(L10n.Finding.gpsPlaceholder, text: $gps)
						.keyboardType(.numbersAndPunctuation)
						.testability(Testability.TextField.saveFindingGps)
				}
			}
			.navigationTitle(L10n.Finding.Save.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(L10n.Common.cancel) {
						dismiss()
					}
					.testability(Testability.Button.saveFindingCancel)
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: save) {
						Text(L10n.Finding.Save.action)
							.bold()
					}
					.testability(Testability.Button.saveFindingSave)
				}
			}
			.alert(L10n.Finding.Save.error, isPresented: $saveFailed) {
				Button(L10n.Common.ok, role: .cancel) {}
			}
			.onAppear {
				suggestions = Self.labelSuggestions(
					detectionClass: capture.observation.primaryLabelIdentifier,
					in: moc
				)
			}
		}
	}

	// MARK: - Preview

	/// The captured snapshot with the tapped detection highlighted at full opacity —
	/// drawn fresh from the bounding box (the live annotation may be mid-fade).
	private var preview: some View {
		HighlightedSnapshotView(
			image: capture.frame.image,
			normalizedBox: capture.observation.boundingBox,
			// Manual picks have no producing driver; red matches the detail view.
			color: capture.params?.annotationColor ?? .red
		)
		.frame(maxHeight: 260)
	}

	// MARK: - Labels

	private var suggestionChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(suggestions, id: \.self) { suggestion in
					Button {
						label = suggestion
					} label: {
						Text(suggestion)
							.font(.callout)
							.padding(.horizontal, 10)
							.padding(.vertical, 4)
							.background(.quaternary, in: Capsule())
					}
					.buttonStyle(.borderless)
					.testability(Testability.Button.saveFindingSuggestion)
				}
			}
		}
	}

	/// Suggestion chips = the tapped detection's top class ∪ distinct stored user
	/// labels (the class keeps the list useful before the first save; the full label
	/// list of the observation would pollute it with low-confidence classes).
	static func labelSuggestions(detectionClass: String?, in context: NSManagedObjectContext) -> [String] {
		var result: [String] = []
		if let detectionClass, detectionClass.isEmpty.not {
			result.append(detectionClass)
		}
		for stored in Finding.distinctLabels(in: context)
		where result.contains(where: { $0.caseInsensitiveCompare(stored) == .orderedSame }).not {
			result.append(stored)
		}
		return result
	}

	// MARK: - Save

	/// PNG first, then the entity: a file without a row is self-healed by the orphan
	/// sweep, while a row without a file would be a broken finding. Any entity
	/// failure deletes both the pending object (it must not linger in the context
	/// for a later unrelated save to commit) and the PNG.
	private func save() {
		let entityId = UUID()
		let filename: String
		do {
			filename = try FindingScreenshotStore.save(capture.frame.image, for: entityId)
		} catch {
			LoggingPolicy.error("Failed to write the finding screenshot", error: error, logger: .storage)
			saveFailed = true
			return
		}

		let finding = Finding.create(in: moc)
		finding.entityId = entityId
		finding.creationDate_ = .now
		finding.page = capture.pageURL
		finding.screenshotFilename = filename
		finding.label_ = normalized(label)
		finding.note_ = normalized(note)
		finding.gps_ = normalized(gps)
		finding.detectionClass = capture.observation.primaryLabelIdentifier
		finding.detectionConfidence = Double(capture.observation.labels.first?.confidence ?? capture.observation.confidence)
		finding.modelId = capture.params?.entityId
		let box = capture.observation.boundingBox
		finding.boxX = box.minX
		finding.boxY = box.minY
		finding.boxWidth = box.width
		finding.boxHeight = box.height

		finding.transition(to: .draft)
		do {
			try finding.throwIfInvalid()
			finding.transition(to: .ready)
			try Finding.save(in: moc)
			dismiss()
		} catch {
			Finding.delete(finding, in: moc)
			FindingScreenshotStore.delete(filename: filename)
			LoggingPolicy.error("Failed to save the finding", error: error, logger: .storage)
			saveFailed = true
		}
	}

	private func normalized(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
