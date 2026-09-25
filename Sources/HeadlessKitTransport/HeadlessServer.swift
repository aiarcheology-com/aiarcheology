//
//  HeadlessServer.swift
//  HeadlessKitTransport
//
//  AIA-0970.
//

#if canImport(Network)
import Foundation
import HeadlessKit
import Network

/// Serves a `HeadlessSession` as JSON Lines over TCP on the loopback interface.
///
/// Binds an ephemeral port, so parallel instances on one machine — several simulators share the
/// host's loopback — can never race for a port chosen in advance. The chosen port and a per-launch
/// token are published to `endpointFile` for the client that launched the app to read.
///
/// Callbacks are delivered on the main queue, which is what lets them enter the session's main
/// actor directly; the traffic is one small command at a time, so the main thread is not a
/// bottleneck.
@MainActor
public final class HeadlessServer {

	public let session: HeadlessSession
	public let token: String
	public private(set) var endpoint: HeadlessEndpoint?

	private let endpointFile: URL?
	private var listener: NWListener?
	private var connections: [ObjectIdentifier: ServerConnection] = [:]

	/// - Parameters:
	///   - endpointFile: where to publish `{host, port, token}` once listening, readable only by
	///     the owner. Removed again by `stop()`, so a stale file never points at a dead app.
	public init(session: HeadlessSession, token: String = HeadlessServer.makeToken(), endpointFile: URL? = nil) {
		self.session = session
		self.token = token
		self.endpointFile = endpointFile
	}

	/// 256 random bits as hex, from the system's cryptographically secure generator.
	public nonisolated static func makeToken() -> String {
		var generator = SystemRandomNumberGenerator()
		return (0..<4).map { _ in
			let word: UInt64 = generator.next()
			return String(word, radix: 16).leftPadded(to: 16)
		}.joined()
	}

	/// Starts listening and returns where. Calling it again returns the same endpoint.
	@discardableResult
	public func start() async throws -> HeadlessEndpoint {
		if let endpoint { return endpoint }
		let parameters = NWParameters.tcp
		// Both, deliberately: the interface restriction keeps the listener off every network
		// interface, and the local endpoint pins the address clients are told to use.
		parameters.requiredInterfaceType = .loopback
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
		let listener = try NWListener(using: parameters)
		self.listener = listener
		listener.newConnectionHandler = { [weak self] connection in
			MainActor.assumeIsolated { self?.accept(connection) }
		}
		let readiness = Readiness()
		let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
			readiness.continuation = continuation
			listener.stateUpdateHandler = { state in
				MainActor.assumeIsolated {
					switch state {
					case .ready:
						if let port = listener.port?.rawValue, port != 0 {
							readiness.resume(with: .success(port))
						} else {
							readiness.resume(with: .failure(HeadlessTransportError(.connectionFailed, "listener has no port")))
						}
					case .failed(let error), .waiting(let error):
						readiness.resume(with: .failure(error))
					case .cancelled:
						readiness.resume(with: .failure(HeadlessTransportError(.closed, "listener cancelled")))
					case .setup:
						break
					@unknown default:
						break
					}
				}
			}
			listener.start(queue: .main)
		}
		let endpoint = HeadlessEndpoint(port: port, token: token)
		do {
			try publish(endpoint)
		} catch {
			stop()
			throw error
		}
		self.endpoint = endpoint
		return endpoint
	}

	/// Stops listening, drops every connection and removes the endpoint file.
	public func stop() {
		listener?.cancel()
		listener = nil
		for connection in connections.values {
			connection.close()
		}
		connections.removeAll()
		endpoint = nil
		if let endpointFile {
			do {
				try FileManager.default.removeItem(at: endpointFile)
			} catch CocoaError.fileNoSuchFile {
				// Never published (start failed early) — nothing to remove.
			} catch {
				assertionFailure("Could not remove the headless endpoint file: \(error)")
			}
		}
	}

	private func publish(_ endpoint: HeadlessEndpoint) throws {
		guard let endpointFile else { return }
		try FileManager.default.createDirectory(
			at: endpointFile.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		// Atomic, so a client polling for the file never reads half of it.
		try HeadlessCoding.makeEncoder().encode(endpoint).write(to: endpointFile, options: [.atomic])
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFile.path)
	}

	private func accept(_ nwConnection: NWConnection) {
		let connection = ServerConnection(connection: nwConnection, server: self)
		connections[ObjectIdentifier(connection)] = connection
		connection.start()
	}

	fileprivate func connectionClosed(_ connection: ServerConnection) {
		connections[ObjectIdentifier(connection)] = nil
	}
}

/// Resumes the start continuation exactly once, whichever listener state arrives first.
@MainActor
private final class Readiness {
	var continuation: CheckedContinuation<UInt16, Error>?

	func resume(with result: Result<UInt16, Error>) {
		continuation?.resume(with: result)
		continuation = nil
	}
}

