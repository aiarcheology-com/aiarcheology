//
//  GitHubCatalogProviders.swift
//  AI Archeology
//
//  AIA-0422: curated Core ML sources backed by public GitHub catalog repositories.
//

import Foundation

/// A versioned, locally searchable catalog manifest. The upstream repositories are curated lists,
/// not registries with stable search APIs, so the app deliberately keeps only reviewed direct Core
/// ML artifacts here. This avoids scraping GitHub on every keystroke or offering a repository page,
/// archive, or package that the importer cannot install.
private struct CuratedCatalogManifest: Sendable {
	struct Entry: Sendable {
		let model: CatalogModel
		let file: CatalogFile
		let keywords: [String]
	}

	let providerID: String
	let entries: [Entry]

	func search(query: String) -> [CatalogModel] {
		let terms = query
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.split(whereSeparator: { $0.isWhitespace })
			.map(String.init)

		guard terms.isEmpty == false else { return [] }

		return entries
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

	func resolveFiles(for model: CatalogModel) throws -> [CatalogFile] {
		guard model.providerId == providerID,
			  let entry = entries.first(where: { $0.model.id == model.id }) else {
			throw CatalogError.noInstallableArtifact
		}
		return [entry.file]
	}
}

private enum CuratedCatalogURLs {
	private static let githubRawBaseURL = URL(string: "https://raw.githubusercontent.com") ?? URL(fileURLWithPath: "/")
	private static let googleDriveBaseURL = URL(string: "https://drive.usercontent.google.com") ?? URL(fileURLWithPath: "/")

	static func githubRaw(owner: String, repository: String, branch: String = "master", path: String) -> URL {
		[owner, repository, branch]
			.reduce(githubRawBaseURL) { $0.appendingPathComponent($1) }
			.appendingPathComponent(path)
	}

	static func googleDrive(fileID: String) -> URL {
		var components = URLComponents(url: googleDriveBaseURL.appendingPathComponent("download"), resolvingAgainstBaseURL: false)
		components?.queryItems = [
			URLQueryItem(name: "id", value: fileID),
			URLQueryItem(name: "export", value: "download"),
			URLQueryItem(name: "confirm", value: "t")
		]
		return components?.url ?? googleDriveBaseURL
	}
}

private extension CuratedCatalogManifest.Entry {
	init(
		id: String,
		providerID: String,
		displayName: String,
		author: String,
		task: CatalogTask,
		sizeBytes: Int64?,
		artifactURL: URL,
		keywords: [String]
	) {
		self.model = CatalogModel(
			id: id,
			providerId: providerID,
			displayName: displayName,
			author: author,
			downloads: 0,
			likes: 0,
			task: task,
			format: .mlmodel,
			sizeBytes: sizeBytes,
			artifactURL: artifactURL
		)
		self.file = CatalogFile(
			relativePath: artifactURL.lastPathComponent,
			resolveURL: artifactURL,
			sizeBytes: sizeBytes
		)
		self.keywords = keywords
	}
}

/// A reviewed subset of likedan/Awesome-CoreML-Models. The source's JSON list also includes
/// project pages and Drive folders; only direct `.mlmodel` files that can enter the normal
/// download-and-import path are retained here.
actor AwesomeCoreMLCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "awesome-coreml", displayName: "Awesome Core ML")

	private static let manifest = CuratedCatalogManifest(
		providerID: "awesome-coreml",
		entries: [
			.init(
				id: "awesome/car-recognition",
				providerID: "awesome-coreml",
				displayName: "Car Recognition",
				author: "likedan",
				task: .imageClassification,
				sizeBytes: nil,
				artifactURL: CuratedCatalogURLs.githubRaw(
					owner: "likedan",
					repository: "Core-ML-Car-Recognition",
					path: "CarRecognition/Resources/CarRecognition.mlmodel"
				),
				keywords: ["car", "vehicle", "make", "model", "image", "classification"]
			),
			.init(
				id: "awesome/photo-assessment-mobilenet",
				providerID: "awesome-coreml",
				displayName: "Photo Assessment MobileNet",
				author: "yulingtianxia",
				task: .imageClassification,
				sizeBytes: nil,
				artifactURL: CuratedCatalogURLs.githubRaw(
					owner: "yulingtianxia",
					repository: "PhotoAssessment",
					path: "PhotoAssessment-Sample/Sources/MobileNet.mlmodel"
				),
				keywords: ["photo", "assessment", "quality", "mobilenet", "image", "classification"]
			),
			.init(
				id: "awesome/tiny-yolo",
				providerID: "awesome-coreml",
				displayName: "Tiny YOLO",
				author: "hollance",
				task: .objectDetection,
				sizeBytes: nil,
				artifactURL: CuratedCatalogURLs.githubRaw(
					owner: "hollance",
					repository: "YOLO-CoreML-MPSNNGraph",
					path: "TinyYOLO-CoreML/TinyYOLO-CoreML/TinyYOLO.mlmodel"
				),
				keywords: ["yolo", "tiny", "object", "detection", "coco"]
			)
		]
	)

	func search(query: String) async throws -> [CatalogModel] {
		Self.manifest.search(query: query)
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		try Self.manifest.resolveFiles(for: model)
	}
}

