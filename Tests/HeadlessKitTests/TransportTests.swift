//
//  TransportTests.swift
//  HeadlessKitTests
//
//  AIA-0970.
//

#if canImport(Network)
import Darwin
import Foundation
import XCTest
import HeadlessKit
@testable import HeadlessKitTransport

@MainActor
final class TransportTests: XCTestCase {

	private var app: CounterApp!
	private var server: HeadlessServer!
	private var directory: URL!

	override func setUp() async throws {
		app = CounterApp()
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessKitTests-\(UUID().uuidString)")
		server = makeServer()
	}

	override func tearDown() async throws {
		server.stop()
		try? FileManager.default.removeItem(at: directory) // Best-effort cleanup of a temp directory.
		server = nil
		app = nil
	}

	private func makeServer(handshakeTimeout: Duration = HeadlessServer.defaultHandshakeTimeout) -> HeadlessServer {
		HeadlessServer(
			session: HeadlessSession(application: app, pollInterval: .milliseconds(5)),
			endpointFile: directory.appendingPathComponent("endpoint.json"),
			handshakeTimeout: handshakeTimeout
		)
	}

	// MARK: - Client and server

	func testClientDrivesTheAppOverLoopback() async throws {
		let endpoint = try await server.start()
		XCTAssertEqual(endpoint.host, "127.0.0.1")
		XCTAssertNotEqual(endpoint.port, 0)

		let client = HeadlessClient(endpoint: endpoint)
		let hello = try await client.connect()
		XCTAssertEqual(hello.protocolVersion, HeadlessProtocol.version)
		XCTAssertEqual(hello.metadata["app"], "counter")

		let increment = try await client.send(.perform(action: "increment", arguments: ["by": 2]))
		XCTAssertEqual(increment.state, ["count": 2])
		let moved = try await client.send(.goto("drawer"))
		XCTAssertEqual(moved.route, "drawer")
		let refused = try await client.send(.goto("nowhere"))
		XCTAssertEqual(refused.error?.code, .invalidArgument, "an app-level error is a response, not a thrown error")
		let unreachable = try await client.send(.goto("about"))
		XCTAssertEqual(unreachable.error?.code, .unreachable, "a declared route no action here leads to")
		let declared = await client.declaredRoutes()
		XCTAssertEqual(declared, CounterApp.declaredMap.routeNames, "the client keeps the routes from the hello")
		await client.close()
		XCTAssertEqual(app.count, 2)
	}

	func testConcurrentStartsShareOneListener() async throws {
		let server: HeadlessServer = self.server
		async let first = server.start()
		async let second = server.start()
		let (a, b) = try await (first, second)
		XCTAssertEqual(a, b)
	}

	func testConcurrentConnectsOpenOneConnection() async throws {
		let endpoint = try await server.start()
		let client = HeadlessClient(endpoint: endpoint)
		async let first = client.connect()
		async let second = client.connect()
		let (a, b) = try await (first, second)
		XCTAssertEqual(a, b)
		_ = try await client.send(.state)
		XCTAssertEqual(server.connectionCount, 1)
		await client.close()
	}

	func testATimedOutClientReportsATimeoutAndRecovers() async throws {
		let endpoint = try await server.start()
		let client = HeadlessClient(endpoint: endpoint, requestTimeout: .milliseconds(200))
		do {
			_ = try await client.send(.wait(condition: "count-at-least", arguments: ["value": 1], timeout: 0.5))
			XCTFail("the request outlived the client's timeout")
		} catch let error as HeadlessTransportError {
			XCTAssertEqual(error.kind, .timeout, "\(error)")
		}
		// The timed-out client closed its connection, which gave up the controller slot at once
		// (AIA-0992): the app is still finishing the abandoned wait, and the next request queues
		// behind it and may itself time out once. Each timeout closes again, so it is never `busy`.
		var recovered: Response?
		for _ in 0..<20 where recovered == nil {
			do {
				recovered = try await client.send(.state)
			} catch let error as HeadlessTransportError {
				XCTAssertEqual(error.kind, .timeout, "only a timeout is expected while the app catches up: \(error)")
			}
		}
		XCTAssertEqual(recovered?.route, "home")
		await client.close()
	}

