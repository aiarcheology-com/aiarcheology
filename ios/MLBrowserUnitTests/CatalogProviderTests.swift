//
//  CatalogProviderTests.swift
//  MLBrowserUnitTests
//
//  AIA-0413: catalog provider and package-staging coverage without live network traffic.
//

import XCTest
import Combine
@testable import ML_Browser

final class CatalogProviderTests: XCTestCase {

	private final class RequestCounter: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0

		func increment() {
			lock.lock()
			count += 1
			lock.unlock()
		}

		var value: Int {
			lock.lock()
			defer { lock.unlock() }
			return count
		}
	}

	private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
		nonisolated(unsafe) static var responseHandler: ((URL) -> (Int, Data))?

		// swiftlint:disable:next static_over_final_class
		override class func canInit(with request: URLRequest) -> Bool {
			request.url?.host == "catalog.test"
		}

		// swiftlint:disable:next static_over_final_class
		override class func canonicalRequest(for request: URLRequest) -> URLRequest {
			request
		}

		override func startLoading() {
			guard let url = request.url,
				  let handler = Self.responseHandler else {
				client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
				return
			}

			let (statusCode, data) = handler(url)
			guard let response = HTTPURLResponse(
				url: url,
				statusCode: statusCode,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Length": String(data.count)]
			) else {
				client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
				return
			}
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		}

		override func stopLoading() { }
	}

	override func tearDown() {
		CatalogURLProtocol.responseHandler = nil
		super.tearDown()
	}

	func testSearch_mergesVisionTasksAndCachesTheQuery() async throws {
		let requestCounter = RequestCounter()
		CatalogURLProtocol.responseHandler = { url in
			requestCounter.increment()
			let task = URLComponents(url: url, resolvingAgainstBaseURL: false)?
				.queryItems?
				.first(where: { $0.name == "pipeline_tag" })?
				.value
			let payload: String
			if task == CatalogTask.objectDetection.rawValue {
				payload = "[{\"id\":\"acme/detector\",\"author\":\"acme\",\"downloads\":12,\"likes\":3,\"siblings\":[{\"rfilename\":\"Detector.mlmodel\"}]}]"
			} else {
				payload = "[{\"id\":\"acme/detector\",\"author\":\"acme\",\"downloads\":12,\"likes\":3,\"siblings\":[{\"rfilename\":\"Detector.mlmodel\"}]},{\"id\":\"acme/classifier\",\"downloads\":5,\"likes\":1,\"siblings\":[{\"rfilename\":\"Classifier.mlmodel\"}]}]"
			}
			return (200, Data(payload.utf8))
		}

		let provider = makeProvider()
		let first = try await provider.search(query: "animals")
		let second = try await provider.search(query: "animals")

		XCTAssertEqual(requestCounter.value, 2, "one request is made for each supported vision task")
		XCTAssertEqual(first.map(\.id), ["acme/detector", "acme/classifier"])
		XCTAssertEqual(second, first)
		XCTAssertEqual(first[0].task, .objectDetection)
		XCTAssertEqual(first[1].task, .imageClassification)
		XCTAssertEqual(first[0].artifactURL?.absoluteString, "https://catalog.test/acme/detector/resolve/main/Detector.mlmodel")
	}

	func testSearch_filtersNestedModelWithoutInstallableArtifact() async throws {
		CatalogURLProtocol.responseHandler = { _ in
			let payload = "[{\"id\":\"acme/unsupported\",\"siblings\":[{\"rfilename\":\"compiled/model.mlmodel\"}]},{\"id\":\"acme/package\",\"siblings\":[{\"rfilename\":\"Package.mlpackage/Data/model.mlmodel\"},{\"rfilename\":\"Package.mlpackage/Manifest.json\"}]}]"
			return (200, Data(payload.utf8))
		}

		let models = try await makeProvider().search(query: "models")

		XCTAssertEqual(models.map(\.id), ["acme/package"])
		XCTAssertEqual(models.first?.format, .mlpackage)
		XCTAssertEqual(models.first?.artifactURL?.lastPathComponent, "Manifest.json")
	}

	func testResolveFiles_prefersSingleModelFile() async throws {
		CatalogURLProtocol.responseHandler = { _ in
			let payload = "{\"siblings\":[{\"rfilename\":\"readme.md\"},{\"rfilename\":\"Detector.mlmodel\",\"size\":42}]}"
			return (200, Data(payload.utf8))
		}

		let files = try await makeProvider().resolveFiles(for: catalogModel())

		XCTAssertEqual(files.count, 1)
		XCTAssertEqual(files[0].relativePath, "Detector.mlmodel")
		XCTAssertEqual(files[0].sizeBytes, 42)
		XCTAssertEqual(files[0].resolveURL.absoluteString, "https://catalog.test/acme/detector/resolve/main/Detector.mlmodel")
	}

	func testResolveFiles_attachesXetMetadataWhenTheHubProvidesIt() async throws {
		CatalogURLProtocol.responseHandler = { url in
			if url.path.contains("/tree/") {
				let payload = "[{\"path\":\"Detector.mlmodel\",\"size\":248,\"xetHash\":\"file-id\"}]"
				return (200, Data(payload.utf8))
			}
			let payload = "{\"siblings\":[{\"rfilename\":\"Detector.mlmodel\"}]}"
			return (200, Data(payload.utf8))
		}

		let files = try await makeProvider().resolveFiles(for: catalogModel())
		let file = try XCTUnwrap(files.first)

		XCTAssertEqual(file.xetFile?.fileID, "file-id")
		XCTAssertEqual(file.xetFile?.sizeBytes, 248)
		XCTAssertEqual(file.xetFile?.repositoryID, "acme/detector")
		XCTAssertEqual(file.xetFile?.hubURL, URL(string: "https://catalog.test"))
		XCTAssertEqual(file.sizeBytes, 248)
		XCTAssertEqual(
			file.xetFile?.tokenURL.absoluteString,
			"https://catalog.test/api/models/acme/detector/xet-read-token/main"
		)
		XCTAssertEqual(
			file.sourceURL?.absoluteString,
			"https://catalog.test/acme/detector/tree/main/Detector.mlmodel"
		)
	}

	func testResolveFiles_collectsOnePackageTree() async throws {
		CatalogURLProtocol.responseHandler = { _ in
			let payload = "{\"siblings\":[{\"rfilename\":\"One.mlpackage/Data/model.bin\",\"size\":10},{\"rfilename\":\"One.mlpackage/Manifest.json\",\"size\":20},{\"rfilename\":\"Other.mlpackage/data\",\"size\":30}]}"
			return (200, Data(payload.utf8))
		}

		let files = try await makeProvider().resolveFiles(for: catalogModel())

		XCTAssertEqual(files.map(\.relativePath), ["One.mlpackage/Manifest.json", "One.mlpackage/Data/model.bin"])
	}

	func testResolveFiles_usesPackageInsteadOfNestedModelFile() async throws {
		CatalogURLProtocol.responseHandler = { _ in
			let payload = "{\"siblings\":[{\"rfilename\":\"One.mlpackage/Data/model.mlmodel\",\"size\":10},{\"rfilename\":\"One.mlpackage/Manifest.json\",\"size\":20}]}"
			return (200, Data(payload.utf8))
		}

		let files = try await makeProvider().resolveFiles(for: catalogModel())

		XCTAssertEqual(files.map(\.relativePath), ["One.mlpackage/Manifest.json", "One.mlpackage/Data/model.mlmodel"])
	}

	func testResolveFiles_usesTreeSizesForEveryPackageFile() async throws {
		CatalogURLProtocol.responseHandler = { url in
			if url.path.contains("/tree/") {
				let payload = "[\n  {\"path\":\"One.mlpackage/Manifest.json\",\"size\":8},\n  {\"path\":\"One.mlpackage/Data/model.mlmodel\",\"size\":12,\"xetHash\":\"model-id\"}\n]"
				return (200, Data(payload.utf8))
			}
			let payload = "{\"siblings\":[{\"rfilename\":\"One.mlpackage/Data/model.mlmodel\"},{\"rfilename\":\"One.mlpackage/Manifest.json\"}]}"
			return (200, Data(payload.utf8))
		}

		let files = try await makeProvider().resolveFiles(for: catalogModel())

		XCTAssertEqual(files.map(\.relativePath), ["One.mlpackage/Manifest.json", "One.mlpackage/Data/model.mlmodel"])
		XCTAssertEqual(files.map(\.sizeBytes), [8, 12])
		XCTAssertEqual(files.last?.xetFile?.fileID, "model-id")
	}

	func testPackageDownloader_assemblesPackageTree() async throws {
		CatalogURLProtocol.responseHandler = { url in
			switch url.lastPathComponent {
			case "Manifest.json": return (200, Data("manifest".utf8))
			case "model.bin": return (200, Data("weights".utf8))
			default: return (404, Data())
			}
		}

		let files = [
			CatalogFile(relativePath: "Animal.mlpackage/Manifest.json", resolveURL: testURL("Manifest.json"), sizeBytes: 8),
			CatalogFile(relativePath: "Animal.mlpackage/Data/model.bin", resolveURL: testURL("model.bin"), sizeBytes: 7)
		]
		let downloader = CatalogPackageDownloader(session: makeSession())
		let events = await downloader.events(for: files)
		var packageURL: URL?

		for try await event in events {
			if case .finished(let url) = event {
				packageURL = url
			}
		}

		let package = try XCTUnwrap(packageURL)
		defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
		XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Manifest.json")), Data("manifest".utf8))
		XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Data/model.bin")), Data("weights".utf8))
	}

	func testPackageDownloader_rejectsDeclaredSizeOverCap() async throws {
		let files = [
			CatalogFile(
				relativePath: "Large.mlpackage/model.bin",
				resolveURL: testURL("model.bin"),
				sizeBytes: CatalogPackageDownloader.maximumTotalBytes + 1
			)
		]
		let events = await CatalogPackageDownloader(session: makeSession()).events(for: files)

		do {
			for try await _ in events { }
			XCTFail("expected the size cap to fail before a download starts")
		} catch let error as CatalogError {
			XCTAssertEqual(error, .tooLarge)
		}
	}

	func testPackageDownloader_forwardsXetByteProgressForMultiFilePackage() async throws {
		CatalogURLProtocol.responseHandler = { url in
			url.lastPathComponent == "Manifest.json" ? (200, Data("manifest".utf8)) : (404, Data())
		}
		let files = [
			CatalogFile(
				relativePath: "Detector.mlpackage/Manifest.json",
				resolveURL: testURL("Manifest.json"),
				sizeBytes: 8
			),
			CatalogFile(
				relativePath: "Detector.mlpackage/Data/model.mlmodel",
				resolveURL: testURL("model.mlmodel"),
				sizeBytes: 4,
				xetFile: HuggingFaceXetFile(fileID: "file-id", tokenURL: URL(string: "https://catalog.test/token")!)
			),
			CatalogFile(
				relativePath: "Detector.mlpackage/Data/weights/weight.bin",
				resolveURL: testURL("weight.bin"),
				sizeBytes: 4,
				xetFile: HuggingFaceXetFile(fileID: "file-id", tokenURL: URL(string: "https://catalog.test/token")!)
			)
		]
		let fakeXetDownload: CatalogXetDownload = { _, _, onBytesWritten in
			onBytesWritten(4)
			let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			try Data("ABCD".utf8).write(to: temporaryURL)
			return temporaryURL
		}
		let events = await CatalogPackageDownloader(
			session: makeSession(),
			xetDownload: fakeXetDownload
		).events(for: files)
		var progress: [CatalogPackageDownloadProgress] = []
		var packageURL: URL?

		for try await event in events {
			switch event {
			case .progress(let update):
				progress.append(update)
			case .finished(let url):
				packageURL = url
			}
		}

		let downloadedPackage = try XCTUnwrap(packageURL)
		defer { try? FileManager.default.removeItem(at: downloadedPackage.deletingLastPathComponent()) }
		XCTAssertEqual(progress.first?.downloadedBytes, 0)
		XCTAssertEqual(progress.last?.downloadedBytes, 16)
		XCTAssertEqual(progress.last?.expectedBytes, 16)
		XCTAssertEqual(progress.last?.completedFileCount, 3)
		XCTAssertTrue(progress.contains { $0.downloadedBytes > 0 && $0.completedFileCount < 3 })
	}

	func testXetProgressByteCount_doesNotTreatSparseLogicalLengthAsDownloadedBytes() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: url) }
		XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))

		let handle = try FileHandle(forWritingTo: url)
		try handle.seek(toOffset: 16 * 1024 * 1024)
		try handle.write(contentsOf: Data([0]))
		try handle.close()

		let logicalByteCount = HuggingFaceXetDownloader.logicalFileSize(at: url)
		let progressByteCount = HuggingFaceXetDownloader.progressByteCount(at: url)

		XCTAssertEqual(logicalByteCount, 16 * 1024 * 1024 + 1)
		XCTAssertLessThan(progressByteCount, logicalByteCount)
	}

	func testAppleCatalog_searchesCuratedInstallableModels() async throws {
		let provider = AppleCoreMLCatalogProvider()

		let models = try await provider.search(query: "yolo tiny")
		let model = try XCTUnwrap(models.first(where: { $0.id == "apple/yolov3-tiny-int8" }))
		let files = try await provider.resolveFiles(for: model)

		XCTAssertEqual(provider.descriptor.id, "apple-coreml")
		XCTAssertEqual(model.providerId, "apple-coreml")
		XCTAssertEqual(model.task, .objectDetection)
		XCTAssertEqual(model.format, .mlmodel)
		XCTAssertEqual(files.count, 1)
		XCTAssertEqual(files[0].relativePath, "YOLOv3TinyInt8LUT.mlmodel")
		XCTAssertEqual(model.artifactURL, files[0].resolveURL)
		XCTAssertEqual(
			files[0].resolveURL.absoluteString,
			"https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel"
		)
	}

	func testAdditionalCuratedProviders_searchOfflineAndResolveDirectArtifacts() async throws {
		let awesome = AwesomeCoreMLCatalogProvider()
		let awesomeModels = try await awesome.search(query: "vehicle")
		let awesomeModel = try XCTUnwrap(awesomeModels.first)
		let awesomeFiles = try await awesome.resolveFiles(for: awesomeModel)

		XCTAssertEqual(awesomeModel.id, "awesome/car-recognition")
		XCTAssertEqual(awesomeModel.task, .imageClassification)
		XCTAssertEqual(awesomeFiles.map(\.relativePath), ["CarRecognition.mlmodel"])
		XCTAssertEqual(awesomeFiles.first?.resolveURL.host, "raw.githubusercontent.com")

		let johnRocky = JohnRockyCoreMLCatalogProvider()
		let johnRockyModels = try await johnRocky.search(query: "yolov5")
		let johnRockyModel = try XCTUnwrap(johnRockyModels.first)
		let johnRockyFiles = try await johnRocky.resolveFiles(for: johnRockyModel)

		XCTAssertEqual(johnRockyModel.id, "john-rocky/yolov5s")
		XCTAssertEqual(johnRockyModel.task, .objectDetection)
		XCTAssertEqual(johnRockyFiles.first?.resolveURL.host, "drive.usercontent.google.com")
		XCTAssertEqual(johnRockyFiles.first?.resolveURL.query?.contains("export=download"), true)
		XCTAssertEqual(johnRockyFiles.first?.relativePath, "yolov5s.mlmodel")

		let github = GitHubCuratedCatalogProvider()
		let githubModels = try await github.search(query: "handwriting")
		let githubModel = try XCTUnwrap(githubModels.first)
		let githubFiles = try await github.resolveFiles(for: githubModel)

		XCTAssertEqual(githubModel.id, "list-coreml/simple-mnist")
		XCTAssertEqual(githubFiles.map(\.relativePath), ["SimpleMnist.mlmodel"])
		XCTAssertEqual(githubFiles.first?.resolveURL.host, "raw.githubusercontent.com")
	}

	func testPintoCatalog_isVisibleButNotSearchableUntilItPublishesDirectArtifacts() async throws {
		let provider = PintoModelZooCatalogProvider()

		XCTAssertEqual(provider.descriptor.id, "pinto-model-zoo")
		XCTAssertFalse(provider.descriptor.isSearchable)
		let models = try await provider.search(query: "yolo")
		XCTAssertTrue(models.isEmpty)
	}
}

