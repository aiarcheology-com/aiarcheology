//
//  FindingsCloudTransport.swift
//  AI Archeology
//
//  The HTTP contract with the findings Worker (AIA-727, backend in AIA-726).
//

import Foundation
import OSLog

/// One finding as the cloud describes it.
///
/// `receivedAt` is the server's own receipt clock and is what paging is done on — never
/// `modifiedAt`. A finding created offline three weeks ago and uploaded today carries a three-week
/// old `modifiedAt`, so a cursor over it would file the finding behind a device's high-water mark
/// and that device would never see it.
struct CloudFindingRow: Sendable, Equatable {
    let id: UUID
    /// Milliseconds since epoch. Integer on the wire on purpose: `Date` carries sub-millisecond
    /// precision, and comparing 1000.7 against a stored 1000 is a difference that never closes.
    let modifiedAt: Int64
    let receivedAt: Int64
    let deleted: Bool
    let bytes: Int
    /// Whether an image is actually stored. A finding may legitimately have none, and a finding
    /// resurrected after a delete has lost the one the delete removed.
    let hasImage: Bool
}

extension CloudFindingRow: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, modifiedAt, receivedAt, deleted, bytes, hasImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .id)
        guard let parsed = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "not a UUID")
        }
        id = parsed
        modifiedAt = try container.decode(Int64.self, forKey: .modifiedAt)
        receivedAt = try container.decode(Int64.self, forKey: .receivedAt)
        deleted = try container.decode(Bool.self, forKey: .deleted)
        bytes = try container.decode(Int.self, forKey: .bytes)
        hasImage = try container.decode(Bool.self, forKey: .hasImage)
    }
}

/// How much of the account's allowance is used. Present on every authenticated JSON response, so
/// the app can warn before it blocks rather than only at the moment an upload fails.
struct CloudUsage: Decodable, Sendable, Equatable {
    let used: Int
    let limit: Int

    var fraction: Double { limit > 0 ? Double(used) / Double(limit) : 0 }
}

struct CloudPage: Decodable, Sendable {
    let findings: [CloudFindingRow]
    let nextCursor: String?
    let hasMore: Bool
    let usage: CloudUsage
}

struct CloudCommit: Decodable, Sendable {
    let finding: CloudFindingRow
    let usage: CloudUsage
}

struct CloudPurge: Decodable, Sendable {
    struct Outcome: Decodable, Sendable {
        /// `false` means call again. It does **not** mean the account may be deleted at Clerk.
        let complete: Bool
        let objects: Int
    }
    let purged: Outcome
}

struct CloudAccepted: Decodable, Sendable {
    /// What the server actually stored, which is not always what was sent: a future-dated client
    /// clock is clamped to receipt time.
    let modifiedAt: Int64
    let usage: CloudUsage
}

/// What went wrong, in the terms the outbox has to act on.
///
/// `code` is the normative key and `retryable` is the summary derived from it — the Worker sends
/// both. The distinction that matters here is between backing off and parking: parking a finding
/// over something transient strands it, and retrying something terminal spins for ever.
enum FindingsCloudError: Error, Sendable {
    /// No base URL for this build. Sync is simply off, which is the state of production until its
    /// Worker exists.
    case notConfigured
    case notSignedIn
    /// Anything below HTTP: no route to host, timeout, aeroplane mode. Always worth retrying.
    case unreachable(String)
    case server(status: Int, code: String, message: String, retryable: Bool, winner: CloudFindingRow?)
    case malformedResponse

    var isRetryable: Bool {
        switch self {
        case .notConfigured, .notSignedIn: return false
        case .unreachable: return true
        case .malformedResponse: return false
        case .server(_, _, _, let retryable, _): return retryable
        }
    }

    /// The Worker's error code, for the cases the outbox treats specially.
    var code: String? {
        if case .server(_, let code, _, _, _) = self { return code }
        return nil
    }

    var winner: CloudFindingRow? {
        if case .server(_, _, _, _, let winner) = self { return winner }
        return nil
    }
}

/// The findings Worker, per environment.
///
/// The base URL is paired with the Clerk instance deliberately: each Worker trusts exactly one
/// Clerk issuer, so a build signing in against the other instance is rejected rather than served.
/// That pairing is the check worth running after a production deploy -- a development token
/// presented to the production Worker must come back 401 (AIA-741).
///
/// Both halves of that pair now come from `BackendEnvironment`, which is fixed at build time.
/// They used to come from two different places — the Clerk key from the distribution channel, this
/// URL from a `UserDefaults` value an App-Store-classified build could never write — and so
/// disagreed permanently on every such build (AIA-0791).
///
/// The Worker's own configuration calls the development environment "staging"; this is the one
/// place the two vocabularies meet.
///
/// A `nil` here turns sync off rather than pointing it somewhere wrong, and the back-up button
/// hides itself when it sees one.
enum FindingsCloudEndpoint {
    static func baseURL(for environment: BackendEnvironment) -> URL? {
        switch environment {
        case .development:
            return URL(string: "https://aia-findings-staging.vladimir-slavik.workers.dev")
        case .production:
            return URL(string: "https://aia-findings-production.vladimir-slavik.workers.dev")
        }
    }
}

