//
//  HuggingFaceCatalogProvider.swift
//  AI Archeology
//
//  AIA-0413: public, unauthenticated Hugging Face Core ML catalog provider.
//

import Foundation

/// Minimal JSON GET client kept separate from the download-task based `Downloader`.
actor JSONHTTPClient {
	private let session: URLSession

	init(session: URLSession = .shared) {
		self.session = session
	}

	func get<Response: Decodable>(_ responseType: Response.Type, from url: URL) async throws -> Response {
		do {
			let (data, response) = try await session.data(from: url)
			guard let response = response as? HTTPURLResponse,
				  (200...299).contains(response.statusCode) else {
				throw CatalogError.network
			}

			do {
				return try JSONDecoder().decode(responseType, from: data)
			} catch {
				throw CatalogError.decoding
			}
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as URLError where error.code == .cancelled {
			throw CancellationError()
		} catch let error as CatalogError {
			throw error
		} catch {
			throw CatalogError.network
		}
	}
}

actor HuggingFaceCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "huggingface", displayName: "Hugging Face")

	private static let defaultBaseURL = URL(string: "https://huggingface.co") ?? URL(fileURLWithPath: "/")

	private let client: JSONHTTPClient
	private let baseURL: URL
	private var searchCache: [String: [CatalogModel]] = [:]

	init(client: JSONHTTPClient = JSONHTTPClient(), baseURL: URL = HuggingFaceCatalogProvider.defaultBaseURL) {
		self.client = client
		self.baseURL = baseURL
	}

	func search(query: String) async throws -> [CatalogModel] {
		let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard normalizedQuery.isEmpty == false else { return [] }

		if let cached = searchCache[normalizedQuery.localizedLowercase] {
			return cached
		}

		async let detection = search(query: normalizedQuery, task: .objectDetection)
		async let classification = search(query: normalizedQuery, task: .imageClassification)
		let fetched = try await detection + classification

		var seen = Set<String>()
		let models = fetched.filter { seen.insert($0.id).inserted }
		searchCache[normalizedQuery.localizedLowercase] = models
		return models
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		let infoURL = try modelInfoURL(for: model.id)
		let info = try await client.get(ModelInfoResponse.self, from: infoURL)
		let siblings = info.siblings ?? []
		let treeFiles = await treeFiles(for: model.id)

		if let singleFile = standaloneModelFile(in: siblings) {
			return [try catalogFile(for: model.id, sibling: singleFile, treeFiles: treeFiles)]
		}

		guard let packageRoot = installablePackageRoot(in: siblings) else {
			throw CatalogError.noInstallableArtifact
		}

		let packageFiles = orderedPackageFiles(in: siblings, packageRoot: packageRoot)

		guard packageFiles.isEmpty == false else {
			throw CatalogError.noInstallableArtifact
		}

		return try packageFiles.map { try catalogFile(for: model.id, sibling: $0, treeFiles: treeFiles) }
	}
}

private extension HuggingFaceCatalogProvider {
	struct SearchResponse: Decodable {
		let id: String
		let author: String?
		let downloads: Int?
		let likes: Int?
		let siblings: [Sibling]?
	}

	struct ModelInfoResponse: Decodable {
		let siblings: [Sibling]?
	}

	struct Sibling: Decodable {
		let rfilename: String
		let size: Int64?
	}

	struct TreeEntry: Decodable {
		let path: String
		let size: Int64?
		let xetHash: String?
	}

	struct TreeFile {
		let sizeBytes: Int64?
		let xetFile: HuggingFaceXetFile?
	}

