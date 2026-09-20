import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import ProjectToolCore

extension ASC {
    struct Cloud: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cloud",
            abstract: "Observe an Xcode Cloud build, its actions, issues and test results (read-only).",
            discussion: """
                Supply a build UUID / App Store Connect build URL, or --branch with an optional
                --product. Branch selection finds the latest non-PR build across all workflows.
                --watch stays on that selected build and stops when it finishes; it never starts
                or cancels a build. Use a build URL to select a particular workflow or PR build.

                Credentials must already be materialized by `ProjectTool asc credentials generate`
                in ios/asc.auth. Tokens stay in memory and are refreshed for each API request.
                A completed unsuccessful build exits 1. A running one-shot observation exits 0;
                that exit status is not a claim that the build passed.
                """
        )

        @Argument(help: "Build UUID or full App Store Connect Xcode Cloud build URL.")
        var build: String?

        @Option(name: .long, help: "Exact source branch name, such as develop or release/1.0.9.")
        var branch: String?

        @Option(name: .long, help: "Xcode Cloud product UUID used with --branch. Defaults to ML Browser.")
        var product = "DAB07D52-E272-4541-B291-2A4D581A5EF5"

        @Flag(name: .long, help: "Poll the selected build until it completes; Ctrl-C stops observation.")
        var watch = false

        @Option(name: .long, help: "Seconds between polls in watch mode (minimum 5).")
        var interval: Int = 60

        mutating func validate() throws {
            guard (build != nil) != (branch != nil), branch?.isEmpty != true else {
                throw ValidationError("Supply exactly one build UUID/URL or --branch NAME.")
            }
            guard (5...86400).contains(interval) else { throw ValidationError("--interval must be 5...86400 seconds.") }
            if let build { _ = try XcodeCloudClient.buildID(from: build) }
            _ = try XcodeCloudClient.identifier(product)
        }

        func run() async throws {
            guard let keyID = Credentials.materializedKeyID() else {
                throw ValidationError("Secure ios/asc.auth credentials are missing. Run: swift run --package-path Tools ProjectTool asc credentials generate")
            }
            let issuer = try String(contentsOfFile: Credentials.Paths.issuerID(), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key: P256.Signing.PrivateKey
            do {
                key = try P256.Signing.PrivateKey(pemRepresentation: String(
                    contentsOfFile: Credentials.Paths.key(forKeyID: keyID), encoding: .utf8))
            } catch { throw ValidationError("Cannot read the materialized App Store Connect signing key.") }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration, delegate: CloudRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let client = XcodeCloudClient { url in
                // Validate again at the credential boundary, including API-provided next links.
                _ = try XcodeCloudClient.apiURL(url.absoluteString)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                let token = try Token.sign(key: key, keyID: keyID, issuer: issuer, ttl: 900)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let data: Data
                let response: URLResponse
                do { (data, response) = try await session.data(for: request) } catch { throw XcodeCloudError("App Store Connect network request failed; retry observation.") }
                guard let http = response as? HTTPURLResponse else {
                    throw XcodeCloudError("Missing App Store Connect HTTP response.")
                }
                guard http.statusCode == 200 else {
                    // Do not echo response bodies, auth headers or signed URLs into diagnostics.
                    throw XcodeCloudError("App Store Connect HTTP \(http.statusCode) for \(url.path). Check credentials/permissions for 401/403; retry later for 429/5xx.")
                }
                return data
            }
            let selectedID: String
            if let build { selectedID = try XcodeCloudClient.buildID(from: build) } else if let branch { selectedID = try await client.latestBuild(branch: branch, product: product) } else { throw ValidationError("Supply a build or branch.") }

            repeat {
                let snapshot = try await client.snapshot(buildID: selectedID)
                print("\nChecked \(ISO8601DateFormatter().string(from: Date()))")
                print(snapshot.report())
                fflush(stdout) // Make each poll visible immediately when piped to a log or tee.
                if snapshot.isComplete {
                    if !snapshot.succeeded { throw ExitCode.failure }
                    return
                }
                if !watch { return }
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            } while true
        }
    }
}

/// Never follow redirects with account credentials, even to another Apple service.
private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
