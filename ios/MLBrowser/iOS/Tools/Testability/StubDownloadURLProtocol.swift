//
//  StubDownloadURLProtocol.swift
//  AI Archeology
//
//  AIA-0318 UI-test harness: a deterministic, network-free download source. When activated (only
//  under UI tests via the `stubDownloads` launch flag — see `Downloader.foregroundProtocolClasses`),
//  it intercepts requests on the foreground `URLSession` and serves a tiny canned payload so
//  model-lifecycle tests never hit the real network. Inert in shipping: it is only ever inserted
//  into a session's `protocolClasses` under `AppEnvironment.isRunningUITests`.
//

import Foundation

final class StubDownloadURLProtocol: URLProtocol {

    /// The canned payload served for every intercepted request. Not a valid model — the harness
    /// contract is "the download completes deterministically", not "produces a loadable model".
    static let cannedPayload = Data("AIA-STUB-MODEL-PAYLOAD".utf8)

    // This class is only added to a session's `protocolClasses` when gated in
    // (`Downloader.foregroundProtocolClasses`), so being asked to init means it should handle the
    // request. It never registers process-globally, so it cannot intercept anything in shipping.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https" || request.url?.scheme == "http"
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(Self.cannedPayload.count)]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // For a download task, the URL loading system writes these bytes to a temp file and
        // delivers a file URL to the delegate.
        client?.urlProtocol(self, didLoad: Self.cannedPayload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // No async work to cancel — the response is delivered synchronously in startLoading().
    }
}
