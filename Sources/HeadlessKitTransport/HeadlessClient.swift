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

	/// Opens the connection and performs the handshake. Idempotent.
	@discardableResult
	public func connect() async throws -> ServerHello {
		if let serverHello { return serverHello }
		guard endpoint.port != 0, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
			throw HeadlessTransportError(.connectionFailed, "invalid port \(endpoint.port)")
		}
		let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
		self.connection = connection
		try await withTimeout { try await Self.waitUntilReady(connection, queue: self.queue) }
		try await write(LineBuffer.line(Envelope.ClientHelloLine(hello: ClientHello(token: endpoint.token))))
		let line = try await withTimeout { try await self.readLine() }
		let decoder = HeadlessCoding.makeDecoder()
		if let hello = try? decoder.decode(Envelope.ServerHelloLine.self, from: line).hello {
			serverHello = hello
			return hello
		}
		close()
		if let rejection = try? decoder.decode(Envelope.ErrorLine.self, from: line).error {
			throw HeadlessTransportError(.handshakeRejected, rejection.description)
		}
		throw HeadlessTransportError(.malformedMessage, "the server did not answer the hello")
	}

	public func send(_ command: Command) async throws -> Response {
		let previous = tail
		let exchange = Task {
			await previous?.value
			return try await self.exchange(command)
		}
		// Only the ordering is chained; the outcome reaches the caller through `exchange.value`.
		tail = Task { _ = await exchange.result }
		return try await exchange.value
	}

	public func close() {
		connection?.cancel()
		connection = nil
		serverHello = nil
	}

	// MARK: - Exchange

	private func exchange(_ command: Command) async throws -> Response {
		try await connect()
		nextID += 1
		let id = String(nextID)
		try await write(LineBuffer.line(Request(id: id, command: command)))
		let line = try await withTimeout { try await self.readLine() }
		let response: Response
		do {
			response = try HeadlessCoding.makeDecoder().decode(Response.self, from: line)
		} catch {
			close()
			throw HeadlessTransportError(.malformedMessage, "unreadable response: \(error)")
		}
		guard response.id == id else {
			close()
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
				close()
				throw HeadlessTransportError(.closed, "the server closed the connection")
			}
			do {
				lines.append(contentsOf: try buffer.append(chunk))
			} catch {
				close()
				throw HeadlessTransportError(.malformedMessage, "line longer than \(LineBuffer.maximumLineLength) bytes")
			}
		}
		return lines.removeFirst()
	}

	/// Runs `operation`, cancelling the connection if it outlives `requestTimeout` — which is also
	/// what unblocks a read still waiting on the socket.
	private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		let timeout = requestTimeout
		return try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await operation() }
			group.addTask {
				try await Task.sleep(for: timeout)
				await self.close()
				throw HeadlessTransportError(.timeout, "no answer within \(timeout)")
			}
			defer { group.cancelAll() }
			guard let first = try await group.next() else {
				throw HeadlessTransportError(.closed, "no result")
			}
			return first
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
