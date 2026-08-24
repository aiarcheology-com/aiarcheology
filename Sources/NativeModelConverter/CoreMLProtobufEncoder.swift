//
//  CoreMLProtobufEncoder.swift
//  NativeModelConverter
//
//  Minimal, dependency-free protobuf writer for the Core ML neural-network model subset.
//

import Foundation

/// A length-delimited protobuf payload whose bytes are produced only when an output writer reaches
/// it. The count pass uses `byteCount` without asking the source for any bytes.
struct CoreMLProtobufDeferredPayload {
	let byteCount: UInt64
	/// Invoked with the byte offset at which this payload will be written to the output file.
	/// Streaming ADAF emission uses this to index the already-emitted weights for a metadata digest
	/// without reopening and widening the extracted fp16 source a second time.
	let willWriteAt: ((UInt64) -> Void)?
	let write: (FileHandle) throws -> Void

	init(
		byteCount: UInt64,
		willWriteAt: ((UInt64) -> Void)? = nil,
		write: @escaping (FileHandle) throws -> Void
	) {
		self.byteCount = byteCount
		self.willWriteAt = willWriteAt
		self.write = write
	}
}

/// One recursive protobuf representation shared by the ADAF count and file-writing passes.
///
/// Static protobuf fields remain small `Data` fragments. Large weight fields stay deferred until
/// the file writer reaches them, so enclosing message lengths can be precomputed without building
/// a second model-sized buffer.
struct CoreMLProtobufSegments {
	private enum Segment {
		case data(Data)
		case deferred(CoreMLProtobufDeferredPayload)
		case progress(NativeModelConversionProgress)
	}

	private var segments: [Segment] = []
	private(set) var byteCount: UInt64 = 0

	mutating func append(data: Data) {
		guard !data.isEmpty else { return }
		segments.append(.data(data))
		byteCount += UInt64(data.count)
	}

	mutating func append(deferred: CoreMLProtobufDeferredPayload) {
		segments.append(.deferred(deferred))
		byteCount += deferred.byteCount
	}

	mutating func append(progress: NativeModelConversionProgress) {
		segments.append(.progress(progress))
	}

	mutating func append(contentsOf other: CoreMLProtobufSegments) {
		segments.append(contentsOf: other.segments)
		byteCount += other.byteCount
	}

	func write(
		to handle: FileHandle,
		reporting progress: NativeModelConversionProgressHandler?
	) throws {
		var fileOffset = try handle.offset()
		for segment in segments {
			switch segment {
			case .data(let data):
				try handle.write(contentsOf: data)
				fileOffset += UInt64(data.count)
			case .deferred(let payload):
				payload.willWriteAt?(fileOffset)
				try payload.write(handle)
				fileOffset += payload.byteCount
			case .progress(let update):
				progress?(update)
			}
		}
	}

	/// The offset of a small marker in the output wire form. Static fragments stay in memory, so this
	/// never scans deferred weight payloads.
	func firstFileOffset(of marker: Data) -> UInt64? {
		guard !marker.isEmpty else { return nil }
		var fileOffset: UInt64 = 0
		for segment in segments {
			switch segment {
			case .data(let data):
				if let range = data.range(of: marker) {
					return fileOffset + UInt64(range.lowerBound)
				}
				fileOffset += UInt64(data.count)
			case .deferred(let payload):
				fileOffset += payload.byteCount
			case .progress:
				break
			}
		}
		return nil
	}
}

/// The streaming counterpart to ``CoreMLProtobufEncoder``. It deliberately shares the same wire
/// rules, but represents a nested message as fragments so a caller can count first and write later.
enum CoreMLProtobufStreamingEncoder {
	static func appendVarintField(_ fieldNumber: Int, value: UInt64, to segments: inout CoreMLProtobufSegments) {
		segments.append(data: key(fieldNumber, wireType: 0) + varint(value))
	}

	static func appendStringField(_ fieldNumber: Int, value: String, to segments: inout CoreMLProtobufSegments) {
		appendLengthDelimitedField(fieldNumber, data: Data(value.utf8), to: &segments)
	}

	static func appendFloatField(_ fieldNumber: Int, value: Float, to segments: inout CoreMLProtobufSegments) {
		var bits = value.bitPattern.littleEndian
		var data = key(fieldNumber, wireType: 5)
		withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
		segments.append(data: data)
	}

	static func appendMessageField(_ fieldNumber: Int, value: CoreMLProtobufSegments, to segments: inout CoreMLProtobufSegments) {
		segments.append(data: key(fieldNumber, wireType: 2) + varint(value.byteCount))
		segments.append(contentsOf: value)
	}

	static func appendDeferredPayloadField(
		_ fieldNumber: Int,
		payload: CoreMLProtobufDeferredPayload,
		to segments: inout CoreMLProtobufSegments
	) {
		segments.append(data: key(fieldNumber, wireType: 2) + varint(payload.byteCount))
		segments.append(deferred: payload)
	}

	private static func appendLengthDelimitedField(_ fieldNumber: Int, data: Data, to segments: inout CoreMLProtobufSegments) {
		segments.append(data: key(fieldNumber, wireType: 2) + varint(UInt64(data.count)))
		segments.append(data: data)
	}

