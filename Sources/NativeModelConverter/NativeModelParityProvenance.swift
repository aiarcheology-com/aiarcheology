//
//  NativeModelParityProvenance.swift
//  NativeModelConverter
//
//  What backs a converted model's numerics: a parity check, or only a successful conversion.
//

import Foundation

/// What an emission is entitled to claim about its numerics.
///
/// The two states are not interchangeable and must never be presented as one. A converter that
/// validated a graph, lowered every operation and serialized the model successfully has proved the
/// *structure* travelled intact — it never compiled or loaded what it wrote, and it has not compared
/// a single number against the source model. Only a run
/// against a reference oracle does that. Collapsing the two would let a model that has never been
/// numerically checked be displayed as "parity verified".
///
/// `Codable` because the raw values are also the wire form written into the model's metadata, so the
/// string a consumer reads and the case this converter writes have exactly one definition.
public enum NativeModelParityEvidence: String, Codable, Sendable {
	/// The emitted model's outputs were compared against a reference oracle — the M3a parity harness
	/// or a committed parity fixture — and agreed within that check's tolerance.
	case verified
	/// The graph converted and validated, and nothing further. This is a statement about the
	/// conversion, not about the numbers it produces.
	case structurallyMatched = "structurally-matched"

	/// What an emission claims when its caller supplied no evidence, defined once so every default
	/// resolves to the same answer. It is the conservative one deliberately: a caller who ran no
	/// parity check must not be able to ship a model asserting one by saying nothing.
	public static let unevidenced = NativeModelParityEvidence.structurallyMatched
}

/// The parity fact recorded in the converted model's `creatorDefined` metadata.
///
/// Serialized as canonical JSON under one key, for the same reason the artifact manifest is: the
/// fact then travels inside the model a runtime has already loaded, needing no second lookup and no
/// file that can be separated from what it describes.
///
/// Deliberately carries the claim and nothing else — no oracle name, no error bound, no date. Those
/// describe the run that made the claim, and a run's details baked into a shipped model age into a
/// lie exactly as a benchmark number would; which of the two claims an emission is entitled to make
/// does not age.
struct NativeModelParityProvenance: Codable, Equatable {
	static let formatIdentifier = "com.aiarcheology.native-model-parity"
	static let currentFormatVersion = 1
	/// The `creatorDefined` key the fact is stored under, on the *outer* model description — the only
	/// description `MLModelDescription` publishes for a pipeline.
	static let userDefinedKey = "com.aiarcheology.native.target.parity-provenance.json"

	let format: String
	let formatVersion: Int
	let evidence: NativeModelParityEvidence

	init(evidence: NativeModelParityEvidence) {
		format = Self.formatIdentifier
		formatVersion = Self.currentFormatVersion
		self.evidence = evidence
	}

	/// The canonical JSON written into the model metadata. Sorted keys keep the emitted bytes
	/// deterministic, matching how the target interface and the artifact manifest are serialized.
	func canonicalJSON() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let encoded = try encoder.encode(self)
		guard let json = String(bytes: encoded, encoding: .utf8) else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: "parityProvenance",
				reason: "The JSON encoder produced non-UTF-8 data."
			)
		}
		return json
	}
}