	func search(query: String, task: CatalogTask) async throws -> [CatalogModel] {
		let url = try searchURL(query: query, task: task)
		let response = try await client.get([SearchResponse].self, from: url)
		return response.compactMap { item in
			let siblings = item.siblings ?? []
			guard let format = installableArtifactFormat(in: siblings) else {
				return nil
			}
			guard let artifactURL = try? primaryArtifactURL(modelID: item.id, siblings: siblings) else {
				return nil
			}

			return CatalogModel(
				id: item.id,
				providerId: descriptor.id,
				displayName: item.id.split(separator: "/").last.map(String.init) ?? item.id,
				author: item.author ?? item.id.split(separator: "/").first.map(String.init) ?? descriptor.displayName,
				downloads: item.downloads ?? 0,
				likes: item.likes ?? 0,
				task: task,
				format: format,
				sizeBytes: nil,
				artifactURL: artifactURL
			)
		}
	}

	func searchURL(query: String, task: CatalogTask) throws -> URL {
		guard var components = URLComponents(url: baseURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false) else {
			throw CatalogError.invalidResponse
		}
		components.queryItems = [
			URLQueryItem(name: "search", value: query),
			URLQueryItem(name: "filter", value: "coreml"),
			URLQueryItem(name: "pipeline_tag", value: task.rawValue),
			URLQueryItem(name: "sort", value: "downloads"),
			URLQueryItem(name: "limit", value: "40"),
			// With `expand`, the Hub returns only `id` plus explicitly requested fields.
			// Including siblings lets us avoid offering artifacts the importer cannot install.
			URLQueryItem(name: "expand", value: "author"),
			URLQueryItem(name: "expand", value: "downloads"),
			URLQueryItem(name: "expand", value: "likes"),
			URLQueryItem(name: "expand", value: "pipeline_tag"),
			URLQueryItem(name: "expand", value: "tags"),
			URLQueryItem(name: "expand", value: "siblings")
		]
		guard let url = components.url else { throw CatalogError.invalidResponse }
		return url
	}

