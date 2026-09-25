//
//  HeadlessServer.swift
//  HeadlessKitTransport
//
//  AIA-0970.
//

#if canImport(Network)
import Darwin
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

	/// How long a connection may stay open without a valid hello, by default.
	public nonisolated static let defaultHandshakeTimeout: Duration = .seconds(10)

	public let session: HeadlessSession
	public let token: String
	public let handshakeTimeout: Duration
	public private(set) var endpoint: HeadlessEndpoint?

	private let endpointFile: URL?
	private var listener: NWListener?
	private var starting: Task<HeadlessEndpoint, Error>?
	private var connections: [ObjectIdentifier: ServerConnection] = [:]

	/// Open connections, for tests.
	var connectionCount: Int { connections.count }

	/// - Parameters:
	///   - endpointFile: where to publish `{host, port, token}` once listening, readable only by
	///     the owner. Removed again by `stop()`. A process that is killed cannot remove it, so a
	///     client must treat a refused connection as "not running" whatever the file says.
	public init(
		session: HeadlessSession,
		token: String = HeadlessServer.makeToken(),
		endpointFile: URL? = nil,
		handshakeTimeout: Duration = HeadlessServer.defaultHandshakeTimeout
	) {
		self.session = session
		self.token = token
		self.handshakeTimeout = handshakeTimeout
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

	/// Starts listening and returns where. Concurrent and repeated calls share one listener.
	@discardableResult
	public func start() async throws -> HeadlessEndpoint {
		if let endpoint { return endpoint }
		if let starting { return try await starting.value }
		let attempt = Task { try await self.listen() }
		starting = attempt
		defer { starting = nil }
		return try await attempt.value
	}

	/// Stops listening, drops every connection and removes the endpoint file.
	public func stop() {
		starting?.cancel()
		if let listener {
			listener.stateUpdateHandler = nil
			listener.newConnectionHandler = nil
			listener.cancel()
		}
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

	private func listen() async throws -> HeadlessEndpoint {
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
		do {
			let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
				readiness.continuation = continuation
				// Weak: the listener owns this handler, and a strong capture would keep it alive forever.
				listener.stateUpdateHandler = { [weak listener] state in
					MainActor.assumeIsolated {
						switch state {
						case .ready:
							if let port = listener?.port?.rawValue, port != 0 {
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
			try publish(endpoint)
			self.endpoint = endpoint
			return endpoint
		} catch {
			// Leave nothing behind: a listener that failed to become ready, or whose endpoint could not
			// be published, must not keep accepting connections nobody can authenticate.
			stop()
			throw error
		}
	}

	/// Writes the endpoint where only the owner can read it — created that way, then renamed into
	/// place, so it is never readable by others and never half-written.
	private func publish(_ endpoint: HeadlessEndpoint) throws {
		guard let endpointFile else { return }
		let directory = endpointFile.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let staging = directory.appendingPathComponent(".\(endpointFile.lastPathComponent).\(UUID().uuidString)")
		let data = try HeadlessCoding.makeEncoder().encode(endpoint)
		guard FileManager.default.createFile(
			atPath: staging.path,
			contents: data,
			attributes: [.posixPermissions: 0o600]
		) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path])
		}
		guard rename(staging.path, endpointFile.path) == 0 else {
			let code = POSIXErrorCode(rawValue: errno) ?? .EIO
			try? FileManager.default.removeItem(at: staging) // Best effort: the rename error is what matters.
			throw POSIXError(code)
		}
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

	private enum Phase {
		case awaitingHello
		case authenticated
		/// The client finished sending. Requests already accepted are answered, then the connection closes.
		case finishing
		/// A protocol violation was answered with an error; nothing else is read or answered.
		case rejecting
		case closed

		var readsInput: Bool { self == .awaitingHello || self == .authenticated }
		var answersRequests: Bool { self == .authenticated || self == .finishing }
	}

	private let connection: NWConnection
	private weak var server: HeadlessServer?
	private var buffer = LineBuffer()
	private var phase = Phase.awaitingHello
	/// The last request accepted on this connection, so responses leave in request order.
	private var tail: Task<Void, Never>?
	/// Sends handed to the network and not yet processed. Cancelling the connection while any is
	/// outstanding discards it, so a close waits for this to reach zero.
	private var pendingSends = 0
	/// Requests accepted and not yet answered.
	private var pendingAnswers = 0
	private var handshakeDeadline: Task<Void, Never>?

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
		let timeout = server?.handshakeTimeout ?? HeadlessServer.defaultHandshakeTimeout
		handshakeDeadline = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: timeout)
			} catch {
				return // Cancelled: the hello arrived, or the connection is already gone.
			}
			guard let self, self.phase == .awaitingHello else { return }
			self.reject(HeadlessError(.unauthorized, "no hello within \(timeout)"))
		}
		receive()
	}

	/// Closes at once, discarding anything not yet sent.
	func close() {
		guard phase != .closed else { return }
		phase = .closed
		handshakeDeadline?.cancel()
		connection.stateUpdateHandler = nil
		connection.cancel()
		server?.connectionClosed(self)
	}

	/// Stops reading, answers what was already accepted, then closes once every answer is out.
	private func finish() {
		guard phase.readsInput else { return }
		phase = .finishing
		closeIfDrained()
	}

	/// Closes once nothing is left to say: no accepted request still waiting for its answer, and no
	/// answer still being sent. Closing any earlier discards output the client is owed.
	private func closeIfDrained() {
		guard phase == .finishing || phase == .rejecting, pendingAnswers == 0, pendingSends == 0 else { return }
		close()
	}

	private func receive() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
			MainActor.assumeIsolated {
				self?.received(data, isComplete: isComplete, failed: error != nil)
			}
		}
	}

	private func received(_ data: Data?, isComplete: Bool, failed: Bool) {
		guard phase.readsInput else { return }
		if let data, data.isEmpty == false {
			do {
				for line in try buffer.append(data) {
					handle(line)
					// A rejected hello stops everything after it in the same chunk.
					guard phase.readsInput else { return }
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
			finish()
		} else {
			receive()
		}
	}

	private func handle(_ line: Data) {
		guard phase == .authenticated else {
			authenticate(line)
			return
		}
		pendingAnswers += 1
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
		phase = .authenticated
		handshakeDeadline?.cancel()
		send(Envelope.ServerHelloLine(hello: server.session.serverHello))
	}

	private func answer(_ line: Data) async {
		defer {
			pendingAnswers -= 1
			closeIfDrained()
		}
		guard let server, phase.answersRequests else { return }
		let decoder = HeadlessCoding.makeDecoder()
		let response: Response
		do {
			let request = try decoder.decode(Request.self, from: line)
			response = await server.session.handle(request)
		} catch {
			// Echo the id when there is one, so the client can still pair the failure with its request.
			let id = (try? decoder.decode(JSONValue.self, from: line))?.value(at: "/id")?.stringValue ?? ""
			let failure = (error as? HeadlessError) ?? HeadlessError(.malformedRequest, Self.describe(error))
			response = server.session.reject(id: id, error: failure)
		}
		send(response)
	}

	private func reject(_ error: HeadlessError) {
		guard phase.readsInput else { return }
		send(Envelope.ErrorLine(error: error))
		phase = .rejecting
		closeIfDrained()
	}

	private func send<T: Encodable>(_ value: T) {
		guard phase != .closed else { return }
		let data: Data
		do {
			data = try LineBuffer.line(value)
		} catch {
			assertionFailure("Could not encode a headless message: \(error)")
			return close()
		}
		pendingSends += 1
		connection.send(content: data, completion: .contentProcessed { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.pendingSends -= 1
				self.closeIfDrained()
			}
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
