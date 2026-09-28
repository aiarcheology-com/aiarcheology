//
//  HeadlessClient.swift
//  HeadlessKitTransport
//
//  AIA-0970.
//

#if canImport(Network)
import Foundation
import HeadlessKit
import Network

/// Talks to a `HeadlessServer`: the handshake, then one request and its response at a time.
public actor HeadlessClient: HeadlessDriving {

	public let endpoint: HeadlessEndpoint
	/// The longest a single request may take, as a last resort against a hung app. Longer than the
	/// session's own wait limit, so a legitimate long `wait` times out in the app, with a response.
	public let requestTimeout: Duration

	public private(set) var serverHello: ServerHello?

	private let queue = DispatchQueue(label: "HeadlessClient")
	private var connection: NWConnection?
	private var buffer = LineBuffer()
	private var lines: [Data] = []
	private var nextID = 0
	/// The last exchange started, which the next one waits for — the connection carries one
	/// request at a time, and interleaved reads would hand one caller another's response.
	private var tail: Task<Void, Never>?

	public init(endpoint: HeadlessEndpoint, requestTimeout: Duration = HeadlessSession.maximumWaitTimeout + .seconds(60)) {
		self.endpoint = endpoint
		self.requestTimeout = requestTimeout
	}

	/// Opens the connection and performs the handshake. Idempotent, and safe to call concurrently
	/// with itself and with `send`: it waits its turn like any exchange.
	@discardableResult
	public func connect() async throws -> ServerHello {
		try await serialized { try await self.establish() }
	}

	public func send(_ command: Command) async throws -> Response {
		try await serialized { try await self.exchange(command) }
	}

	/// The routes from the last handshake; `nil` before `connect()` and after `close()`.
	public func declaredRoutes() async -> [Route]? {
		serverHello?.routes
	}

	/// How long `close()` waits for the server to finish the connection before dropping it.
	public nonisolated static let closeGracePeriod: Duration = .seconds(1)

	/// Ends the connection; the next call reconnects.
	///
	/// Graceful (AIA-0992): it stops sending, then waits — at most ``closeGracePeriod`` — for the
	/// server to close its side, which it does once it has answered everything already sent. By then
	/// the server has given up this client's controller slot, so a client that connects right after
	/// this returns (`up`, then `exec`) is not refused as `busy`. A server still busy with an
	/// abandoned request keeps its side open; the wait then ends at the grace period.
	public func close() async {
		guard let connection else { return drop() }
		self.connection = nil
		drop()
		await Self.finish(connection, within: Self.closeGracePeriod)
	}

	/// Drops the connection and anything half-read from it at once; the next call reconnects.
	private func drop() {
		connection?.cancel()
		connection = nil
		serverHello = nil
		// Bytes from a dead connection must not prefix the next connection's first line.
		buffer = LineBuffer()
		lines.removeAll()
	}

	/// Runs `operation` after every earlier one has finished. Actor isolation alone is not enough:
	/// an exchange suspends while reading, and a second exchange entering then would read the
	/// first one's response.
	private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		let previous = tail
		let current = Task {
			await previous?.value
			return try await operation()
		}
		// Only the ordering is chained; the outcome reaches the caller through `current.value`.
		tail = Task { _ = await current.result }
		return try await current.value
	}

	private func establish() async throws -> ServerHello {
		if let serverHello { return serverHello }
		guard endpoint.port != 0, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
			throw HeadlessTransportError(.connectionFailed, "invalid port \(endpoint.port)")
		}
		drop()
		let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
		self.connection = connection
		do {
			try await withTimeout { try await Self.waitUntilReady(connection, queue: self.queue) }
			try await write(LineBuffer.line(Envelope.ClientHelloLine(hello: ClientHello(token: endpoint.token))))
			let line = try await withTimeout { try await self.readLine() }
			let decoder = HeadlessCoding.makeDecoder()
			if let hello = try? decoder.decode(Envelope.ServerHelloLine.self, from: line).hello {
				serverHello = hello
				return hello
			}
			if let rejection = try? decoder.decode(Envelope.ErrorLine.self, from: line).error {
				throw HeadlessTransportError(.handshakeRejected, rejection.description)
			}
			throw HeadlessTransportError(.malformedMessage, "the server did not answer the hello")
		} catch {
			drop()
			throw error
		}
	}

	// MARK: - Exchange

	private func exchange(_ command: Command) async throws -> Response {
		_ = try await establish()
		nextID += 1
		let id = String(nextID)
		try await write(LineBuffer.line(Request(id: id, command: command)))
		let line = try await withTimeout { try await self.readLine() }
		let response: Response
		do {
			response = try HeadlessCoding.makeDecoder().decode(Response.self, from: line)
		} catch {
			drop()
			throw HeadlessTransportError(.malformedMessage, "unreadable response: \(error)")
		}
		guard response.id == id else {
			drop()
			throw HeadlessTransportError(.malformedMessage, "response \(response.id) does not answer request \(id)")
		}
		return response
	}

	private func write(_ data: Data) async throws {
		guard let connection else { throw HeadlessTransportError(.closed, "not connected") }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			connection.send(content: data, completion: .contentProcessed { error in
				if let error {
					continuation.resume(throwing: HeadlessTransportError(.connectionFailed, "\(error)"))
				} else {
					continuation.resume()
				}
			})
		}
	}

	private func readLine() async throws -> Data {
		while lines.isEmpty {
			guard let connection else { throw HeadlessTransportError(.closed, "not connected") }
			guard let chunk = try await Self.receive(on: connection) else {
				drop()
				throw HeadlessTransportError(.closed, "the server closed the connection")
			}
			do {
				lines.append(contentsOf: try buffer.append(chunk))
			} catch {
				drop()
				throw HeadlessTransportError(.malformedMessage, "line longer than \(LineBuffer.maximumLineLength) bytes")
			}
		}
		return lines.removeFirst()
	}

	/// Runs `operation`, cancelling the connection if it outlives `requestTimeout` — which is also
	/// what unblocks a read still waiting on the socket.
	private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		let timeout = requestTimeout
		let expiry = Expiry()
		do {
			return try await withThrowingTaskGroup(of: T.self) { group in
				group.addTask { try await operation() }
				group.addTask {
					try await Task.sleep(for: timeout)
					// The operation may have won while this slept; it cancelled us, so stop here.
					try Task.checkCancellation()
					expiry.mark()
					await self.drop()
					throw HeadlessTransportError(.timeout, "no answer within \(timeout)")
				}
				defer { group.cancelAll() }
				guard let first = try await group.next() else {
					throw HeadlessTransportError(.closed, "no result")
				}
				return first
			}
		} catch {
			// Closing the connection completes the pending read with "closed", which can reach the
			// group before the timeout's own error does. The caller must still learn it timed out.
			if expiry.hasExpired {
				throw HeadlessTransportError(.timeout, "no answer within \(timeout)")
			}
			throw error
		}
	}

	// MARK: - Network.framework bridges

	private static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
		let once = ResumeOnce()
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			once.install(continuation)
			connection.stateUpdateHandler = { state in
				switch state {
				case .ready:
					once.resume(with: .success(()))
				case .waiting(let error):
					// TCP "waiting" is almost always a refused connection. Retrying it would turn
					// "the app is not running" into a hang, so it fails at once.
					connection.cancel()
					once.resume(with: .failure(HeadlessTransportError(.notRunning, "nothing is listening (\(error))")))
				case .failed(let error):
					once.resume(with: .failure(HeadlessTransportError(.connectionFailed, "\(error)")))
				case .cancelled:
					once.resume(with: .failure(HeadlessTransportError(.closed, "connection cancelled")))
				case .setup, .preparing:
					break
				@unknown default:
					break
				}
			}
			connection.start(queue: queue)
		}
	}

	/// Sends end-of-stream, then reads until the peer finishes too, fails, or `grace` runs out.
	private static func finish(_ connection: NWConnection, within grace: Duration) async {
		connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
		await withTaskGroup(of: Void.self) { group in
			group.addTask {
				// Anything still arriving answers requests nobody waits for any more.
				while true {
					// `nil` both when the server has finished and when the connection failed.
					guard (try? await receive(on: connection)) != nil else { return }
				}
			}
			group.addTask {
				try? await Task.sleep(for: grace)
			}
			await group.next()
			group.cancelAll()
			// Unblocks a read still waiting on the socket, so the group can end.
			connection.cancel()
		}
	}

	/// The next chunk of bytes, or `nil` when the peer has finished.
	private static func receive(on connection: NWConnection) async throws -> Data? {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
			connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
				if let data, data.isEmpty == false {
					continuation.resume(returning: data)
				} else if let error {
					continuation.resume(throwing: HeadlessTransportError(.connectionFailed, "\(error)"))
				} else if isComplete {
					continuation.resume(returning: nil)
				} else {
					continuation.resume(returning: Data())
				}
			}
		}
	}
}

/// Whether a request's timeout fired, readable from any task.
private final class Expiry: @unchecked Sendable {
	// @unchecked: every access to `expired` is under `lock`.
	private let lock = NSLock()
	private var expired = false

	func mark() {
		lock.withLock { expired = true }
	}

	var hasExpired: Bool {
		lock.withLock { expired }
	}
}

/// Resumes a continuation at most once from callbacks on an arbitrary queue.
private final class ResumeOnce: @unchecked Sendable {
	// @unchecked: every access to `continuation` is under `lock`.
	private let lock = NSLock()
	private var continuation: CheckedContinuation<Void, Error>?

	func install(_ continuation: CheckedContinuation<Void, Error>) {
		lock.withLock { self.continuation = continuation }
	}

	func resume(with result: Result<Void, Error>) {
		let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
			defer { continuation = nil }
			return continuation
		}
		pending?.resume(with: result)
	}
}
#endif
