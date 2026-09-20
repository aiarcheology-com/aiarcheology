import Foundation

public struct XcodeCloudError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct CloudResource<Attributes: Decodable>: Decodable {
    public let id: String
    public let attributes: Attributes
    public let relationships: [String: CloudRelationship]?
}

public struct CloudRelationship: Decodable {
    public struct Identifier: Decodable { public let id: String }
    public let data: Identifier?
}

public struct CloudRun: Decodable {
    public struct Commit: Decodable { public let commitSha: String }
    public let number: Int
    public let createdDate: String
    public let executionProgress: String
    public let completionStatus: String?
    public let isPullRequestBuild: Bool
    public let sourceCommit: Commit?
}

public struct CloudAction: Decodable {
    public let name: String
    public let actionType: String
    public let executionProgress: String
    public let completionStatus: String?
}

public struct CloudIssue: Decodable, Hashable {
    public struct Location: Decodable, Hashable {
        public let path: String
        public let lineNumber: Int?
    }
    public let issueType: String
    public let message: String
    public let fileSource: Location?
}

public struct CloudTestResult: Decodable {
    public let status: String
    public let name: String
    public let className: String?
    public let message: String?
}

private struct CloudReference: Decodable {
    let name: String
    let kind: String
}

private struct CloudPage<T: Decodable>: Decodable {
    struct Links: Decodable { let next: String? }
    let data: [CloudResource<T>]
    let included: [CloudResource<CloudReference>]?
    let links: Links?
}

private struct CloudSingle<T: Decodable>: Decodable {
    let data: CloudResource<T>
}

public struct CloudActionSnapshot {
    public let action: CloudResource<CloudAction>
    public let issues: [CloudIssue]
    /// Nil means results have not been fetched while the action is still running.
    public let tests: [CloudTestResult]?
}

public struct CloudSnapshot {
    public let run: CloudResource<CloudRun>
    public let actions: [CloudActionSnapshot]
    public var isComplete: Bool { run.attributes.executionProgress == "COMPLETE" }
    public var succeeded: Bool { isComplete && run.attributes.completionStatus == "SUCCEEDED" }

    public func report() -> String {
        let build = run.attributes
        var lines = ["Build \(build.number) (\(run.id)) — \(build.executionProgress) / \(build.completionStatus ?? "pending")"]
        if let sha = build.sourceCommit?.commitSha { lines.append("Commit: \(sha)") }
        var printedIssues = Set<CloudIssue>()
        for item in actions {
            let action = item.action.attributes
            let counts = Dictionary(grouping: item.issues, by: \.issueType).mapValues(\.count)
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            lines.append("\(action.name): \(action.executionProgress) / \(action.completionStatus ?? "pending") [\(summary.isEmpty ? "no issues reported" : summary)]")
            if let tests = item.tests {
                let totals = Dictionary(grouping: tests, by: \.status).mapValues(\.count)
                lines.append("  Published tests: \(tests.count) " + totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                for test in tests where !["SUCCESS", "SKIPPED", "EXPECTED_FAILURE"].contains(test.status) {
                    lines.append("  \(test.status): \(test.className ?? "").\(test.name) \(test.message ?? "")")
                }
            } else if action.actionType == "TEST" {
                lines.append("  Test totals pending action completion.")
            }
            for issue in item.issues where printedIssues.insert(issue).inserted {
                let location = issue.fileSource.map { " \($0.path):\($0.lineNumber.map(String.init) ?? "?")" } ?? ""
                lines.append("  \(issue.issueType)\(location): \(issue.message)")
            }
        }
        // API-provided names/messages must not inject terminal control sequences.
        return lines.map { $0.components(separatedBy: .controlCharacters).joined(separator: " ") }.joined(separator: "\n")
    }
}

/// Read-only API traversal. The injected transport keeps authentication out of parsing tests.
public final class XcodeCloudClient {
    private let fetch: (URL) async throws -> Data
    private var completedTests: [String: [CloudTestResult]] = [:]

    public init(fetch: @escaping (URL) async throws -> Data) { self.fetch = fetch }

    public static func identifier(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw XcodeCloudError("Expected a UUID.") }
        // Apple's product lookup is case-sensitive even though the identifier has UUID syntax.
        return value
    }

