//
//  AppleCoreMLCatalogProvider.swift
//  AI Archeology
//
//  AIA-0422: curated, versioned Apple Core ML model catalog.
//

import Foundation

/// A deliberately small, reviewed subset of Apple's Core ML gallery. The gallery does not expose a
/// public search API, so this manifest is versioned with the app instead of scraping its HTML at
/// runtime. Every entry points to a single-file artifact that the normal downloader can import.
actor AppleCoreMLCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "apple-coreml", displayName: "Apple Core ML")

	private static let manifestVersion = 1
	private static let assetBaseURL = URL(string: "https://ml-assets.apple.com/coreml/models") ?? URL(fileURLWithPath: "/")
	private static let entries: [Entry] = [
		entry(
			ManifestEntry(
				id: "mobilenet-v2-int8",
				displayName: "MobileNetV2 Int8",
				path: "Image/ImageClassification/MobileNetV2/MobileNetV2Int8LUT.mlmodel",
				sizeBytes: 6_300_000,
				task: .imageClassification,
				keywords: ["mobilenet", "image", "imagenet", "efficient", "mobile"]
			)
		),
		entry(
			ManifestEntry(
				id: "mobilenet-v2-fp16",
				displayName: "MobileNetV2 FP16",
				path: "Image/ImageClassification/MobileNetV2/MobileNetV2FP16.mlmodel",
				sizeBytes: 12_400_000,
				task: .imageClassification,
				keywords: ["mobilenet", "image", "imagenet", "efficient", "mobile"]
			)
		),
		entry(
			ManifestEntry(
				id: "resnet-50-fp16",
				displayName: "ResNet-50 FP16",
				path: "Image/ImageClassification/Resnet50/Resnet50FP16.mlmodel",
				sizeBytes: 51_300_000,
				task: .imageClassification,
				keywords: ["resnet", "image", "imagenet", "classification"]
			)
		),
		entry(
			ManifestEntry(
				id: "yolov3-tiny-int8",
				displayName: "YOLOv3 Tiny Int8",
				path: "Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel",
				sizeBytes: 8_900_000,
				task: .objectDetection,
				keywords: ["yolo", "coco", "object", "detection", "tiny"]
			)
		),
		entry(
			ManifestEntry(
				id: "yolov3-tiny-fp16",
				displayName: "YOLOv3 Tiny FP16",
				path: "Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel",
				sizeBytes: 17_700_000,
				task: .objectDetection,
				keywords: ["yolo", "coco", "object", "detection", "tiny"]
			)
		),
		entry(
			ManifestEntry(
				id: "yolov3-int8",
				displayName: "YOLOv3 Int8",
				path: "Image/ObjectDetection/YOLOv3/YOLOv3Int8LUT.mlmodel",
				sizeBytes: 62_200_000,
				task: .objectDetection,
				keywords: ["yolo", "coco", "object", "detection"]
			)
		)
	]

	func search(query: String) async throws -> [CatalogModel] {
		let terms = query
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.split(whereSeparator: { $0.isWhitespace })
			.map(String.init)

		guard terms.isEmpty == false else { return [] }

		return Self.entries
			.filter { entry in
				let searchableText = ([entry.model.displayName, entry.model.author, entry.model.id] + entry.keywords)
					.joined(separator: " ")
					.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
				return terms.allSatisfy(searchableText.contains)
			}
			.map(\.model)
			.sorted { lhs, rhs in
				lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
			}
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		guard model.providerId == descriptor.id,
			  let entry = Self.entries.first(where: { $0.model.id == model.id }) else {
			throw CatalogError.noInstallableArtifact
		}
		return [entry.file]
	}
}

private extension AppleCoreMLCatalogProvider {
	struct Entry: Sendable {
		let model: CatalogModel
		let file: CatalogFile
		let keywords: [String]
	}

	struct ManifestEntry: Sendable {
		let id: String
		let displayName: String
		let path: String
		let sizeBytes: Int64
		let task: CatalogTask
		let keywords: [String]
	}

	static func entry(_ manifestEntry: ManifestEntry) -> Entry {
		let modelID = "apple/\(manifestEntry.id)"
		return Entry(
			model: CatalogModel(
				id: modelID,
				providerId: "apple-coreml",
				displayName: manifestEntry.displayName,
				author: "Apple",
				downloads: 0,
				likes: 0,
				task: manifestEntry.task,
				format: .mlmodel,
				sizeBytes: manifestEntry.sizeBytes
			),
			file: CatalogFile(
				relativePath: manifestEntry.path.split(separator: "/").last.map(String.init) ?? manifestEntry.path,
				resolveURL: assetBaseURL.appendingPathComponent(manifestEntry.path),
				sizeBytes: manifestEntry.sizeBytes
			),
			keywords: manifestEntry.keywords
		)
	}
}
