//
//  PyTorchWeightExtractor.swift
//  NativeModelConverter
//
//  Reading a checkpoint's weight bytes into the blob an emitter addresses (AIA-0675).
//

import CryptoKit
import Foundation

/// What an extraction produced, and what it deliberately left out.
///
/// The skipped list is part of the result rather than a log line because "some tensors were not
/// written" is exactly the kind of fact that is invisible until a model is silently missing a layer.
public struct PyTorchWeightExtraction: Equatable, Sendable {
	/// The written weights, in `state_dict` order — which is the model's layer order.
	public let weights: [NativeModelWeight]
	/// The blob's length. Half the floating-point bytes read, by construction.
	public let byteCount: UInt64
	/// The fp32 bytes read out of the checkpoint.
	public let sourceByteCount: UInt64
	/// The blob's SHA-256, lowercase hex.
	///
	/// Computed in the same pass rather than by re-reading the file, because the next slice's package
	/// manifest requires one (``NativeModelGraphPackageManifest/weightsSHA256``) and re-hashing 82 MiB
	/// on a phone to learn something this loop already had in its hands is work for nothing.
	public let sha256: String
	/// Tensors deliberately not written: the BatchNorm `num_batches_tracked` counters.
	///
	/// In every published ADAF checkpoint these are 65 int64 scalars a BatchNorm layer increments
	/// during training and no forward pass reads — torchvision's evaluation path never touches one,
	/// and the emitter's batch-normalisation layer wants scale, bias, mean and variance and nothing
	/// else. ``NativeModelDataType`` has no integer case, so there is nothing to write them as.
	///
	/// The skip is deliberately narrow. "Skip every integer tensor" would silently drop a meaningful
	/// one from some future checkpoint; only this named counter is skipped, and anything else
	/// unrepresentable is refused by name. ``weights`` and this list together account for every
	/// tensor in the `state_dict`.
	public let skippedCounterTensors: [String]
	/// The process footprint observed across the extraction, sampled once per chunk.
	///
	/// Three things this is not, all of which it would otherwise be quoted as. It is a *process*
	/// figure, so it includes whatever the host was already holding —
	/// ``NativeModelConversionProcessMemoryUsage/observedPeakIncreaseByteCount`` is the part this
	/// extraction is answerable for. It is a **sampled lower bound**, not a guaranteed peak. And it
	/// measures *extraction only*: emitting a Core ML model afterwards copies the weight bytes
	/// several times as its protobuf nesting unwinds, so the conversion's real peak is dominated by
	/// emission and is a different measurement than this one.
	public let memory: NativeModelConversionProcessMemoryUsage?
}

public enum PyTorchWeightExtractionError: Error, Equatable {
	case unreadableArchive(String)
	/// A tensor is a strided or partial view of its storage. The reader already refuses these; this
	/// is the second statement of the same rule, because a caller can hand this code a checkpoint it
	/// did not read itself.
	case tensorIsNotContiguous(tensor: String)
	case storageMissingFromArchive(tensor: String, entry: String)
	/// The archive entry is not the size the tensor's shape implies. The checkpoint and the archive
	/// are two independent statements about the same bytes; a disagreement means this extraction
	/// would write something other than the tensor it is naming.
	case storageSizeDisagreesWithArchive(tensor: String, expected: Int, archive: Int)
	/// A finite fp32 weight that fp16 cannot represent, so storing it would replace a number with an
	/// infinity and no test downstream would see anything wrong. Named rather than clamped.
	case valueNotRepresentableInFloat16(tensor: String)
	/// A weight that is already NaN or infinite in the checkpoint. Copying it faithfully produces
	/// exactly the poisoned artifact the overflow check exists to prevent — the value's provenance
	/// does not make it any more usable — so it is refused rather than passed through.
	case nonFiniteWeight(tensor: String)
	/// The weights would exceed the caller's total budget. Distinct from a single oversized tensor:
	/// a checkpoint may name thousands of tensors that all reference **one** storage, and the reader
	/// permits that (torch writes it for tied parameters). Without a total, a small archive can ask
	/// for an unbounded amount of reading, converting and writing.
	case weightsExceedBudget(byteCount: UInt64, limit: UInt64)
	/// The storage's bytes do not match the checksum the archive's central directory records for
	/// them. Distinct from a malformed archive: the container parsed, and the bytes at the resolved
	/// offset are not the bytes that were written there.
	case storageChecksumFailed(tensor: String)
	case destinationNotWritable(String)
	case shapeTooLarge(tensor: String)
	/// A tensor whose element type the graph cannot express and which is not the one counter this
	/// extractor is allowed to drop. Refused by name rather than skipped, so a checkpoint carrying a
	/// meaningful integer tensor cannot lose it silently.
	case unrepresentableTensor(tensor: String, dataType: String)
	/// The archive being extracted is not the one the checkpoint description was decoded from.
	case checkpointDescribesAnotherArchive
}