    public static func buildID(from value: String) throws -> String {
        if UUID(uuidString: value) != nil { return value }
        guard let url = URL(string: value), url.scheme == "https", url.host == "appstoreconnect.apple.com",
              url.user == nil, url.password == nil, url.port == nil else {
            throw XcodeCloudError("Provide a build UUID or an HTTPS App Store Connect build URL.")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 7, parts[0] == "teams", parts[2] == "xcode-cloud",
              parts[3] == "products", parts[5] == "builds",
              UUID(uuidString: parts[1]) != nil, UUID(uuidString: parts[4]) != nil else {
            throw XcodeCloudError("The URL must identify an Xcode Cloud build.")
        }
        return try identifier(parts[6])
    }

    /// Validate *every* pagination link before the transport attaches a bearer token.
    public static func apiURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host == "api.appstoreconnect.apple.com",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/v1/") else {
            throw XcodeCloudError("Refusing an unexpected App Store Connect API URL.")
        }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await fetch(url)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw XcodeCloudError("App Store Connect returned an invalid response for \(url.path).") }
    }

    private func pages<T: Decodable>(_ type: T.Type, path: String) async throws -> [CloudPage<T>] {
        var next: String? = "https://api.appstoreconnect.apple.com/v1/" + path
        var seen = Set<String>()
        var result: [CloudPage<T>] = []
        while let link = next {
            guard seen.insert(link).inserted, seen.count <= 1000 else {
                throw XcodeCloudError("Invalid or excessive API pagination; results are incomplete.")
            }
            let page = try await decode(CloudPage<T>.self, from: Self.apiURL(link))
            result.append(page)
            next = page.links?.next
        }
        return result
    }

    public func latestBuild(branch: String, product: String) async throws -> String {
        let id = try Self.identifier(product)
        let all = try await pages(CloudRun.self, path: "ciProducts/\(id)/buildRuns?limit=200&include=sourceBranchOrTag")
        let references = all.flatMap { $0.included ?? [] }
        let branchIDs = Set(references.filter { $0.attributes.kind == "BRANCH" && $0.attributes.name == branch }.map(\.id))
        let candidates = all.flatMap(\.data).filter {
            !$0.attributes.isPullRequestBuild && branchIDs.contains($0.relationships?["sourceBranchOrTag"]?.data?.id ?? "")
        }
        // The API does not promise newest-first ordering. Inspect all pages and compare timestamps.
        let dated = try candidates.map { run -> (Date, CloudResource<CloudRun>) in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: run.attributes.createdDate)
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime]
                date = formatter.date(from: run.attributes.createdDate)
            }
            guard let date else { throw XcodeCloudError("Invalid build timestamp; cannot select the latest build.") }
            return (date, run)
        }
        guard let latest = dated.max(by: {
            $0.0 == $1.0 ? $0.1.attributes.number < $1.1.attributes.number : $0.0 < $1.0
        }) else { throw XcodeCloudError("No non-PR Xcode Cloud build exists for the requested branch and product.") }
        return try Self.identifier(latest.1.id)
    }

    public func snapshot(buildID: String) async throws -> CloudSnapshot {
        let id = try Self.identifier(buildID)
        let url = try Self.apiURL("https://api.appstoreconnect.apple.com/v1/ciBuildRuns/\(id)")
        let run = try await decode(CloudSingle<CloudRun>.self, from: url).data
        let actions = try await pages(CloudAction.self, path: "ciBuildRuns/\(id)/actions?limit=200").flatMap(\.data)
        let progress = [run.attributes.executionProgress] + actions.map { $0.attributes.executionProgress }
        guard progress.allSatisfy({ ["PENDING", "RUNNING", "COMPLETE"].contains($0) }) else {
            throw XcodeCloudError("Unknown Xcode Cloud execution progress; cannot reliably observe completion.")
        }
        var snapshots: [CloudActionSnapshot] = []
        for action in actions {
            let actionID = try Self.identifier(action.id)
            let issues = try await pages(CloudIssue.self, path: "ciBuildActions/\(actionID)/issues?limit=200").flatMap(\.data).map(\.attributes)
            var tests: [CloudTestResult]?
            if action.attributes.actionType == "TEST", action.attributes.executionProgress == "COMPLETE" {
                if let cached = completedTests[actionID] { tests = cached }
                else {
                    let results = try await pages(CloudTestResult.self, path: "ciBuildActions/\(actionID)/testResults?limit=200").flatMap(\.data).map(\.attributes)
                    tests = results
                    // Empty results can be transient while Apple publishes artifacts; retry them.
                    if !results.isEmpty { completedTests[actionID] = results }
                }
            }
            snapshots.append(CloudActionSnapshot(action: action, issues: issues, tests: tests))
        }
        return CloudSnapshot(run: run, actions: snapshots)
    }
}