/// A reviewed subset of john-rocky/CoreML-Models. Its published Google Drive files are normalized
/// to the direct user-content endpoint and were checked to return attachment responses, rather than
/// a Drive HTML page. Archive-only releases remain excluded because they cannot be imported directly.
actor JohnRockyCoreMLCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "john-rocky-coreml", displayName: "john-rocky Core ML")

	private static let manifest = CuratedCatalogManifest(
		providerID: "john-rocky-coreml",
		entries: [
			.init(
				id: "john-rocky/efficientnet-b0",
				providerID: "john-rocky-coreml",
				displayName: "EfficientNet B0",
				author: "john-rocky",
				task: .imageClassification,
				sizeBytes: 22_679_674,
				artifactURL: CuratedCatalogURLs.googleDrive(fileID: "1mJq8SMuDaCQHW77ui3fAfe5o3Qu2GKMi"),
				keywords: ["efficientnet", "imagenet", "image", "classification"]
			),
			.init(
				id: "john-rocky/efficientnet-v2",
				providerID: "john-rocky-coreml",
				displayName: "EfficientNet V2",
				author: "john-rocky",
				task: .imageClassification,
				sizeBytes: 85_800_000,
				artifactURL: CuratedCatalogURLs.googleDrive(fileID: "12JiGwXh8pX3yjoG_GsJOKAnPd3lbVrrn"),
				keywords: ["efficientnet", "imagenet", "image", "classification"]
			),
			.init(
				id: "john-rocky/yolov5s",
				providerID: "john-rocky-coreml",
				displayName: "YOLOv5s",
				author: "john-rocky",
				task: .objectDetection,
				sizeBytes: 29_188_748,
				artifactURL: CuratedCatalogURLs.googleDrive(fileID: "1KT-9eKO4F-LYIJVYJg7dy2LEW_hVUq0M"),
				keywords: ["yolo", "yolov5", "coco", "object", "detection"]
			),
			.init(
				id: "john-rocky/yolov8s",
				providerID: "john-rocky-coreml",
				displayName: "YOLOv8s",
				author: "john-rocky",
				task: .objectDetection,
				sizeBytes: 22_431_142,
				artifactURL: CuratedCatalogURLs.googleDrive(fileID: "1pLRh1Y37KLEMpQn3v8qH-A12swakoHbI"),
				keywords: ["yolo", "yolov8", "coco", "object", "detection"]
			)
		]
	)

	func search(query: String) async throws -> [CatalogModel] {
		Self.manifest.search(query: query)
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		try Self.manifest.resolveFiles(for: model)
	}
}

/// An allow-listed GitHub catalog derived from juanmorillios/List-CoreML-Models. It intentionally
/// is not a global GitHub search: every entry is a reviewed direct artifact, which keeps API-rate
/// limits, license provenance, and installability predictable.
actor GitHubCuratedCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "github-curated", displayName: "GitHub curated")

	private static let manifest = CuratedCatalogManifest(
		providerID: "github-curated",
		entries: [
			.init(
				id: "list-coreml/inception-v3",
				providerID: "github-curated",
				displayName: "Inception v3",
				author: "yulingtianxia",
				task: .imageClassification,
				sizeBytes: nil,
				artifactURL: CuratedCatalogURLs.githubRaw(
					owner: "yulingtianxia",
					repository: "Core-ML-Sample",
					path: "CoreMLSample/Inceptionv3.mlmodel"
				),
				keywords: ["inception", "imagenet", "image", "classification"]
			),
			.init(
				id: "list-coreml/resnet-50",
				providerID: "github-curated",
				displayName: "ResNet-50",
				author: "ytakzk",
				task: .imageClassification,
				sizeBytes: nil,
				artifactURL: CuratedCatalogURLs.githubRaw(
					owner: "ytakzk",
					repository: "CoreML-samples",
					path: "CoreML-samples/Resnet50.mlmodel"
				),
				keywords: ["resnet", "imagenet", "image", "classification"]
			),
			.init(
				id: "list-coreml/simple-mnist",
				providerID: "github-curated",
				displayName: "Simple MNIST",
				author: "ytakzk",
				task: .imageClassification,
				sizeBytes: nil,
				artifactURL: CuratedCatalogURLs.githubRaw(
					owner: "ytakzk",
					repository: "CoreML-samples",
					path: "CoreML-samples/SimpleMnist.mlmodel"
				),
				keywords: ["mnist", "digit", "handwriting", "image", "classification"]
			)
		]
	)

	func search(query: String) async throws -> [CatalogModel] {
		Self.manifest.search(query: query)
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		try Self.manifest.resolveFiles(for: model)
	}
}

/// PINTO's model zoo currently publishes conversion resources in `.tar.gz` bundles instead of
/// individual Core ML files. Keep the provider visible, but prevent it from entering a search until
/// archive extraction and model-manifest validation are deliberately added.
actor PintoModelZooCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(
		id: "pinto-model-zoo",
		displayName: "PINTO Model Zoo",
		isSearchable: false
	)

	func search(query: String) async throws -> [CatalogModel] {
		[]
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		throw CatalogError.noInstallableArtifact
	}
}