	/// Strict wire types (AIA-0992): text for a typed parameter is refused on the wire, before the
	/// handler runs; converting `k=v` is the command line's job.
	func testAStringForATypedParameterIsRejectedOnTheWire() async throws {
		let endpoint = try await server.start()
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [
			#"{"hello":{"protocolVersion":1,"token":"\#(endpoint.token)"}}"#,
			#"{"id":"1","command":"perform","action":"increment","arguments":{"by":"2"}}"#,
			#"{"id":"2","command":"perform","action":"rename","arguments":{"name":"n","loud":"true"}}"#,
			#"{"id":"3","command":"perform","action":"increment","arguments":{"by":2}}"#
		], expectLines: 4)
		let decoder = HeadlessCoding.makeDecoder()
		let integer = try decoder.decode(Response.self, from: Data(lines[1].utf8))
		XCTAssertEqual(integer.error?.code, .invalidArgument, lines[1])
		let boolean = try decoder.decode(Response.self, from: Data(lines[2].utf8))
		XCTAssertEqual(boolean.error?.code, .invalidArgument, lines[2])
		let native = try decoder.decode(Response.self, from: Data(lines[3].utf8))
		XCTAssertTrue(native.ok, lines[3])
		XCTAssertEqual(app.count, 2, "only the natively typed request ran")
	}

	// MARK: - One controller (AIA-0992)

	func testASecondHelloIsBusyWhileAClientIsConnected() async throws {
		let endpoint = try await server.start()
		let first = HeadlessClient(endpoint: endpoint)
		try await first.connect()
		let second = HeadlessClient(endpoint: endpoint)
		do {
			try await second.connect()
			XCTFail("a second client connected while the first drives the app")
		} catch let error as HeadlessTransportError {
			XCTAssertEqual(error.kind, .handshakeRejected, "\(error)")
			XCTAssertTrue(error.message.hasPrefix("busy:"), error.message)
		}
		let answer = try await first.send(.perform(action: "increment", arguments: [:]))
		XCTAssertTrue(answer.ok, "the controller keeps working")
		XCTAssertEqual(app.count, 1)
		try await Self.eventually { self.server.connectionCount == 1 }
		await first.close()
	}

	func testTheBusyErrorLineIsOnTheWireAndTheConnectionCloses() async throws {
		let endpoint = try await server.start()
		let first = HeadlessClient(endpoint: endpoint)
		try await first.connect()
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [
			#"{"hello":{"protocolVersion":1,"token":"\#(endpoint.token)"}}"#,
			#"{"id":"1","command":"perform","action":"increment"}"#
		], expectLines: 1, readUntilClosed: true)
		XCTAssertEqual(lines.count, 1, "nothing after the refused hello is answered: \(lines)")
		let error = try HeadlessCoding.makeDecoder().decode(JSONValue.self, from: Data(lines[0].utf8))
		XCTAssertEqual(error.value(at: "/error/code"), "busy")
		XCTAssertEqual(app.count, 0)
		await first.close()
	}

	func testAWrongTokenIsUnauthorizedEvenWhileBusy() async throws {
		let endpoint = try await server.start()
		let first = HeadlessClient(endpoint: endpoint)
		try await first.connect()
		let intruder = HeadlessClient(endpoint: HeadlessEndpoint(port: endpoint.port, token: "wrong"))
		do {
			try await intruder.connect()
			XCTFail("connected with a wrong token")
		} catch let error as HeadlessTransportError {
			XCTAssertTrue(error.message.hasPrefix("unauthorized:"), "a peer without the token learns nothing: \(error.message)")
		}
		await first.close()
	}

	func testAConnectionWithoutAHelloDoesNotHoldTheSlot() async throws {
		let endpoint = try await server.start()
		let silent = try RawSocket.open(port: endpoint.port)
		defer { Darwin.close(silent) }
		try await Self.eventually { self.server.connectionCount == 1 }
		let client = HeadlessClient(endpoint: endpoint)
		try await client.connect()
		let answer = try await client.send(.state)
		XCTAssertTrue(answer.ok)
		await client.close()
	}

	func testClosingTheControllerFreesTheSlotAtOnce() async throws {
		let endpoint = try await server.start()
		// Closed and replaced with no delay, repeatedly: the worst case of `up` followed by `exec`.
		for round in 0..<20 {
			let client = HeadlessClient(endpoint: endpoint)
			do {
				try await client.connect()
			} catch {
				XCTFail("round \(round): the previous controller's close did not free the slot: \(error)")
			}
			await client.close()
		}
	}

	func testAControllerMidWaitHoldsTheSlotUntilItDisconnects() async throws {
		let endpoint = try await server.start()
		let waiter = HeadlessClient(endpoint: endpoint, requestTimeout: .seconds(5))
		try await waiter.connect()
		let wait = Task { try await waiter.send(.wait(condition: "count-at-least", arguments: ["value": 1], timeout: 0.3)) }
		let other = HeadlessClient(endpoint: endpoint)
		do {
			try await other.connect()
			XCTFail("connected while another client's wait is running on an open connection")
		} catch let error as HeadlessTransportError {
			XCTAssertTrue(error.message.hasPrefix("busy:"), error.message)
		}
		let answered = try await wait.value
		XCTAssertEqual(answered.error?.code, .timeout, "the wait itself answers on the open connection")
		do {
			try await other.connect()
			XCTFail("an open, idle controller still holds the slot")
		} catch let error as HeadlessTransportError {
			XCTAssertTrue(error.message.hasPrefix("busy:"), error.message)
		}
		await waiter.close()
		try await other.connect()
		await other.close()
	}

	func testAClientThatTimedOutAndDisconnectedFreesTheSlotPromptly() async throws {
		let endpoint = try await server.start()
		let impatient = HeadlessClient(endpoint: endpoint, requestTimeout: .milliseconds(100))
		let started = ContinuousClock.now
		do {
			_ = try await impatient.send(.wait(condition: "count-at-least", arguments: ["value": 1], timeout: 1))
			XCTFail("the request outlived the client's timeout")
		} catch let error as HeadlessTransportError {
			XCTAssertEqual(error.kind, .timeout, "\(error)")
		}
		// The timeout dropped the connection while the abandoned wait still runs in the app. The slot
		// is free as soon as the server sees the close, long before that wait ends: a drop sends no
		// goodbye to wait for, so the next hello may arrive a moment before the close is processed.
		let next = HeadlessClient(endpoint: endpoint, requestTimeout: .seconds(5))
		var connected = false
		while connected == false, ContinuousClock.now - started < .milliseconds(500) {
			do {
				try await next.connect()
				connected = true
			} catch let error as HeadlessTransportError where error.message.hasPrefix("busy:") {
				try await Task.sleep(for: .milliseconds(10))
			}
		}
		XCTAssertTrue(connected, "the slot was still held half-way through the abandoned wait")
		let answer = try await next.send(.state)
		XCTAssertTrue(answer.ok, "answered once the abandoned wait ends")
		await next.close()
	}

	/// Polls `condition` on the main actor for up to two seconds.
	private static func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
		for _ in 0..<200 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		XCTFail("condition never held", file: file, line: line)
	}

	func testTheEndpointFileIsPublishedPrivatelyAndRemovedOnStop() async throws {
		let file = directory.appendingPathComponent("endpoint.json")
		let endpoint = try await server.start()
		XCTAssertEqual(try HeadlessEndpoint.read(from: file), endpoint)
		let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
		XCTAssertEqual(permissions?.intValue, 0o600)
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		XCTAssertEqual(leftovers, ["endpoint.json"], "no staging file is left behind")
		server.stop()
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
	}

	func testAWrongTokenIsRejected() async throws {
		let endpoint = try await server.start()
		let client = HeadlessClient(endpoint: HeadlessEndpoint(port: endpoint.port, token: "wrong"))
		do {
			try await client.connect()
			XCTFail("connected with a wrong token")
		} catch let error as HeadlessTransportError {
			XCTAssertEqual(error.kind, .handshakeRejected)
			XCTAssertTrue(error.message.contains("unauthorized"), error.message)
		}
		XCTAssertEqual(app.count, 0)
	}

	func testConnectingToNothingSaysNotRunning() async throws {
		let endpoint = try await server.start()
		server.stop()
		let client = HeadlessClient(endpoint: endpoint)
		do {
			try await client.connect()
			XCTFail("connected to a stopped server")
		} catch let error as HeadlessTransportError {
			XCTAssertEqual(error.kind, .notRunning, "\(error)")
		}
	}

	// MARK: - The wire, independently of the client

	func testRawProtocol() async throws {
		let endpoint = try await server.start()
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [
			#"{"hello":{"protocolVersion":1,"token":"\#(endpoint.token)"}}"#,
			#"{"id":"7","command":"teleport"}"#,
			#"{"id":"8","command":"state"}"#,
			#"{"#
		], expectLines: 4)
		let decoder = HeadlessCoding.makeDecoder()
		XCTAssertNotNil(try decoder.decode(JSONValue.self, from: Data(lines[0].utf8)).value(at: "/hello/metadata"))
		let unknown = try decoder.decode(Response.self, from: Data(lines[1].utf8))
		XCTAssertEqual(unknown.id, "7", "the id is echoed")
		XCTAssertEqual(unknown.error?.code, .unknownCommand)
		let state = try decoder.decode(Response.self, from: Data(lines[2].utf8))
		XCTAssertEqual(state.id, "8")
		XCTAssertTrue(state.ok)
		let malformed = try decoder.decode(Response.self, from: Data(lines[3].utf8))
		XCTAssertEqual(malformed.error?.code, .malformedRequest)
	}

	func testAClientThatStopsSendingStillGetsItsAnswers() async throws {
		let endpoint = try await server.start()
		// `printf 'hello\nrequest\n' | nc` shape: everything, then end-of-stream at once.
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [
			#"{"hello":{"protocolVersion":1,"token":"\#(endpoint.token)"}}"#,
			#"{"id":"1","command":"perform","action":"increment-slowly"}"#,
			#"{"id":"2","command":"state"}"#
		], expectLines: 3, halfClose: true)
		let last = try HeadlessCoding.makeDecoder().decode(Response.self, from: Data(lines[2].utf8))
		XCTAssertEqual(last.id, "2")
		XCTAssertEqual(last.state, ["count": 1])
	}

	func testTheFirstLineMustBeAHelloWithTheRightVersion() async throws {
		let endpoint = try await server.start()
		let noHello = try await RawSocket.exchange(port: endpoint.port, send: [#"{"id":"1","command":"state"}"#], expectLines: 1)
		XCTAssertTrue(noHello[0].contains("malformedRequest"), noHello[0])
		let oldVersion = try await RawSocket.exchange(
			port: endpoint.port,
			send: [#"{"hello":{"protocolVersion":0,"token":"\#(endpoint.token)"}}"#],
			expectLines: 1
		)
		XCTAssertTrue(oldVersion[0].contains("protocolMismatch"), oldVersion[0])
	}

	func testNothingAfterARejectedHelloIsAnswered() async throws {
		let endpoint = try await server.start()
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [
			#"{"hello":{"protocolVersion":1,"token":"wrong"}}"#,
			#"{"id":"1","command":"perform","action":"increment"}"#,
			#"{"id":"2","command":"state"}"#
		], expectLines: 1, readUntilClosed: true)
		XCTAssertEqual(lines.count, 1, "\(lines)")
		XCTAssertTrue(lines[0].contains("unauthorized"), lines[0])
		XCTAssertEqual(app.count, 0)
	}

	func testASilentConnectionIsClosedAfterTheHandshakeTimeout() async throws {
		server.stop()
		server = makeServer(handshakeTimeout: .milliseconds(100))
		let endpoint = try await server.start()
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [], expectLines: 1, readUntilClosed: true)
		XCTAssertEqual(lines.count, 1, "\(lines)")
		XCTAssertTrue(lines[0].contains("unauthorized"), lines[0])
		XCTAssertEqual(server.connectionCount, 0)
	}

	// MARK: - Framing

	func testLineBufferSplitsAcrossChunksAndStripsCarriageReturns() throws {
		var buffer = LineBuffer()
		XCTAssertEqual(try buffer.append(Data("{\"a\"".utf8)), [])
		XCTAssertEqual(try buffer.append(Data(":1}\r\n\n{\"b\":2}\n{".utf8)), [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
	}

	func testLineBufferRefusesAnEndlessLine() {
		var buffer = LineBuffer()
		XCTAssertThrowsError(try buffer.append(Data(count: LineBuffer.maximumLineLength + 1)))
	}
}

/// A blocking BSD-socket client, independent of the code under test, for asserting the wire format.
private enum RawSocket {

	struct Failure: Error, CustomStringConvertible {
		let description: String
	}

	/// Opens a connection and returns its descriptor without sending anything; the caller closes it.
	static func open(port: UInt16) throws -> Int32 {
		let descriptor = socket(AF_INET, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw Failure(description: "socket failed") }
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = port.bigEndian
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard connected == 0 else {
			Darwin.close(descriptor)
			throw Failure(description: "connect failed")
		}
		return descriptor
	}

	/// Sends `lines`, then reads until `expectLines` lines arrived — or, with `readUntilClosed`,
	/// until the server closes the connection.
	static func exchange(
		port: UInt16,
		send lines: [String],
		expectLines count: Int,
		halfClose: Bool = false,
		readUntilClosed: Bool = false
	) async throws -> [String] {
		try await Task.detached {
			let descriptor = socket(AF_INET, SOCK_STREAM, 0)
			guard descriptor >= 0 else { throw Failure(description: "socket failed") }
			defer { close(descriptor) }
			var timeout = timeval(tv_sec: 5, tv_usec: 0)
			setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
			var address = sockaddr_in()
			address.sin_family = sa_family_t(AF_INET)
			address.sin_port = port.bigEndian
			address.sin_addr.s_addr = inet_addr("127.0.0.1")
			let connected = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
				}
			}
			guard connected == 0 else { throw Failure(description: "connect failed") }
			if lines.isEmpty == false {
				let payload = Array((lines.joined(separator: "\n") + "\n").utf8)
				guard write(descriptor, payload, payload.count) == payload.count else { throw Failure(description: "write failed") }
			}
			if halfClose {
				shutdown(descriptor, SHUT_WR)
			}
			var received = Data()
			var chunk = [UInt8](repeating: 0, count: 4096)
			while readUntilClosed || received.filter({ $0 == 0x0A }).count < count {
				let read = recv(descriptor, &chunk, chunk.count, 0)
				guard read > 0 else { break }
				received.append(contentsOf: chunk[0..<read])
			}
			let text = String(bytes: received, encoding: .utf8) ?? ""
			let result = text.split(separator: "\n").map(String.init)
			guard result.count >= count else { throw Failure(description: "expected \(count) lines, got: \(text)") }
			return result
		}.value
	}
}
#endif