/// Talks to the findings Worker. One method per endpoint, no policy: retries, backoff and parking
/// are the sync engine's business.
///
/// An `actor` because this is network work that has no reason to occupy the main actor, and it
/// takes a token *closure* rather than an `AuthProviding` so it does not have to reach back onto
/// the main actor to hold a reference it should not hold.
actor FindingsCloudTransport {
    private let baseURL: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String?

    init(baseURL: URL, session: URLSession = .shared, token: @escaping @Sendable () async throws -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    func list(cursor: String?, limit: Int = 200) async throws -> CloudPage {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await decoding(CloudPage.self, from: request(path: "/v1/findings", query: items))
    }

    func usage() async throws -> CloudUsage {
        struct Envelope: Decodable { let usage: CloudUsage }
        return try await decoding(Envelope.self, from: request(path: "/v1/me/usage")).usage
    }

    func downloadMeta(id: UUID) async throws -> Data {
        try await bytes(from: request(path: "/v1/findings/\(id.uuidString)/meta"))
    }

    func downloadImage(id: UUID) async throws -> Data {
        try await bytes(from: request(path: "/v1/findings/\(id.uuidString)/image"))
    }

    func uploadImage(id: UUID, modifiedAt: Int64, data: Data) async throws -> CloudAccepted {
        var built = request(
            path: "/v1/findings/\(id.uuidString)/image",
            query: [URLQueryItem(name: "modifiedAt", value: String(modifiedAt))]
        )
        built.httpMethod = "PUT"
        built.httpBody = data
        built.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        return try await decoding(CloudAccepted.self, from: built)
    }

    /// Commits the finding. The Worker writes the index row here and nowhere else, so this call is
    /// what makes an upload visible to another device.
    func commitMeta(id: UUID, modifiedAt: Int64, data: Data) async throws -> CloudCommit {
        var built = request(
            path: "/v1/findings/\(id.uuidString)/meta",
            query: [URLQueryItem(name: "modifiedAt", value: String(modifiedAt))]
        )
        built.httpMethod = "PUT"
        built.httpBody = data
        built.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decoding(CloudCommit.self, from: built)
    }

    /// Erases everything this account has stored.
    ///
    /// Must complete before the Clerk user is deleted. Deleting the user first destroys the session
    /// token, and with it the only credential that can reach this data -- which would then sit in
    /// the bucket for ever with nothing able to name it.
    func purgeAccountData() async throws -> CloudPurge {
        var built = request(path: "/v1/me/data")
        built.httpMethod = "DELETE"
        return try await decoding(CloudPurge.self, from: built)
    }

    func delete(id: UUID, modifiedAt: Int64) async throws -> CloudCommit {
        var built = request(
            path: "/v1/findings/\(id.uuidString)",
            query: [URLQueryItem(name: "modifiedAt", value: String(modifiedAt))]
        )
        built.httpMethod = "DELETE"
        return try await decoding(CloudCommit.self, from: built)
    }

    // MARK: - Plumbing

    private func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components?.url ?? baseURL)
        request.httpMethod = "GET"
        return request
    }

    /// Sends the request, attaching a freshly-asked-for token.
    ///
    /// A 401 is retried exactly once with a newly fetched token. Session tokens live about a
    /// minute, so a device that has been offline will routinely present an expired one, and that is
    /// a refresh rather than a failure. Retrying more than once would mean the credential itself is
    /// wrong, which more attempts cannot fix.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = request
        for round in 0...1 {
            guard let bearer = try await token() else { throw FindingsCloudError.notSignedIn }
            attempt.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: attempt)
            } catch let error as URLError {
                throw FindingsCloudError.unreachable(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw FindingsCloudError.malformedResponse }
            if http.statusCode == 401, round == 0 { continue }
            return (data, http)
        }
        throw FindingsCloudError.malformedResponse
    }

    private func bytes(from request: URLRequest) async throws -> Data {
        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(data, http) }
        return data
    }

    private func decoding<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data = try await bytes(from: request)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Deliberately does not log the body: it carries site coordinates and an author name.
            LoggingPolicy.warning("Findings sync could not decode a \(type) response", logger: .networking)
            throw FindingsCloudError.malformedResponse
        }
    }

    private static func failure(_ data: Data, _ http: HTTPURLResponse) -> FindingsCloudError {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let code: String
                let message: String
                let retryable: Bool
                let winner: CloudFindingRow?
            }
            let error: Payload
        }
        guard let payload = try? JSONDecoder().decode(Envelope.self, from: data) else {
            // An unrecognised failure is treated as retryable when the status says the server is
            // having trouble, and terminal otherwise. Guessing the other way round would either
            // spin for ever or discard work.
            return .server(
                status: http.statusCode,
                code: "unknown",
                message: "HTTP \(http.statusCode)",
                retryable: http.statusCode >= 500,
                winner: nil
            )
        }
        return .server(
            status: http.statusCode,
            code: payload.error.code,
            message: payload.error.message,
            retryable: payload.error.retryable,
            winner: payload.error.winner
        )
    }
}