/// One client connection: a handshake, then requests answered in order.
@MainActor
private final class ServerConnection {

	private let connection: NWConnection
	private weak var server: HeadlessServer?
	private var buffer = LineBuffer()
	private var isAuthenticated = false
	private var isClosed = false
	/// The last request accepted on this connection, so responses leave in request order.
	private var tail: Task<Void, Never>?

	init(connection: NWConnection, server: HeadlessServer) {
		self.connection = connection
		self.server = server
	}

	func start() {
		connection.stateUpdateHandler = { [weak self] state in
			MainActor.assumeIsolated {
				switch state {
				case .failed, .cancelled:
					self?.close()
				default:
					break
				}
			}
		}
		connection.start(queue: .main)
		receive()
	}

	func close() {
		guard isClosed == false else { return }
		isClosed = true
		connection.cancel()
		server?.connectionClosed(self)
	}

	private func receive() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
			MainActor.assumeIsolated {
				self?.received(data, isComplete: isComplete, failed: error != nil)
			}
		}
	}

	private func received(_ data: Data?, isComplete: Bool, failed: Bool) {
		guard isClosed == false else { return }
		if let data, data.isEmpty == false {
			do {
				for line in try buffer.append(data) {
					handle(line)
				}
			} catch {
				reject(HeadlessError(.malformedRequest, "line longer than \(LineBuffer.maximumLineLength) bytes"))
				return
			}
		}
		if failed {
			close()
		} else if isComplete {
			// The client finished sending. Answer what it already asked, then close.
			let pending = tail
			Task { @MainActor [weak self] in
				await pending?.value
				self?.close()
			}
		} else {
			receive()
		}
	}

	private func handle(_ line: Data) {
		guard isAuthenticated else {
			authenticate(line)
			return
		}
		let previous = tail
		tail = Task { @MainActor [weak self] in
			await previous?.value
			await self?.answer(line)
		}
	}

	private func authenticate(_ line: Data) {
		guard let server else { return close() }
		let decoder = HeadlessCoding.makeDecoder()
		guard let hello = try? decoder.decode(Envelope.ClientHelloLine.self, from: line).hello else {
			return reject(HeadlessError(.malformedRequest, "the first line must be a hello"))
		}
		guard hello.protocolVersion == HeadlessProtocol.version else {
			return reject(HeadlessError(
				.protocolMismatch,
				"server speaks protocol \(HeadlessProtocol.version), client \(hello.protocolVersion)"
			))
		}
		guard Self.constantTimeEquals(hello.token, server.token) else {
			return reject(HeadlessError(.unauthorized, "wrong token"))
		}
		isAuthenticated = true
		send(Envelope.ServerHelloLine(hello: server.session.serverHello))
	}

	private func answer(_ line: Data) async {
		guard let server, isClosed == false else { return }
		let decoder = HeadlessCoding.makeDecoder()
		let response: Response
		do {
			let request = try decoder.decode(Request.self, from: line)
			response = await server.session.handle(request)
		} catch {
			// Echo the id when there is one, so the client can still pair the failure with its request.
			let id = (try? decoder.decode(JSONValue.self, from: line))?.value(at: "/id")?.stringValue ?? ""
			response = server.session.reject(id: id, error: HeadlessError(.malformedRequest, Self.describe(error)))
		}
		send(response)
	}

	private func reject(_ error: HeadlessError) {
		send(Envelope.ErrorLine(error: error), thenClose: true)
	}

	private func send<T: Encodable>(_ value: T, thenClose: Bool = false) {
		guard isClosed == false else { return }
		let data: Data
		do {
			data = try LineBuffer.line(value)
		} catch {
			assertionFailure("Could not encode a headless message: \(error)")
			return close()
		}
		connection.send(content: data, completion: .contentProcessed { [weak self] _ in
			guard thenClose else { return }
			MainActor.assumeIsolated { self?.close() }
		})
	}

	/// Compares without an early exit, so response timing reveals nothing about the token.
	private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
		let left = Array(lhs.utf8)
		let right = Array(rhs.utf8)
		guard left.count == right.count else { return false }
		var difference: UInt8 = 0
		for index in left.indices {
			difference |= left[index] ^ right[index]
		}
		return difference == 0
	}

	private static func describe(_ error: Error) -> String {
		switch error {
		case DecodingError.dataCorrupted(let context):
			return context.debugDescription
		case DecodingError.keyNotFound(let key, _):
			return "missing '\(key.stringValue)'"
		case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
			let path = context.codingPath.map(\.stringValue).joined(separator: ".")
			return "wrong type at '\(path)'"
		default:
			return "not a request"
		}
	}
}

private extension String {
	func leftPadded(to length: Int) -> String {
		count >= length ? self : String(repeating: "0", count: length - count) + self
	}
}
#endif
