//
//  HeadlessDriving.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// Something that sends commands to one running app and returns its responses — a socket client
/// for an app in a simulator, or an in-process driver in a test.
public protocol HeadlessDriving: AnyObject, Sendable {
	/// Sends one command. Throws only when the app could not be reached; a command the app rejects
	/// comes back as a `Response` whose `error` is set.
	func send(_ command: Command) async throws -> Response
}

/// Drives a session in the same process — for testing adapters and scenarios without a transport.
@MainActor
public final class InProcessDriver: HeadlessDriving {

	public let session: HeadlessSession
	private var nextID = 0

	public init(session: HeadlessSession) {
		self.session = session
	}

	public func send(_ command: Command) async throws -> Response {
		nextID += 1
		return await session.handle(Request(id: String(nextID), command: command))
	}
}