/// Copies a checkpoint's `state_dict` into a flat `weights.bin`, converting fp32 to fp16 on the way.
///
/// **fp16 is the storage format on purpose.** M3a measured that a Core ML model computing on `ALL`
/// produces identical output from fp32 and fp16 weights — the GPU and Neural Engine compute in half
/// precision whatever is stored — so halving a 165 MiB artifact costs nothing *there*. It is not
/// free on `cpuOnly`, which computes in fp32 and will diverge from an fp32-weight model. That
/// trade-off belongs to whoever chooses the compute unit, and it is stated here so the choice is
/// made knowingly.
///
/// **Bounded memory is the other reason this exists.** The state_dict is 173,262,188 bytes of fp32
/// across 339 storages, the largest of which runs to tens of megabytes. Reading a storage whole
/// would put that on a phone's heap for no reason, so every read goes through
/// ``PyTorchZipArchive/streamBytes(of:maximumByteCount:chunkByteCount:receive:)`` and peak residency
/// tracks the chunk size, not the checkpoint.
public enum PyTorchWeightExtractor {

	/// The largest single storage this will read. The largest tensor in any published ADAF
	/// checkpoint is two orders of magnitude below this; the cap exists so a hostile central
	/// directory cannot name a half-gigabyte "tensor" and have it read.
	public static let maximumStorageByteCount = 128 * 1024 * 1024

	/// The most bytes the emitted blob may reach, unless the caller says otherwise.
	///
	/// The published ADAF detectors produce 86,630,834 bytes, so this is generous by 6x. It exists
	/// for the amplification a per-tensor limit cannot see: `maximumStorageByteCount` bounds one
	/// storage, but nothing bounds how many tensors name the same one, and each is streamed and
	/// written again.
	public static let defaultMaximumTotalByteCount: UInt64 = 512 * 1024 * 1024

	/// The most fp32 bytes held at once. A multiple of four, which is what keeps a float from
	/// straddling two chunks — the boundary bug that would shift every subsequent value by a byte and
	/// still produce a blob of exactly the right length.
	static let chunkByteCount = 1024 * 1024

	/// Writes `checkpoint`'s floating-point tensors to `destinationURL` as fp16.
	///
	/// - Parameter checkpointURL: the file `checkpoint` was read from. Reopened here rather than
	///   carried on ``PyTorchCheckpoint``, which is a description of a file and holds no handle to
	///   one.
	/// - Important: on any throw the destination is removed, on a best-effort basis — a removal that
	///   itself fails cannot be reported without replacing the real error with a worse one. A
	///   partially written blob whose manifest claims a length is worse than no blob at all, and the
	///   checksum that would catch it is not computed until the whole entry has been streamed.
	public static func extract(
		_ checkpoint: PyTorchCheckpoint,
		from checkpointURL: URL,
		to destinationURL: URL,
		maximumTotalByteCount: UInt64 = defaultMaximumTotalByteCount
	) throws -> PyTorchWeightExtraction {
		let source: FileBytes
		do {
			source = try FileBytes(url: checkpointURL)
		} catch {
			throw PyTorchWeightExtractionError.unreadableArchive("\(error)")
		}
		return try extract(
			checkpoint, from: source, to: destinationURL,
			maximumTotalByteCount: maximumTotalByteCount
		)
	}

