//
//  ONNXMetadataMapping.swift
//  NativeModelConverter
//
//  Maps the free-form attribution fields of an ONNX ModelProto into the converter's typed source
//  metadata (AIA-0473), so a converted Core ML model carries the original model's
//  description/author/version/license and mirrors the rest of `metadata_props` as provenance.
//
//  `metadata_props` is an untrusted `[key, value]` string bag written by whoever exported the
//  model. Everything here is DISPLAY-ONLY: it never influences conversion behaviour, and every
//  value is length- and count-bounded before it is carried into Core ML metadata (and, via the
//  app, onto a screen).
//

import Foundation

/// The raw attribution bytes pulled out of a ModelProto, before any interpretation.
struct ONNXRawMetadata: Equatable {
	/// `metadata_props` (field 14) in file order. Not a dictionary: ONNX does not require unique keys.
	var props: [(key: String, value: String)]
	/// `doc_string` (field 6).
	var docString: String?
	/// `producer_name` (field 2).
	var producerName: String?
	/// `model_version` (field 5), an int64 that defaults to 0 when unset.
	var modelVersion: UInt64?

	init(
		props: [(key: String, value: String)] = [],
		docString: String? = nil,
		producerName: String? = nil,
		modelVersion: UInt64? = nil
	) {
		self.props = props
		self.docString = docString
		self.producerName = producerName
		self.modelVersion = modelVersion
	}

	static func == (lhs: ONNXRawMetadata, rhs: ONNXRawMetadata) -> Bool {
		lhs.docString == rhs.docString
			&& lhs.producerName == rhs.producerName
			&& lhs.modelVersion == rhs.modelVersion
			&& lhs.props.count == rhs.props.count
			&& zip(lhs.props, rhs.props).allSatisfy { $0.key == $1.key && $0.value == $1.value }
	}
}

enum ONNXMetadataMapping {

	/// A generous ceiling on a single metadata value. Real attribution fields (a license line, a
	/// class-name map) are well under this; the cap exists only so a hostile or corrupt file cannot
	/// pump megabytes of text into the model's metadata.
	static let maximumValueByteCount = 4096
	/// A key is an identifier, so it needs far less room than a value.
	static let maximumKeyByteCount = 256
	/// A generous ceiling on how many `metadata_props` pairs are mirrored. Genuine exports carry a
	/// dozen or so; capping bounds a file that lists thousands of junk keys.
	static let maximumMirroredPairCount = 64
	/// A ceiling on the total mirrored payload, independent of the per-value and count caps, so many
	/// near-limit values cannot still add up to an unreasonable metadata block.
	static let maximumAggregateByteCount = 64 * 1024

	/// Builds typed source metadata from the raw ONNX attribution fields, or `nil` when the model
	/// carries nothing worth recording (so a metadata-free model keeps its existing filename
	/// fallback rather than acquiring an empty metadata block).
	static func metadata(from raw: ONNXRawMetadata) -> NativeModelCoreMLMetadata? {
		// Present ONNX does not require unique metadata_props keys; keep the last occurrence, matching
		// how a consumer reading the map would see it. Empty keys and values are dropped as absent —
		// `firstString` returns "" for a present-but-empty protobuf string, and an empty
		// `description` must not beat the `doc_string` fallback below.
		var props: [String: String] = [:]
		for (rawKey, rawValue) in raw.props {
			// Keys must be exact: trimming a key would canonicalize " author " onto "author", letting a
			// whitespace-decorated later entry override the genuine one. A non-canonical key is not
			// something a real exporter writes — drop the pair instead of normalizing it.
			guard rawKey == rawKey.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
			let key = rawKey
			let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !key.isEmpty, !value.isEmpty else { continue }
			// Drop only the offending pair, never the whole map — a hostile oversized value must not
			// be able to suppress a legitimate description/author/license elsewhere in the file.
			guard key.utf8.count <= maximumKeyByteCount, value.utf8.count <= maximumValueByteCount else { continue }
			props[key] = value  // last occurrence wins; ONNX does not require unique keys
		}

		func prop(_ name: String) -> String? {
			guard let value = props[name], !value.isEmpty else { return nil }
			return value
		}

		// doc_string is untrusted input like every other field — it must pass the same size cap, or
		// an oversized doc_string would bypass the bound the metadata_props values obey.
		let docString = raw.docString?.trimmingCharacters(in: .whitespacesAndNewlines)
		let boundedDocString = docString.flatMap { $0.isEmpty || $0.utf8.count > maximumValueByteCount ? nil : $0 }
		let description = prop("description") ?? boundedDocString
		let author = prop("author")
		let license = prop("license")
		// model_version is a protobuf int64: it defaults to 0 when unset, and a (pathological)
		// negative value arrives as a huge two's-complement varint. Neither is a real version —
		// reinterpret signed and accept only values > 0, and only when metadata_props carries no
		// explicit version string.
		let signedModelVersion = raw.modelVersion.map { Int64(bitPattern: $0) }
		let versionFromModelVersion = signedModelVersion.flatMap { $0 > 0 ? String($0) : nil }
		let version = prop("version") ?? versionFromModelVersion

		// Mirror every surviving pair as provenance, bounded, in a stable (sorted) order so the output
		// is deterministic regardless of the file's field order. This is what preserves the keys the
		// typed fields don't capture — docs, date, stride, imgsz, channels, Image.BitmapPixelFormat, …
		var userDefined: [String: String] = [:]
		var aggregateByteCount = 0
		for (key, value) in props.sorted(by: { $0.key < $1.key }) {
			guard userDefined.count < maximumMirroredPairCount else { break }
			let pairBytes = key.utf8.count + value.utf8.count
			guard aggregateByteCount + pairBytes <= maximumAggregateByteCount else { continue }
			userDefined[key] = value
			aggregateByteCount += pairBytes
		}

		// Nothing worth recording → nil, so a bare model is unchanged.
		guard description != nil || author != nil || license != nil || version != nil || !userDefined.isEmpty else {
			return nil
		}

		return NativeModelCoreMLMetadata(
			shortDescription: description,
			versionString: version,
			author: author,
			license: license,
			userDefined: userDefined
		)
	}
}
