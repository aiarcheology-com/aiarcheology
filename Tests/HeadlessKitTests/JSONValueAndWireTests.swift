//
//  JSONValueAndWireTests.swift
//  HeadlessKitTests
//
//  AIA-0970.
//

import Foundation
import XCTest
@testable import HeadlessKit

final class JSONValueAndWireTests: XCTestCase {

	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try HeadlessCoding.makeDecoder().decode(type, from: Data(json.utf8))
	}

	private func encode<T: Encodable>(_ value: T) throws -> String {
		try XCTUnwrap(String(bytes: HeadlessCoding.makeEncoder().encode(value), encoding: .utf8))
	}

	// MARK: - JSONValue

	func testDecodingKeepsBooleansAndNumbersApart() throws {
		let value = try decode(JSONValue.self, #"[true, 1, 1.5, "s", null, {"a": []}]"#)
		XCTAssertEqual(value, [true, 1, 1.5, "s", .null, ["a": []]])
	}

	func testIntegralNumbersEncodeAsIntegers() throws {
		XCTAssertEqual(try encode(JSONValue.number(3)), "3")
		XCTAssertEqual(try encode(JSONValue.number(1.5)), "1.5")
		XCTAssertEqual(try encode(JSONValue.number(-0.0)), "0")
	}

	func testEncodingSortsKeys() throws {
		XCTAssertEqual(try encode(["b": 1, "a": 2] as JSONValue), #"{"a":2,"b":1}"#)
	}

	func testPointerAddressesObjectsAndArrays() {
		let document: JSONValue = ["models": [["id": "x", "enabled": true]], "a/b": 1, "m~n": 2]
		XCTAssertEqual(document.value(at: "/models/0/id"), "x")
		XCTAssertEqual(document.value(at: "/models/0/enabled"), true)
		XCTAssertEqual(document.value(at: ""), document)
		XCTAssertEqual(document.value(at: "/a~1b"), 1)
		XCTAssertEqual(document.value(at: "/m~0n"), 2)
	}

	func testPointerMissesRatherThanGuesses() {
		let document: JSONValue = ["list": ["a", "b"], "scalar": 1]
		XCTAssertNil(document.value(at: "/list/2"))
		XCTAssertNil(document.value(at: "/list/01"), "a non-canonical index must not match")
		XCTAssertNil(document.value(at: "/list/-1"))
		XCTAssertNil(document.value(at: "/scalar/x"))
		XCTAssertNil(document.value(at: "/missing"))
		XCTAssertNil(document.value(at: "list"), "a pointer must start with /")
	}

	// MARK: - Requests

	func testRequestsAreFlatAndRoundTrip() throws {
		let requests = [
			Request(id: "1", command: .help),
			Request(id: "2", command: .state),
			Request(id: "3", command: .actions),
			Request(id: "4", command: .perform(action: "enable", arguments: ["id": "x"])),
			Request(id: "5", command: .goto("drawer")),
			Request(id: "6", command: .wait(condition: "loaded", arguments: ["id": "x"], timeout: 2.5))
		]
		for request in requests {
			XCTAssertEqual(try decode(Request.self, try encode(request)), request)
		}
		XCTAssertEqual(
			try encode(requests[3]),
			#"{"action":"enable","arguments":{"id":"x"},"command":"perform","id":"4"}"#
		)
		XCTAssertEqual(try encode(requests[4]), #"{"command":"goto","id":"5","route":"drawer"}"#)
	}

	func testAnUnknownCommandIsReportedAsSuch() {
		XCTAssertThrowsError(try decode(Request.self, #"{"id":"1","command":"teleport"}"#)) { error in
			XCTAssertEqual((error as? HeadlessError)?.code, .unknownCommand)
		}
		XCTAssertThrowsError(try decode(Request.self, #"{"id":"1","command":"perform"}"#), "perform needs an action") { error in
			XCTAssertTrue(error is DecodingError)
		}
	}

	func testAResponseWhoseOkContradictsItsErrorIsMalformed() {
		let base = #""id":"1","route":"home","state":{},"actions":[],"context":{}"#
		XCTAssertThrowsError(try decode(Response.self, "{\(base),\"ok\":true,\"error\":{\"code\":\"timeout\",\"message\":\"m\"}}"))
		XCTAssertThrowsError(try decode(Response.self, "{\(base),\"ok\":false}"))
		XCTAssertNoThrow(try decode(Response.self, "{\(base),\"ok\":true}"))
	}

	// MARK: - Responses

	func testResponseDocumentMatchesTheWire() throws {
		let response = Response(
			id: "9",
			route: "home",
			state: ["count": 2],
			actions: [ActionSpec(name: "open-drawer", summary: "Open.", navigatesTo: "drawer")],
			context: ["env": "development"],
			error: HeadlessError(.unreachable, "no")
		)
		let document = response.document
		XCTAssertEqual(document.value(at: "/ok"), false)
		XCTAssertEqual(document.value(at: "/state/count"), 2)
		XCTAssertEqual(document.value(at: "/actions/0/navigatesTo"), "drawer")
		XCTAssertEqual(document.value(at: "/error/code"), "unreachable")
		XCTAssertNil(document.value(at: "/result"), "an absent result is absent, not null")
		XCTAssertEqual(try decode(Response.self, try encode(response)), response)
	}

	func testUnknownErrorCodesStillDecode() throws {
		let error = try decode(HeadlessError.self, #"{"code":"fromTheFuture","message":"m"}"#)
		XCTAssertEqual(error.code.rawValue, "fromTheFuture")
	}

	// MARK: - Arguments

	func testArgumentsConvertTextualForms() throws {
		let parameters = [
			ParameterSpec("count", .integer),
			ParameterSpec("flag", .boolean),
			ParameterSpec("ratio", .number),
			ParameterSpec("name", .string)
		]
		let arguments = try Arguments.validated(
			["count": "3", "flag": "TRUE", "ratio": "0.5", "name": 7],
			against: parameters,
			subject: "test"
		)
		XCTAssertEqual(try arguments.integer("count"), 3)
		XCTAssertEqual(try arguments.boolean("flag"), true)
		XCTAssertEqual(try arguments.number("ratio"), 0.5)
		XCTAssertEqual(try arguments.string("name"), "7")
	}

	func testArgumentsRejectWhatTheyCannotConvert() {
		let parameters = [ParameterSpec("count", .integer), ParameterSpec("flag", .boolean, required: false)]
		for raw: [String: JSONValue] in [["count": "3.5"], ["count": 1.5], ["count": 1, "flag": "yes"], ["count": "nan"]] {
			XCTAssertThrowsError(try Arguments.validated(raw, against: parameters, subject: "test"), "\(raw)") { error in
				XCTAssertEqual((error as? HeadlessError)?.code, .invalidArgument)
			}
		}
	}
}
