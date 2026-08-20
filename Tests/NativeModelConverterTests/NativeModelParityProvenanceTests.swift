//
//  NativeModelParityProvenanceTests.swift
//  NativeModelConverterTests
//

import CoreML
import XCTest
@testable import NativeModelConverter

final class NativeModelParityProvenanceTests: XCTestCase {

	/// The emitter is never told anything about parity here — exactly the position every current
	/// conversion path is in — so the model must come back claiming only that it converted.
	func testEmission_statingNoEvidence_claimsOnlyAStructuralMatch() throws {
		let json = try emittedProvenanceJSON()
		let provenance = try JSONDecoder().decode(NativeModelParityProvenance.self, from: Data(json.utf8))
		XCTAssertEqual(provenance.evidence, .structurallyMatched)
		XCTAssertEqual(provenance.format, "com.aiarcheology.native-model-parity")
		XCTAssertEqual(provenance.formatVersion, 1)
	}

	/// The two claims must be distinguishable by a consumer reading the compiled model's metadata,
	/// and distinguishable as *text*: an app that showed both as "parity verified" would be making
	/// the claim the unverified model never earned.
	func testEmission_withAndWithoutAReferenceCheck_readBackAsDifferentClaims() throws {
		let verified = try emittedProvenanceJSON(parityEvidence: .verified)
		let unevidenced = try emittedProvenanceJSON()

		XCTAssertNotEqual(verified, unevidenced)
		XCTAssertTrue(verified.contains("\"evidence\":\"verified\""), "was: \(verified)")
		XCTAssertTrue(unevidenced.contains("\"evidence\":\"structurally-matched\""), "was: \(unevidenced)")
	}

	/// The default is a single definition, and it is the conservative one. Pointing it at `.verified`
	/// would let every path that says nothing about parity ship a model asserting a check nobody ran.
	func testUnevidencedClaim_isTheConservativeOne() {
		XCTAssertEqual(NativeModelParityEvidence.unevidenced, .structurallyMatched)
		XCTAssertNotEqual(NativeModelParityEvidence.unevidenced, .verified)
	}

	/// These strings leave the converter and are read by something else, so they are part of the
	/// contract and not an implementation detail of the Swift case names. Renaming a case without
	/// keeping its raw value must fail here rather than silently changing what a consumer sees.
	func testWireStrings_arePinned() throws {
		XCTAssertEqual(NativeModelParityEvidence.verified.rawValue, "verified")
		XCTAssertEqual(NativeModelParityEvidence.structurallyMatched.rawValue, "structurally-matched")
		XCTAssertEqual(NativeModelParityEvidence(rawValue: "verified"), .verified)
		XCTAssertEqual(NativeModelParityEvidence(rawValue: "structurally-matched"), .structurallyMatched)
		XCTAssertNil(
			NativeModelParityEvidence(rawValue: "structurallyMatched"),
			"the case name is not the wire form; only the recorded raw value is"
		)
		XCTAssertEqual(
			NativeModelParityProvenance.userDefinedKey,
			"com.aiarcheology.native.target.parity-provenance.json"
		)
		// One literal pinning the whole wire form: the key names, the values, and the sorted-key order
		// that keeps two emissions of the same claim byte-identical.
		XCTAssertEqual(
			try NativeModelParityProvenance(evidence: .verified).canonicalJSON(),
			#"{"evidence":"verified","format":"com.aiarcheology.native-model-parity","formatVersion":1}"#
		)
	}

	// MARK: - Helpers

	/// Emits a minimal conversion and returns the parity JSON the way a consumer gets it: off the
	/// compiled model's description. Passing no evidence exercises the real default, which is the
	/// behaviour under test — supplying `.unevidenced` explicitly would prove nothing about it.
	private func emittedProvenanceJSON(parityEvidence: NativeModelParityEvidence? = nil) throws -> String {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		let modelURL = directory.appendingPathComponent("converted.mlmodel")

		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 3, 2, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "activation",
					kind: .relu,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 3, 2, 2])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
		if let parityEvidence {
			try NativeModelCoreMLEmitter().emit(
				graph: graph, weights: Data(), to: modelURL,
				classifierLabels: nil, imagePreprocessing: nil, parityEvidence: parityEvidence
			)
		} else {
			try NativeModelCoreMLEmitter().emit(
				graph: graph, weights: Data(), to: modelURL,
				classifierLabels: nil, imagePreprocessing: nil
			)
		}

		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		let model = try MLModel(contentsOf: try MLModel.compileModel(at: modelURL), configuration: configuration)
		let userDefined = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
		return try XCTUnwrap(userDefined[NativeModelParityProvenance.userDefinedKey])
	}
}