	/// The extraction itself, over any byte source.
	///
	/// Separate from the URL entry point because the source is the only thing that differs between
	/// reading a downloaded checkpoint and reading a fixture that carries two regions of one, and a
	/// copy of this loop per source is how the two drift apart.
	static func extract(
		_ checkpoint: PyTorchCheckpoint,
		from source: any RandomAccessBytes,
		to destinationURL: URL,
		maximumTotalByteCount: UInt64 = defaultMaximumTotalByteCount
	) throws -> PyTorchWeightExtraction {
		let archive: PyTorchZipArchive
		let pickleEntry: PyTorchZipEntry
		do {
			archive = try PyTorchZipArchive.open(source)
			(_, pickleEntry) = try archive.torchPickleEntry()
		} catch {
			throw PyTorchWeightExtractionError.unreadableArchive("\(error)")
		}
		// The description and the bytes must come from the same `data.pkl`. `checkpoint` was decoded
		// from *a* file and this opens one again, and between those two moments the file can change —
		// a resumed download, a shared cache directory, or a caller that simply passed the wrong URL.
		// Every other check here would still pass: the four published detectors have byte-identical
		// tensor tables, so names, shapes, storage keys, entry sizes and per-entry CRCs would all
		// agree while the weights came from a different model and nothing said so.
		//
		// The payload is **re-read** rather than compared against the directory's declared CRC field.
		// Reading it verifies it against that field (`bytes(of:)` checks the checksum), so a
		// replacement archive cannot simply copy the original's declared value into a directory
		// describing different pickle bytes.
		//
		// - Important: this binds the description to the **pickle**, not to the whole file. An archive
		//   carrying byte-identical pickle bytes beside different storage payloads — with matching
		//   recomputed CRCs — is not detected, and cannot be by any check over `data.pkl`. Closing
		//   that needs a whole-file digest, which costs a full re-read of a 518 MB download and would
		//   undo the reader's under-a-megabyte read set. It is a deliberate limit, not an oversight.
		do {
			let pickle = try archive.bytes(
				of: pickleEntry, maximumByteCount: PyTorchPickleDecoder.Caps.pickleBytes
			)
			guard CRC32.checksum(pickle) == checkpoint.pickleChecksum else {
				throw PyTorchWeightExtractionError.checkpointDescribesAnotherArchive
			}
		} catch let error as PyTorchWeightExtractionError {
			throw error
		} catch {
			throw PyTorchWeightExtractionError.unreadableArchive("\(pickleEntry.name): \(error)")
		}

		guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
			throw PyTorchWeightExtractionError.destinationNotWritable(destinationURL.lastPathComponent)
		}
		guard let handle = try? FileHandle(forWritingTo: destinationURL) else {
			// The file exists by now and this method promises to leave none behind on a throw. Folding
			// this into the guard above leaves an empty `weights.bin` on disk, which a caller that
			// treats the file's presence as success would read as an empty model.
			try? FileManager.default.removeItem(at: destinationURL)
			throw PyTorchWeightExtractionError.destinationNotWritable(destinationURL.lastPathComponent)
		}

		let tracker = NativeModelConversionMemoryTracker()
		var memory = tracker.sample()
		var digest = SHA256()
		var weights: [NativeModelWeight] = []
		var skipped: [String] = []
		var offset: UInt64 = 0
		var sourceByteCount: UInt64 = 0
		var completed = false
		defer {
			try? handle.close()
			if completed == false {
				try? FileManager.default.removeItem(at: destinationURL)
			}
		}