@MainActor
final class CatalogSearchManagerTests: XCTestCase {
	func testSearch_queriesAllSelectedSourcesAndFiltersResultsLocally() async {
		let huggingFace = TestCatalogProvider(
			id: "huggingface",
			models: [TestCatalogProvider.model(id: "acme/yolo", providerID: "huggingface")]
		)
		let apple = TestCatalogProvider(
			id: "apple-coreml",
			models: [TestCatalogProvider.model(id: "apple/yolo", providerID: "apple-coreml")]
		)
		let manager = CatalogSearchManager(providers: [huggingFace, apple], searchDebounce: .zero)
		let completed = expectation(description: "search completes")
		let cancellable = manager.$isLoading
			.dropFirst()
			.filter { $0 == false }
			.sink { _ in completed.fulfill() }

		manager.updateQuery("yolo")
		await fulfillment(of: [completed], timeout: 1)
		withExtendedLifetime(cancellable) { }

		XCTAssertEqual(manager.selectedProviderIDs, Set(["huggingface", "apple-coreml"]))
		XCTAssertEqual(Set(manager.results.map(\.providerId)), ["huggingface", "apple-coreml"])
		let huggingFaceSearchCallCount = await huggingFace.searchCallCount
		let appleSearchCallCount = await apple.searchCallCount
		XCTAssertEqual(huggingFaceSearchCallCount, 1)
		XCTAssertEqual(appleSearchCallCount, 1)

		manager.filterResults(to: "apple-coreml")
		XCTAssertEqual(manager.visibleResults.map(\.providerId), ["apple-coreml"])
		let filteredHuggingFaceSearchCallCount = await huggingFace.searchCallCount
		let filteredAppleSearchCallCount = await apple.searchCallCount
		XCTAssertEqual(filteredHuggingFaceSearchCallCount, 1, "result filtering must not make another request")
		XCTAssertEqual(filteredAppleSearchCallCount, 1, "result filtering must not make another request")

		// CatalogBrowseView calls this while its download detail is on screen. The shared manager
		// must retain the already-rendered catalog state when the user navigates back or reopens it.
		cancellable.cancel()
		manager.cancelSearch()
		XCTAssertEqual(manager.query, "yolo")
		XCTAssertEqual(manager.selectedProviderIDs, Set(["huggingface", "apple-coreml"]))
		XCTAssertEqual(manager.resultProviderFilterID, "apple-coreml")
		XCTAssertEqual(manager.visibleResults.map(\.providerId), ["apple-coreml"])
	}

