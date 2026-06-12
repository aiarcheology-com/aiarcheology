//
//  FindingsListView.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import SwiftUI
import CoreData

/// The findings inventory (AIA-0215): stored detections with label filtering,
/// presented as a sheet from the drawer's Findings section.
struct FindingsListView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc

	/// "Open page" routes through the presenting drawer: it must dismiss this
	/// sheet and the drawer before the web screen loads the URL.
	let onOpenPage: (URL) -> Void

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \Finding.creationDate_, ascending: false)],
		predicate: NSPredicate(
			format: "%K == %@",
			#keyPath(Finding.lifeCycleString),
			CoreDataManageableState.ready.rawValue
		),
		animation: .default)
	private var findings: FetchedResults<Finding>

	/// nil = no filter (all findings, including unlabeled ones).
	@State private var filterLabel: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				if distinctLabels.isEmpty.not {
					filterChips
				}
				List {
					if filteredFindings.isEmpty {
						emptyStateView
					}
					ForEach(filteredFindings, id: \.objectID) { finding in
						row(finding)
					}
				}
				.listStyle(.plain)
			}
			.navigationTitle(L10n.Findings.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: { dismiss() }) {
						Text(L10n.Common.dismiss)
							.bold()
					}
					.testability(Testability.Button.findingsDismiss)
				}
			}
			.navigationDestination(for: Finding.self) { finding in
				FindingDetailView(finding: finding, onOpenPage: onOpenPage)
			}
		}
		.onAppear {
			// Self-heal write-time leftovers (PNG written, entity insert failed) and
			// failed file deletes. Runs on the viewContext/MainActor; the save sheet
			// is dismissed before this list can open, so it never races a save.
			FindingScreenshotStore.sweepOrphans(in: moc)
		}
	}

	// MARK: - Filtering

	private var distinctLabels: [String] {
		Finding.distinctLabels(in: moc)
	}

	private var filteredFindings: [Finding] {
		guard let filterLabel else { return Array(findings) }
		return findings.filter { $0.label_ == filterLabel }
	}

	private var filterChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				chip(title: L10n.Findings.Filter.all, isSelected: filterLabel.isNil) {
					filterLabel = nil
				}
				ForEach(distinctLabels, id: \.self) { label in
					chip(title: label, isSelected: filterLabel == label) {
						filterLabel = label
					}
				}
			}
			.padding(.horizontal)
			.padding(.vertical, 8)
		}
	}

	private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(.callout)
				.padding(.horizontal, 12)
				.padding(.vertical, 5)
				.background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
				.foregroundStyle(isSelected ? .white : .primary)
		}
		.buttonStyle(.borderless)
		.testability(Testability.Button.findingsFilterLabel, label: title)
	}

	// MARK: - Rows

	private func row(_ finding: Finding) -> some View {
		NavigationLink(value: finding) {
			HStack(spacing: 12) {
				thumbnail(finding)
				VStack(alignment: .leading, spacing: 2) {
					Text(finding.label_ ?? finding.detectionClass ?? L10n.Finding.detection)
						.foregroundStyle(.primary)
					if let page = finding.page, let host = page.host {
						Text(host)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let date = finding.creationDate_ {
						Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.testability(Testability.Button.findingsItem)
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			Button(role: .destructive) {
				delete(finding)
			} label: {
				Label(L10n.Common.delete, systemImage: "trash")
			}
			.testability(Testability.Button.findingsDeleteEntry)
		}
	}

	@ViewBuilder
	private func thumbnail(_ finding: Finding) -> some View {
		if let image = finding.cropThumbnail() {
			Image(uiImage: image)
				.resizable()
				.scaledToFill()
				.frame(width: 56, height: 56)
				.clipShape(RoundedRectangle(cornerRadius: 8))
		} else {
			// Row whose file is missing: placeholder, never auto-deleted (the
			// orphan sweep only removes files WITHOUT rows).
			Image(systemName: "photo")
				.foregroundStyle(.secondary)
				.frame(width: 56, height: 56)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
		}
	}

	private var emptyStateView: some View {
		VStack(spacing: 12) {
			Image(systemName: "archivebox")
				.font(.largeTitle)
				.foregroundStyle(.secondary)
			Text(L10n.Findings.Empty.title)
				.font(.headline)
			Text(L10n.Findings.Empty.message)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 32)
	}

	/// Entity first (committed), then best-effort file delete: a leftover file is
	/// exactly the direction the orphan sweep self-heals. The filename is captured
	/// before deletion — Core Data nullifies attributes on delete.
	private func delete(_ finding: Finding) {
		let filename = finding.screenshotFilename
		moc.delete(finding)
		do {
			try Finding.save(in: moc)
		} catch {
			LoggingPolicy.error("Failed to delete the finding", error: error, logger: .storage)
			return
		}
		FindingScreenshotStore.delete(filename: filename)
	}
}

// MARK: - Detail

/// One stored finding: the full snapshot with the detection highlighted live
/// (drawn from the stored bounding box — never baked into the image), all fields,
/// and the way back to the captured page.
private struct FindingDetailView: View {
	@ObservedObject var finding: Finding
	let onOpenPage: (URL) -> Void

	var body: some View {
		List {
			Section {
				if let image = FindingScreenshotStore.load(filename: finding.screenshotFilename) {
					HighlightedSnapshotView(image: image, normalizedBox: finding.normalizedBox, color: .red)
				} else {
					Image(systemName: "photo")
						.font(.largeTitle)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 32)
				}
			}
			if let label = finding.label_ {
				labeledRow(L10n.Finding.label, value: label)
			}
			if let note = finding.note_ {
				labeledRow(L10n.Finding.note, value: note)
			}
			if let gps = finding.gps_ {
				labeledRow(L10n.Finding.gps, value: gps)
			}
			if let detectionClass = finding.detectionClass {
				labeledRow(L10n.Finding.detection, value: "\(detectionClass) (\(Int(finding.detectionConfidence * 100))%)")
			}
			if let page = finding.page {
				Section(L10n.Finding.page) {
					Text(page.absoluteString)
						.font(.caption)
						.foregroundStyle(.secondary)
						.contextMenu {
							Button {
								UIPasteboard.general.string = page.absoluteString
							} label: {
								Label(L10n.Common.copy, systemImage: "doc.on.doc")
							}
						}
					Button {
						onOpenPage(page)
					} label: {
						Label(L10n.Findings.openPage, systemImage: "safari")
					}
					.testability(Testability.Button.findingsOpenPage)
				}
			}
		}
		.navigationTitle(finding.label_ ?? finding.detectionClass ?? L10n.Findings.title)
		.navigationBarTitleDisplayMode(.inline)
	}

	private func labeledRow(_ title: String, value: String) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(value)
		}
	}
}