		for tensor in checkpoint.tensors {
			guard tensor.dataType == .float32 else {
				guard tensor.dataType == .int64,
					tensor.name.hasSuffix(".num_batches_tracked"),
					tensor.shape.isEmpty,
					tensor.storageElementCount == 1
				else {
					throw PyTorchWeightExtractionError.unrepresentableTensor(
						tensor: tensor.name, dataType: tensor.dataType.rawValue
					)
				}
				skipped.append(tensor.name)
				continue
			}
			guard tensor.isContiguousAndComplete else {
				throw PyTorchWeightExtractionError.tensorIsNotContiguous(tensor: tensor.name)
			}
			guard let expectedSourceBytes = checkedProduct(tensor.elementCount, tensor.dataType.byteCount),
				let halfBytes = checkedProduct(tensor.elementCount, 2)
			else {
				throw PyTorchWeightExtractionError.shapeTooLarge(tensor: tensor.name)
			}
			// Checked before the tensor is streamed, not after: the point is to refuse the work, not
			// to notice afterwards that too much of it was done.
			let projected = offset + UInt64(halfBytes)
			guard projected <= maximumTotalByteCount else {
				throw PyTorchWeightExtractionError.weightsExceedBudget(
					byteCount: projected, limit: maximumTotalByteCount
				)
			}

			let entryName = "\(checkpoint.root)/data/\(tensor.storageKey)"
			guard let entry = archive.entry(named: entryName) else {
				throw PyTorchWeightExtractionError.storageMissingFromArchive(
					tensor: tensor.name, entry: entryName
				)
			}
			guard entry.uncompressedSize == expectedSourceBytes else {
				throw PyTorchWeightExtractionError.storageSizeDisagreesWithArchive(
					tensor: tensor.name, expected: expectedSourceBytes, archive: entry.uncompressedSize
				)
			}

			do {
				try archive.streamBytes(
					of: entry,
					maximumByteCount: maximumStorageByteCount,
					chunkByteCount: chunkByteCount
				) { chunk in
					let converted = Data(try float16Bytes(of: chunk, tensor: tensor.name))
					digest.update(data: converted)
					// A disk-full or permission failure here is a fact about the destination, and
					// reporting it as a malformed archive sends whoever reads the error to the wrong
					// file entirely.
					do {
						try handle.write(contentsOf: converted)
					} catch {
						throw PyTorchWeightExtractionError.destinationNotWritable(
							destinationURL.lastPathComponent
						)
					}
					// Sampled here rather than per tensor: the residency this is asked about is the
					// chunk's, and a tensor-boundary sample can miss it entirely.
					memory = tracker.sample() ?? memory
				}
			} catch let error as PyTorchWeightExtractionError {
				throw error
			} catch PyTorchZipArchiveError.checksumMismatch {
				throw PyTorchWeightExtractionError.storageChecksumFailed(tensor: tensor.name)
			} catch {
				throw PyTorchWeightExtractionError.unreadableArchive("\(entryName): \(error)")
			}

			weights.append(NativeModelWeight(
				name: tensor.name,
				dataType: .float16,
				shape: tensor.shape,
				offset: offset,
				byteCount: UInt64(halfBytes)
			))
			offset += UInt64(halfBytes)
			sourceByteCount += UInt64(expectedSourceBytes)
		}

		completed = true
		return PyTorchWeightExtraction(
			weights: weights,
			byteCount: offset,
			sourceByteCount: sourceByteCount,
			sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
			skippedCounterTensors: skipped,
			memory: memory
		)
	}

	/// Converts one chunk of little-endian fp32 to little-endian fp16.
	///
	/// The decode is explicit rather than a reinterpret of the host's memory layout, so the result
	/// does not depend on which CPU runs it. The *source* is assumed little-endian: `torch.save`
	/// format 3 writes storages in the saving host's byte order and records nothing about it — this
	/// archive's only non-`data/` entries are `data.pkl` and `version`, with no `byteorder` record —
	/// so a checkpoint written on a big-endian host would be misread and nothing in the file says so.
	/// Every published ADAF checkpoint was written little-endian.
	private static func float16Bytes(of chunk: [UInt8], tensor: String) throws -> [UInt8] {
		// The caller guarantees this by sizing chunks in multiples of four against an entry whose
		// length is a multiple of four, but a leftover byte here would silently shift every value in
		// every later chunk, so it is checked rather than trusted.
		guard chunk.count % 4 == 0 else {
			throw PyTorchWeightExtractionError.storageSizeDisagreesWithArchive(
				tensor: tensor, expected: chunk.count - chunk.count % 4, archive: chunk.count
			)
		}
		var converted = [UInt8]()
		converted.reserveCapacity(chunk.count / 2)
		var index = 0
		while index < chunk.count {
			let bits = UInt32(chunk[index])
				| UInt32(chunk[index + 1]) << 8
				| UInt32(chunk[index + 2]) << 16
				| UInt32(chunk[index + 3]) << 24
			let value = Float(bitPattern: bits)
			// A weight that arrives NaN or infinite is refused rather than copied. Faithfulness is the
			// wrong instinct here: the result is the same poisoned artifact the overflow check below
			// exists to prevent, and it would carry exactly the length the manifest expects. Measured
			// on all four published detectors: zero NaN, zero infinities, so nothing real is refused.
			guard value.isFinite else {
				throw PyTorchWeightExtractionError.nonFiniteWeight(tensor: tensor)
			}
			let half = Float16(value)
			// Underflow to zero is ordinary precision loss and is accepted. Overflow to infinity is
			// not, for the same reason.
			guard half.isFinite else {
				throw PyTorchWeightExtractionError.valueNotRepresentableInFloat16(tensor: tensor)
			}
			let halfBits = half.bitPattern
			converted.append(UInt8(halfBits & 0xFF))
			converted.append(UInt8(halfBits >> 8))
			index += 4
		}
		return converted
	}
}