	func testSearch_keepsSuccessfulResultsWhenAnotherSourceFails() async {
		let successfulProvider = TestCatalogProvider(
			id: "apple-coreml",
			models: [TestCatalogProvider.model(id: "apple/mobilenet", providerID: "apple-coreml")]
		)
		let failingProvider = TestCatalogProvider(id: "unavailable", failure: .network)
		let manager = CatalogSearchManager(providers: [successfulProvider, failingProvider], searchDebounce: .zero)
		let completed = expectation(description: "search completes")
		let cancellable = manager.$isLoading
			.dropFirst()
			.filter { $0 == false }
			.sink { _ in completed.fulfill() }

		manager.updateQuery("model")
		await fulfillment(of: [completed], timeout: 1)
		withExtendedLifetime(cancellable) { }

		XCTAssertEqual(manager.results.map(\.id), ["apple/mobilenet"])
		XCTAssertNil(manager.errorMessage)
	}

	func testSearch_excludesUnavailableSourcesFromTheInitialSelection() async {
		let searchable = TestCatalogProvider(
			id: "github-curated",
			models: [TestCatalogProvider.model(id: "list-coreml/mnist", providerID: "github-curated")]
		)
		let unavailable = TestCatalogProvider(id: "pinto-model-zoo", isSearchable: false)
		let manager = CatalogSearchManager(providers: [searchable, unavailable], searchDebounce: .zero)
		let completed = expectation(description: "search completes")
		let cancellable = manager.$isLoading
			.dropFirst()
			.filter { $0 == false }
			.sink { _ in completed.fulfill() }

		manager.updateQuery("mnist")
		await fulfillment(of: [completed], timeout: 1)
		withExtendedLifetime(cancellable) { }

		XCTAssertEqual(manager.selectedProviderIDs, ["github-curated"])
		XCTAssertEqual(manager.searchableProviderDescriptors.map(\.id), ["github-curated"])
		XCTAssertEqual(manager.selectedProviderSummary, L10n.Catalog.Results.allSources)
		let searchableSearchCallCount = await searchable.searchCallCount
		let unavailableSearchCallCount = await unavailable.searchCallCount
		XCTAssertEqual(searchableSearchCallCount, 1)
		XCTAssertEqual(unavailableSearchCallCount, 0)
	}