// MARK: - Highlighted snapshot

/// Renders a snapshot with a Vision-normalized box highlighted at full opacity.
/// The overlay's geometry IS the fitted image rect (it sizes to the fitted Image),
/// so the shared bottom-left→top-left transform applies without letterbox math.
/// Used by the save sheet's preview and the finding detail.
struct HighlightedSnapshotView: View {
	let image: UIImage
	let normalizedBox: CGRect
	let color: Color
	/// The save form exposes this on a slider — a solid rectangle can hide the
	/// very detail the user wants to inspect before storing.
	var opacity: Double = 1

	var body: some View {
		Image(uiImage: image)
			.resizable()
			.scaledToFit()
			.overlay {
				GeometryReader { imageGeometry in
					let rect = normalizedBox.visionRect(in: imageGeometry.size)
					Rectangle()
						.stroke(color.opacity(opacity), lineWidth: 2)
						.frame(width: rect.width, height: rect.height)
						.position(x: rect.midX, y: rect.midY)
				}
			}
			.frame(maxWidth: .infinity)
	}
}

// MARK: - Crop helpers

extension Finding {
	/// The stored bounding box as a Vision-normalized full-image rect.
	var normalizedBox: CGRect {
		CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
	}

	/// Cropped detection thumbnail from the stored snapshot. The pixel rect is
	/// computed against the cgImage's own dimensions — multiplying a pixel-based
	/// rect by `UIImage.scale` would double-scale it.
	func cropThumbnail() -> UIImage? {
		guard
			let image = FindingScreenshotStore.load(filename: screenshotFilename),
			let cgImage = image.cgImage
		else { return nil }
		let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
		let pixelRect = normalizedBox.visionRect(in: pixelSize).integral
		guard let crop = cgImage.cropping(to: pixelRect) else { return nil }
		return UIImage(cgImage: crop)
	}
}
