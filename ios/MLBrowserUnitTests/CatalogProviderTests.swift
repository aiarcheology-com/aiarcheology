//
//  CatalogProviderTests.swift
//  MLBrowserUnitTests
//
//  AIA-0413: catalog provider and package-staging coverage without live network traffic.
//

import XCTest
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
				payload = "[{\"id\":\"acme/detector\",\"author\":\"acme\",\"downloads\":12,\"likes\":3}]"
			} else {
				payload = "[{\"id\":\"acme/detector\",\"author\":\"acme\",\"downloads\":12,\"likes\":3},{\"id\":\"acme/classifier\",\"downloads\":5,\"likes\":1}]"
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

	func testResolveFiles_collectsOnePackageTree() async throws {
		CatalogURLProtocol.responseHandler = { _ in
			let payload = "{\"siblings\":[{\"rfilename\":\"One.mlpackage/Data/model.bin\",\"size\":10},{\"rfilename\":\"One.mlpackage/Manifest.json\",\"size\":20},{\"rfilename\":\"Other.mlpackage/data\",\"size\":30}]}"
			return (200, Data(payload.utf8))
		}

		let files = try await makeProvider().resolveFiles(for: catalogModel())

		XCTAssertEqual(files.map(\.relativePath), ["One.mlpackage/Data/model.bin", "One.mlpackage/Manifest.json"])
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