	func modelInfoURL(for modelID: String) throws -> URL {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			throw CatalogError.invalidResponse
		}
		let encodedModelID = try encodedPath(modelID)
		components.percentEncodedPath = "/api/models/" + encodedModelID
		guard let url = components.url else { throw CatalogError.invalidResponse }
		return url
	}

	func treeFiles(for modelID: String) async -> [String: TreeFile] {
		guard let treeURL = try? modelTreeURL(for: modelID),
			  let entries = try? await client.get([TreeEntry].self, from: treeURL) else {
			return [:]
		}
		let tokenURL = entries.contains(where: { $0.xetHash != nil }) ? try? xetTokenURL(for: modelID) : nil

		return Dictionary(
			uniqueKeysWithValues: entries.map { entry in
				let xetFile = entry.xetHash.flatMap { xetHash in
					tokenURL.map {
						HuggingFaceXetFile(
							fileID: xetHash,
							tokenURL: $0,
							sizeBytes: entry.size,
							repositoryID: modelID,
							hubURL: baseURL
						)
					}
				}
				return (
					entry.path,
					TreeFile(sizeBytes: entry.size, xetFile: xetFile)
				)
			}
		)
	}

	func modelTreeURL(for modelID: String) throws -> URL {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			throw CatalogError.invalidResponse
		}
		let encodedModelID = try encodedPath(modelID)
		components.percentEncodedPath = "/api/models/" + encodedModelID + "/tree/main"
		components.queryItems = [
			URLQueryItem(name: "recursive", value: "true"),
			URLQueryItem(name: "expand", value: "true")
		]
		guard let url = components.url else { throw CatalogError.invalidResponse }
		return url
	}

	func xetTokenURL(for modelID: String) throws -> URL {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			throw CatalogError.invalidResponse
		}
		let encodedModelID = try encodedPath(modelID)
		components.percentEncodedPath = "/api/models/" + encodedModelID + "/xet-read-token/main"
		guard let url = components.url else { throw CatalogError.invalidResponse }
		return url
	}

	func catalogFile(for modelID: String, sibling: Sibling, treeFiles: [String: TreeFile]) throws -> CatalogFile {
		let sourcePath = packageRoot(in: sibling.rfilename) ?? sibling.rfilename
		let treeFile = treeFiles[sibling.rfilename]
		return CatalogFile(
			relativePath: sibling.rfilename,
			resolveURL: try resolveURL(modelID: modelID, filePath: sibling.rfilename),
			sourceURL: try sourceURL(modelID: modelID, filePath: sourcePath),
			sizeBytes: sibling.size ?? treeFile?.sizeBytes,
			xetFile: treeFile?.xetFile
		)
	}

	func resolveURL(modelID: String, filePath: String) throws -> URL {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			throw CatalogError.invalidResponse
		}
		components.percentEncodedPath = "/" + [
			try encodedPath(modelID),
			"resolve",
			"main",
			try encodedPath(filePath)
		].joined(separator: "/")
		guard let url = components.url else { throw CatalogError.invalidResponse }
		return url
	}

	func sourceURL(modelID: String, filePath: String) throws -> URL {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			throw CatalogError.invalidResponse
		}
		components.percentEncodedPath = "/" + [
			try encodedPath(modelID),
			"tree",
			"main",
			try encodedPath(filePath)
		].joined(separator: "/")
		guard let url = components.url else { throw CatalogError.invalidResponse }
		return url
	}

	func encodedPath(_ path: String) throws -> String {
		let components = path.split(separator: "/", omittingEmptySubsequences: false)
		guard components.isEmpty == false,
			  components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
			throw CatalogError.invalidFilePath
		}

		let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
		return try components.map { component in
			guard let encoded = String(component).addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
				throw CatalogError.invalidFilePath
			}
			return encoded
		}.joined(separator: "/")
	}

	func packageRoot(in path: String) -> String? {
		let components = path.split(separator: "/", omittingEmptySubsequences: false)
		guard let packageIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".mlpackage") }) else {
			return nil
		}
		return components[...packageIndex].joined(separator: "/")
	}

	func standaloneModelFile(in siblings: [Sibling]) -> Sibling? {
		siblings.first {
			$0.rfilename.contains("/") == false && $0.rfilename.lowercased().hasSuffix(".mlmodel")
		}
	}

	func primaryArtifactURL(modelID: String, siblings: [Sibling]) throws -> URL {
		if let singleFile = standaloneModelFile(in: siblings) {
			return try resolveURL(modelID: modelID, filePath: singleFile.rfilename)
		}

		guard let packageRoot = installablePackageRoot(in: siblings),
			  let firstPackageFile = orderedPackageFiles(in: siblings, packageRoot: packageRoot).first else {
			throw CatalogError.noInstallableArtifact
		}
		return try resolveURL(modelID: modelID, filePath: firstPackageFile.rfilename)
	}

	func installableArtifactFormat(in siblings: [Sibling]) -> CatalogArtifactFormat? {
		if standaloneModelFile(in: siblings) != nil {
			return .mlmodel
		}
		return installablePackageRoot(in: siblings) == nil ? nil : .mlpackage
	}

	func installablePackageRoot(in siblings: [Sibling]) -> String? {
		let roots = Set(siblings.compactMap { packageRoot(in: $0.rfilename) })
		return roots.sorted().first { root in
			siblings.contains { $0.rfilename.caseInsensitiveCompare(root + "/Manifest.json") == .orderedSame }
		}
	}

	func orderedPackageFiles(in siblings: [Sibling], packageRoot: String) -> [Sibling] {
		let manifestPath = packageRoot + "/Manifest.json"
		return siblings
			.filter { $0.rfilename.hasPrefix(packageRoot + "/") }
			.sorted { lhs, rhs in
				let lhsIsManifest = lhs.rfilename.caseInsensitiveCompare(manifestPath) == .orderedSame
				let rhsIsManifest = rhs.rfilename.caseInsensitiveCompare(manifestPath) == .orderedSame
				if lhsIsManifest != rhsIsManifest { return lhsIsManifest }
				return lhs.rfilename.localizedStandardCompare(rhs.rfilename) == .orderedAscending
			}
	}
}
