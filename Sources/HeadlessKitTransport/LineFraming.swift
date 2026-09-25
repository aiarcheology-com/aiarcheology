//
//  LineFraming.swift
//  HeadlessKitTransport
//
//  AIA-0970.
//

import Foundation
import HeadlessKit

/// JSON Lines framing: one JSON document per `\n`-terminated line.
struct LineBuffer {

	/// Longer than any legitimate request or response line. A peer that sends more without a
	/// newline is broken or hostile, and buffering it without bound would let it exhaust memory.
	static let maximumLineLength = 4 * 1024 * 1024

	struct LineTooLong: Error {}

	private var pending = Data()

	/// Appends received bytes and returns every complete, non-empty line without its terminator.
	mutating func append(_ bytes: Data) throws -> [Data] {
		pending.append(bytes)
		var lines: [Data] = []
		while let newline = pending.firstIndex(of: 0x0A) {
			var line = Data(pending[pending.startIndex..<newline])
			if line.last == 0x0D { line.removeLast() }
			if line.isEmpty == false { lines.append(line) }
			pending.removeSubrange(pending.startIndex...newline)
		}
		guard pending.count <= Self.maximumLineLength else { throw LineTooLong() }
		return lines
	}

	/// `value` encoded as one line.
	static func line<T: Encodable>(_ value: T) throws -> Data {
		var data = try HeadlessCoding.makeEncoder().encode(value)
		data.append(0x0A)
		return data
	}
}

/// The lines that surround requests and responses: `{"hello": …}` both ways, `{"error": …}` from
/// the server when a handshake fails.
enum Envelope {

	struct ClientHelloLine: Codable {
		let hello: ClientHello
	}

	struct ServerHelloLine: Codable {
		let hello: ServerHello
	}

	struct ErrorLine: Codable {
		let error: HeadlessError
	}
}

/// Where a running app listens, as it publishes it for clients.
public struct HeadlessEndpoint: Codable, Hashable, Sendable {

	public let host: String
	public let port: UInt16
	/// A shared secret for this launch. Loopback is reachable by every process on the machine —
	/// and every simulator on it — so the port alone must not be enough to drive the app.
	public let token: String

	public init(host: String = "127.0.0.1", port: UInt16, token: String) {
		self.host = host
		self.port = port
		self.token = token
	}

	/// Reads an endpoint file written by `HeadlessServer`.
	public static func read(from url: URL) throws -> HeadlessEndpoint {
		try HeadlessCoding.makeDecoder().decode(HeadlessEndpoint.self, from: Data(contentsOf: url))
	}
}

/// A failure of the connection itself, as opposed to an error response from the app.
public struct HeadlessTransportError: Error, Hashable, Sendable, CustomStringConvertible {

	public enum Kind: String, Hashable, Sendable {
		/// Nothing listens there: the app is not running, or was suspended.
		case notRunning
		case connectionFailed
		case handshakeRejected
		case malformedMessage
		case timeout
		case closed
	}

	public let kind: Kind
	public let message: String

	public init(_ kind: Kind, _ message: String) {
		self.kind = kind
		self.message = message
	}

	public var description: String { "\(kind.rawValue): \(message)" }
}
