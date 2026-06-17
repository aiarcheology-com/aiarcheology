//
//  StubDownloadURLProtocolTests.swift
//  MLBrowserUnitTests
//
//  AIA-0318: covers the model-download stub harness — both the URLProtocol (serves a completing
//  download deterministically, no network) and the gating logic that decides when Downloader's
//  foreground session uses it. The live end-to-end path (add model by URL -> download completes in
//  the list) is exercised by AIA-0319, which builds that UI flow.
//

import XCTest
@testable import ML_Browser

final class StubDownloadURLProtocolTests: XCTestCase {

    /// Reads the downloaded file's bytes inside the delegate callback — the temp file is removed
    /// once the callback returns, so the URL alone would be useless afterwards.
    private final class DownloadSpy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        var downloadedData: Data?
        var completionError: Error?
        let finished = XCTestExpectation(description: "download task finished")

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            downloadedData = try? Data(contentsOf: location)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completionError = error
            finished.fulfill()
        }
    }

    // (a) The stub serves the canned payload through a real downloadTask (same API as production).
    func testStub_servesCannedPayloadThroughDownloadTask() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadURLProtocol.self]
        let spy = DownloadSpy()
        let session = URLSession(configuration: configuration, delegate: spy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "https://example.com/model.mlmodel"))
        session.downloadTask(with: url).resume()

        wait(for: [spy.finished], timeout: 5)
        XCTAssertNil(spy.completionError, "stubbed download should not error")
        let data = try XCTUnwrap(spy.downloadedData, "no file delivered to the download delegate")
        // Non-empty guard: a download task yields a temp file; an empty file would false-pass the
        // byte-equality below if URLProtocol didn't actually materialize the payload.
        XCTAssertFalse(data.isEmpty, "downloaded file is empty — the stub payload was not written")
        XCTAssertEqual(data, StubDownloadURLProtocol.cannedPayload)
    }

    // (b) The gating decision: the stub is prepended only under UI tests with the flag, and the
    // existing protocol classes are preserved.
    func testForegroundProtocolClasses_gating() {
        let base: [AnyClass] = []
        XCTAssertTrue(
            Downloader.foregroundProtocolClasses(base: base, isUITest: true, stubDownloads: true).first === StubDownloadURLProtocol.self,
            "stub should be prepended under UI tests with the flag"
        )
        XCTAssertTrue(
            Downloader.foregroundProtocolClasses(base: base, isUITest: true, stubDownloads: false).isEmpty,
            "no stub without the flag"
        )
        XCTAssertTrue(
            Downloader.foregroundProtocolClasses(base: base, isUITest: false, stubDownloads: true).isEmpty,
            "no stub outside UI tests (shipping/unit paths untouched)"
        )

        let withExisting = Downloader.foregroundProtocolClasses(base: [StubDownloadURLProtocol.self], isUITest: true, stubDownloads: true)
        XCTAssertEqual(withExisting.count, 2, "existing protocol classes must be preserved, not replaced")
    }

    // (c) canInit only claims http(s) requests.
    func testCanInit_onlyClaimsHTTP() throws {
        let https = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com")))
        let file = URLRequest(url: try XCTUnwrap(URL(string: "file:///tmp/x")))
        XCTAssertTrue(StubDownloadURLProtocol.canInit(with: https))
        XCTAssertFalse(StubDownloadURLProtocol.canInit(with: file))
    }
}