	func testSearch_keepsTheLastSelectedSourceEnabled() {
		let provider = TestCatalogProvider(id: "github-curated")
		let manager = CatalogSearchManager(providers: [provider], searchDebounce: .zero)

		manager.toggleProvider(id: "github-curated")

		XCTAssertEqual(manager.selectedProviderIDs, ["github-curated"])
		XCTAssertEqual(manager.selectedProviderSummary, L10n.Catalog.Results.allSources)
	}

	func testSearch_clearsResolvedFilesWhenStartingANewSearch() async throws {
		let model = TestCatalogProvider.model(id: "acme/detector", providerID: "huggingface")
		let file = CatalogFile(
			relativePath: "Detector.mlmodel",
			resolveURL: URL(string: "https://catalog.test/Detector.mlmodel") ?? URL(fileURLWithPath: "/"),
			sizeBytes: 1
		)
		let provider = TestCatalogProvider(id: "huggingface", models: [model], resolvedFiles: [file])
		let manager = CatalogSearchManager(providers: [provider], searchDebounce: .zero)

		let firstSearch = expectation(description: "first search completes")
		let cancellable = manager.$isLoading
			.dropFirst()
			.filter { $0 == false }
			.sink { _ in firstSearch.fulfill() }
		manager.updateQuery("model")
		await fulfillment(of: [firstSearch], timeout: 1)
		_ = await manager.resolveFiles(for: model)
		_ = await manager.resolveFiles(for: model)
		let firstResolveCallCount = await provider.resolveCallCount
		XCTAssertEqual(firstResolveCallCount, 1)
		cancellable.cancel()

		let secondSearch = expectation(description: "second search completes")
		let secondCancellable = manager.$isLoading
			.dropFirst()
			.filter { $0 == false }
			.prefix(1)
			.sink { _ in secondSearch.fulfill() }
		manager.updateQuery("models")
		await fulfillment(of: [secondSearch], timeout: 1)
		_ = await manager.resolveFiles(for: model)

		withExtendedLifetime(secondCancellable) { }
		let secondResolveCallCount = await provider.resolveCallCount
		XCTAssertEqual(secondResolveCallCount, 2)
	}
}