	private static func key(_ fieldNumber: Int, wireType: UInt64) -> Data {
		precondition(fieldNumber > 0)
		return varint((UInt64(fieldNumber) << 3) | wireType)
	}

	private static func varint(_ value: UInt64) -> Data {
		var remaining = value
		var data = Data()
		while remaining >= 0x80 {
			data.append(UInt8(remaining & 0x7F) | 0x80)
			remaining >>= 7
		}
		data.append(UInt8(remaining))
		return data
	}
}

/// Publishes a fully written sibling temporary file over a destination. Both the extractor and
/// streamed model emitter use this exact replacement rule, so an existing artifact remains intact
/// until a complete replacement exists.
enum NativeModelAtomicFilePublisher {
	static func writeAtomically(
		to destinationURL: URL,
		writing body: (FileHandle) throws -> Void,
		beforePublish: () throws -> Void
	) throws {
		try writeAtomically(
			to: destinationURL,
			writing: body,
			beforePublish: { _ in try beforePublish() }
		)
	}

	static func writeAtomically(
		to destinationURL: URL,
		writing body: (FileHandle) throws -> Void,
		beforePublish: (URL) throws -> Void
	) throws {
		let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
			".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)",
			isDirectory: false
		)
		guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown)
		}
		var handle: FileHandle?
		var published = false
		defer {
			try? handle?.close()
			if !published { try? FileManager.default.removeItem(at: temporaryURL) }
		}
		let openedHandle = try FileHandle(forWritingTo: temporaryURL)
		handle = openedHandle
		try body(openedHandle)
		try openedHandle.close()
		handle = nil
		try beforePublish(temporaryURL)
		try publish(temporaryURL, as: destinationURL)
		published = true
	}

	static func publish(_ temporaryURL: URL, as destinationURL: URL) throws {
		if FileManager.default.fileExists(atPath: destinationURL.path) {
			_ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
		} else {
			try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
		}
	}
}

/// Encodes the protobuf wire types used by the first native Core ML emitter.
///
/// This is deliberately a small encoder, rather than a copy of the generated Core ML protobuf
/// surface. It covers only the fields emitted by `NativeModelCoreMLEmitter`; every field number is
/// verified against Apple's public Core ML model specification.
enum CoreMLProtobufEncoder {

	static func message(_ body: (inout Data) -> Void) -> Data {
		var data = Data()
		body(&data)
		return data
	}

	static func appendVarintField(_ fieldNumber: Int, value: UInt64, to data: inout Data) {
		appendKey(fieldNumber, wireType: 0, to: &data)
		appendVarint(value, to: &data)
	}

	static func appendStringField(_ fieldNumber: Int, value: String, to data: inout Data) {
		appendLengthDelimitedField(fieldNumber, value: Data(value.utf8), to: &data)
	}

	static func appendMessageField(_ fieldNumber: Int, value: Data, to data: inout Data) {
		appendLengthDelimitedField(fieldNumber, value: value, to: &data)
	}

	static func appendFloatField(_ fieldNumber: Int, value: Float, to data: inout Data) {
		appendKey(fieldNumber, wireType: 5, to: &data)
		var littleEndianBits = value.bitPattern.littleEndian
		withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
	}

	/// Core ML declares NMS thresholds as `double`, which is wire type 1 — writing them as floats
	/// would shift every following field and corrupt the message.
	static func appendDoubleField(_ fieldNumber: Int, value: Double, to data: inout Data) {
		appendKey(fieldNumber, wireType: 1, to: &data)
		var littleEndianBits = value.bitPattern.littleEndian
		withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
	}

	/// A packed `repeated` scalar field: proto3 encodes these as one length-delimited run of
	/// varints, which is how Core ML writes shape and permutation vectors.
	static func appendPackedVarintField(_ fieldNumber: Int, values: [UInt64], to data: inout Data) {
		var payload = Data()
		for value in values {
			appendVarint(value, to: &payload)
		}
		appendLengthDelimitedField(fieldNumber, value: payload, to: &data)
	}

	/// Writes a signed `int64` field. Negative values occupy the full ten-byte varint (two's
	/// complement, *not* zigzag — that is `sint64`), which is how Core ML encodes an unbounded
	/// shape-range upper bound of -1.
	static func appendSignedVarintField(_ fieldNumber: Int, value: Int64, to data: inout Data) {
		appendKey(fieldNumber, wireType: 0, to: &data)
		appendVarint(UInt64(bitPattern: value), to: &data)
	}

	private static func appendKey(_ fieldNumber: Int, wireType: UInt64, to data: inout Data) {
		precondition(fieldNumber > 0)
		appendVarint((UInt64(fieldNumber) << 3) | wireType, to: &data)
	}

	private static func appendLengthDelimitedField(_ fieldNumber: Int, value: Data, to data: inout Data) {
		appendKey(fieldNumber, wireType: 2, to: &data)
		appendVarint(UInt64(value.count), to: &data)
		data.append(value)
	}

	private static func appendVarint(_ value: UInt64, to data: inout Data) {
		var remaining = value
		while remaining >= 0x80 {
			data.append(UInt8(remaining & 0x7F) | 0x80)
			remaining >>= 7
		}
		data.append(UInt8(remaining))
	}
}
