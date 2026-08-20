//
//  NativeModelEmittedArtifacts.swift
//  NativeModelConverter
//
//  The standalone companion models an emission may write beside the primary `.mlmodel`.
//

import Foundation

/// A Faster R-CNN ROI box head compiled for a fixed proposal batch, emitted as its own `.mlmodel`.
///
/// The chunk is deliberately *not* a Core ML pipeline stage of the primary model. Pipeline stages
/// are embedded in the outer model and run sequentially inside a single `prediction` call, so
/// carrying the batched copies there would only reproduce the in-graph chunking AIA-0670 measured
/// as saving nothing. A standalone model is what lets the runtime drive the loop itself, invoking
/// the chunk ``invocationCount`` times.
public struct NativeModelROIBoxHeadChunkEmission: Sendable {
	/// The chunk network: a plain neural network taking one fixed batch of proposals and returning
	/// compact boxes and scores. It is never emitted through the detector overload, which would wrap
	/// it in the network + non-maximum-suppression pipeline it is not.
	public let graph: NativeModelGraph
	/// The weight blob `graph` indexes into.
	public let weights: Data
	/// How many proposals one invocation of the chunk processes.
	public let fixedBatchSize: Int
	/// How many proposals the primary model's first stage produces in total.
	public let proposalCount: Int

	public init(graph: NativeModelGraph, weights: Data, fixedBatchSize: Int, proposalCount: Int) {
		self.graph = graph
		self.weights = weights
		self.fixedBatchSize = fixedBatchSize
		self.proposalCount = proposalCount
	}

	/// How many invocations cover every proposal, derived rather than stored so a manifest can never
	/// record a loop count the batch size does not produce. Valid only for a positive
	/// ``fixedBatchSize``, which the emitter checks before reading this.
	///
	/// Rounded up through the remainder rather than by the usual `+ fixedBatchSize - 1` numerator: that
	/// addition overflows — and traps, taking the process with it — for perfectly legal inputs near
	/// `Int.max`, which is not a failure mode a conversion may have.
	var invocationCount: Int {
		let (fullBatches, remainder) = proposalCount.quotientAndRemainder(dividingBy: fixedBatchSize)
		return remainder == 0 ? fullBatches : fullBatches + 1
	}
}

/// One file an emission wrote, with the digest that binds it to the set it belongs to.
public struct NativeModelEmittedArtifact: Sendable {
	/// What a file is to the runtime that loads it. `Codable` because the raw value is also the
	/// manifest's wire form, so encoding and decoding go through this one definition.
	public enum Role: String, Codable, Sendable {
		case primary
		/// Spelled out because this raw value is the wire form written into the manifest: it names an
		/// architecture-specific companion, not the generic idea of a chunk.
		case roiBoxHeadChunk = "fasterRCNN.roiBoxHeadChunk"
	}

	public let role: Role
	public let url: URL
	public let byteCount: UInt64
	/// The SHA-256 of the written file's bytes, lowercase hex.
	public let sha256: String

	public init(role: Role, url: URL, byteCount: UInt64, sha256: String) {
		self.role = role
		self.url = url
		self.byteCount = byteCount
		self.sha256 = sha256
	}
}

/// Every file one emission produced. The primary is the discovery anchor: it carries the manifest
/// naming the companions, so it is always written last.
public struct NativeModelEmissionArtifactSet: Sendable {
	public let primary: NativeModelEmittedArtifact
	public let companions: [NativeModelEmittedArtifact]

	public init(primary: NativeModelEmittedArtifact, companions: [NativeModelEmittedArtifact]) {
		self.primary = primary
		self.companions = companions
	}
}

/// The runtime manifest naming the companion files a primary model cannot run without.
///
/// It is serialized into the primary model's Core ML `creatorDefined` metadata rather than into a
/// file of its own: `<model-name>.metadata.json` is reserved for the byte-for-byte source metadata
/// (see ``NativeModelMetadataSidecar``) and `.aiagraph/manifest.json` is an input-integrity manifest
/// over a fixed allowed-file set. Living in the model's metadata also means the runtime finds it
/// through `MLModelDescription` with the model it already loaded, needing no second lookup.
///
/// Deliberately carries no performance numbers. Batch size and invocation count are interface facts
/// the runtime must obey; how fast a chunk ran on some device is a measurement, and a measurement
/// baked into a shipped model would age into a lie.
struct NativeModelArtifactManifest: Codable, Equatable {
	static let formatIdentifier = "com.aiarcheology.native-model-artifacts"
	static let currentFormatVersion = 1
	/// The `creatorDefined` key the manifest is stored under, on the primary model's *outer* model
	/// description. On a pipeline's embedded stage it would be invisible to `MLModelDescription`.
	static let userDefinedKey = "com.aiarcheology.native.target.artifact-manifest.json"

	struct Companion: Codable, Equatable {
		let role: NativeModelEmittedArtifact.Role
		/// A plain basename resolved beside the primary model — never a path.
		let filename: String
		/// The SHA-256 of the companion file. Without it an old companion left beside a new primary
		/// compiles and predicts happily, with silently mismatched shapes.
		let sha256: String
		let fixedBatchSize: Int
		let proposalCount: Int
		let invocationCount: Int
	}

	let format: String
	let formatVersion: Int
	let companions: [Companion]

	init(companions: [Companion]) {
		format = Self.formatIdentifier
		formatVersion = Self.currentFormatVersion
		self.companions = companions
	}

	/// The canonical JSON written into the model metadata. Sorted keys keep the emitted bytes
	/// deterministic, matching how the target interface is serialized.
	func canonicalJSON() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let encoded = try encoder.encode(self)
		guard let json = String(bytes: encoded, encoding: .utf8) else {
			throw NativeModelCoreMLEmissionError.invalidArtifactSet(
				reason: "the JSON encoder produced non-UTF-8 manifest data"
			)
		}
		return json
	}
}
