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
		server = HeadlessServer(
			session: HeadlessSession(application: app, pollInterval: .milliseconds(5)),
			endpointFile: directory.appendingPathComponent("endpoint.json")
		)
	}

	override func tearDown() async throws {
		server.stop()
		try? FileManager.default.removeItem(at: directory) // Best-effort cleanup of a temp directory.
		server = nil
		app = nil
	}

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
		XCTAssertEqual(refused.error?.code, .unreachable, "an app-level error is a response, not a thrown error")
		await client.close()
		XCTAssertEqual(app.count, 2)
	}

	func testTheEndpointFileIsPublishedPrivatelyAndRemovedOnStop() async throws {
		let file = directory.appendingPathComponent("endpoint.json")
		let endpoint = try await server.start()
		XCTAssertEqual(try HeadlessEndpoint.read(from: file), endpoint)
		let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
		XCTAssertEqual(permissions?.intValue, 0o600)
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

	func testRawProtocol() async throws {
		let endpoint = try await server.start()
		let lines = try await RawSocket.exchange(port: endpoint.port, send: [
			#"{"hello":{"protocolVersion":1,"token":"\#(endpoint.token)"}}"#,
			#"{"id":"7","command":"teleport"}"#,
			#"{"id":"8","command":"state"}"#
		], expectLines: 3)
		let decoder = HeadlessCoding.makeDecoder()
		XCTAssertNotNil(try? decoder.decode(JSONValue.self, from: Data(lines[0].utf8)).value(at: "/hello/metadata"))
		let malformed = try decoder.decode(Response.self, from: Data(lines[1].utf8))
		XCTAssertEqual(malformed.id, "7", "the id is echoed even when the request is unreadable")
		XCTAssertEqual(malformed.error?.code, .malformedRequest)
		let state = try decoder.decode(Response.self, from: Data(lines[2].utf8))
		XCTAssertEqual(state.id, "8")
		XCTAssertTrue(state.ok)
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

	static func exchange(port: UInt16, send lines: [String], expectLines count: Int) async throws -> [String] {
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
			let payload = Array((lines.joined(separator: "\n") + "\n").utf8)
			guard write(descriptor, payload, payload.count) == payload.count else { throw Failure(description: "write failed") }
			var received = Data()
			var chunk = [UInt8](repeating: 0, count: 4096)
			while received.filter({ $0 == 0x0A }).count < count {
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