private actor TestCatalogProvider: CatalogProvider {
	nonisolated let descriptor: CatalogProviderDescriptor
	private let models: [CatalogModel]
	private let resolvedFiles: [CatalogFile]
	private let failure: CatalogError?
	private(set) var searchCallCount = 0
	private(set) var resolveCallCount = 0

	init(
		id: String,
		models: [CatalogModel] = [],
		resolvedFiles: [CatalogFile] = [],
		failure: CatalogError? = nil,
		isSearchable: Bool = true
	) {
		descriptor = CatalogProviderDescriptor(id: id, displayName: id, isSearchable: isSearchable)
		self.models = models
		self.resolvedFiles = resolvedFiles
		self.failure = failure
	}

	func search(query: String) async throws -> [CatalogModel] {
		searchCallCount += 1
		if let failure { throw failure }
		return models
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		resolveCallCount += 1
		return resolvedFiles
	}

	nonisolated static func model(id: String, providerID: String) -> CatalogModel {
		CatalogModel(
			id: id,
			providerId: providerID,
			displayName: id,
			author: providerID,
			downloads: 0,
			likes: 0,
			task: .objectDetection,
			format: .mlmodel,
			sizeBytes: 1
		)
	}
}

private extension CatalogProviderTests {
	func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [CatalogURLProtocol.self]
		return URLSession(configuration: configuration)
	}

	func makeProvider() -> HuggingFaceCatalogProvider {
		HuggingFaceCatalogProvider(
			client: JSONHTTPClient(session: makeSession()),
			baseURL: URL(string: "https://catalog.test") ?? URL(fileURLWithPath: "/")
		)
	}

	func catalogModel() -> CatalogModel {
		CatalogModel(
			id: "acme/detector",
			providerId: "huggingface",
			displayName: "detector",
			author: "acme",
			downloads: 0,
			likes: 0,
			task: .objectDetection,
			format: nil,
			sizeBytes: nil
		)
	}

	func testURL(_ lastPathComponent: String) -> URL {
		URL(string: "https://catalog.test/files/\(lastPathComponent)") ?? URL(fileURLWithPath: "/")
	}

}
