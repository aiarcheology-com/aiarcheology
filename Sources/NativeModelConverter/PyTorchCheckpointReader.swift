//
//  PyTorchCheckpointReader.swift
//  NativeModelConverter
//
//  Turning a torch.save archive into a typed description of what is in it (AIA-0666).
//

import Foundation

/// The element type of a tensor's storage.
public enum PyTorchTensorDataType: String, Equatable, Sendable {
	case float32
	case int64

	var byteCount: Int {
		switch self {
		case .float32: return 4
		case .int64: return 8
		}
	}
}

/// One entry of a checkpoint's `state_dict`.
///
/// **Logical metadata only — there is no file range here.** This milestone reads no weights, and an
/// offset it never uses is arithmetic that never gets exercised: real tensors are contiguous and
/// start at storage offset zero, so a stride or offset bug would sit undetected until something
/// finally read a blob. Resolving a storage to a byte range belongs with the code that reads one.
public struct PyTorchTensorRef: Equatable, Sendable {
	public let name: String
	public let dataType: PyTorchTensorDataType
	public let shape: [Int]
	public let stride: [Int]
	/// The tensor's first element within its storage, in elements.
	public let storageOffset: Int
	/// The archive entry holding the storage, as `data/<key>`.
	public let storageKey: String
	/// The **storage's** element count, which a tensor may only partially view.
	public let storageElementCount: Int

	/// The number of elements the tensor itself has.
	public var elementCount: Int { shape.reduce(1, *) }

	/// True when the tensor covers its whole storage in row-major order — the shape every tensor in
	/// the pinned ADAF checkpoints has, and the one a weight reader can treat as a flat copy.
	public var isContiguousAndComplete: Bool {
		guard storageOffset == 0, elementCount == storageElementCount else { return false }
		var expected = 1
		for (dimension, step) in zip(shape, stride).reversed() {
			guard step == expected else { return false }
			expected *= dimension
		}
		return true
	}
}

/// What a `torch.save` checkpoint says about itself.
public struct PyTorchCheckpoint: Equatable, Sendable {
	/// The archive's single root directory, e.g. `best_checkpoint_1691592063_17.pth`.
	public let root: String
	/// The `version` entry's contents. 3 for every ADAF checkpoint.
	public let formatVersion: Int
	/// The training `run_id` aitlas wrote (`aitlas/base/models.py:751`), when present. This is the
	/// only place the model's class name appears.
	public let identifier: String?
	public let epoch: Int?
	public let loss: Double?
	public let startTimestamp: Int?
	/// The `state_dict`, in the order the file records it — which is the model's layer order.
	public let tensors: [PyTorchTensorRef]
	/// Every storage the pickle references, including the optimizer's. Counted, never located.
	public let totalStorageCount: Int
}

public enum PyTorchCheckpointError: Error, Equatable {
	case unreadableArchive(String)
	case unreadablePickle(String)
	case notACheckpoint(String)
	case missingStateDictionary
	case missingVersion
	case unsupportedFormatVersion(Int)
	case tooManyTensors(Int)
	/// A tensor's storage is not the size the archive says that entry is. The archive and the pickle
	/// are two independent statements about the same bytes, so a disagreement means one of them is
	/// being misread.
	case storageSizeDisagreesWithArchive(tensor: String, declared: Int, archive: Int)
	case storageMissingFromArchive(tensor: String, entry: String)
	case tensorOutsideItsStorage(tensor: String)
}

/// Reads a `torch.save` checkpoint's structure: what tensors it holds, what shape they are, and the
/// scalars recorded alongside them.
///
/// Reads exactly four things — the archive's end records, its central directory, `data.pkl` and
/// `version` — which for a 517,823,445-byte ADAF checkpoint is under a megabyte. **No weight bytes
/// are read and no storage is located**, including the optimizer's, which is two thirds of the file.
public enum PyTorchCheckpointReader {

	/// The `state_dict` width this will read. HRNet, the largest published ADAF checkpoint, has
	/// 1,964; anything beyond 25x that is not a model this converter has any prospect of supporting.
	static let maximumTensorCount = 50_000

	public static func read(contentsOf url: URL) throws -> PyTorchCheckpoint {
		let source: FileBytes
		do {
			source = try FileBytes(url: url)
		} catch {
			throw PyTorchCheckpointError.unreadableArchive("\(error)")
		}
		return try read(source)
	}

	static func read(_ source: any RandomAccessBytes) throws -> PyTorchCheckpoint {
		let archive: PyTorchZipArchive
		let root: String
		let pickleEntry: PyTorchZipEntry
		do {
			archive = try PyTorchZipArchive.open(source)
			(root, pickleEntry) = try archive.torchPickleEntry()
		} catch let error as PyTorchZipArchiveError {
			throw PyTorchCheckpointError.unreadableArchive(String(describing: error))
		}

		let formatVersion = try readFormatVersion(archive, root: root)
		let top = try decodeTopLevel(archive, entry: pickleEntry)
		let tensors = try readTensors(top, archive: archive, root: root)

		return PyTorchCheckpoint(
			root: root,
			formatVersion: formatVersion,
			identifier: top["id"].flatMap(\.stringValue),
			epoch: top["epoch"].flatMap(\.intValue),
			loss: top["loss"].flatMap(\.doubleValue),
			startTimestamp: top["start"].flatMap(\.intValue),
			tensors: tensors,
			totalStorageCount: countStorages(in: top)
		)
	}

	/// The `version` entry, which torch writes as a decimal integer and a newline.
	private static func readFormatVersion(_ archive: PyTorchZipArchive, root: String) throws -> Int {
		guard let entry = archive.entry(named: "\(root)/version") else {
			throw PyTorchCheckpointError.missingVersion
		}
		let bytes: [UInt8]
		do {
			bytes = try archive.bytes(of: entry, maximumByteCount: 64)
		} catch let error as PyTorchZipArchiveError {
			throw PyTorchCheckpointError.unreadableArchive(String(describing: error))
		}
		guard let text = String(bytes: bytes, encoding: .utf8),
			let version = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
		else {
			throw PyTorchCheckpointError.missingVersion
		}
		// 3 is what every published ADAF checkpoint carries. Refusing anything else is the pinned-model
		// position: a different serialization version is a different format to have checked.
		guard version == 3 else { throw PyTorchCheckpointError.unsupportedFormatVersion(version) }
		return version
	}

	private static func decodeTopLevel(_ archive: PyTorchZipArchive, entry: PyTorchZipEntry) throws -> PickleValue {
		let pickle: [UInt8]
		do {
			pickle = try archive.bytes(of: entry, maximumByteCount: PyTorchPickleDecoder.Caps.pickleBytes)
		} catch let error as PyTorchZipArchiveError {
			throw PyTorchCheckpointError.unreadableArchive(String(describing: error))
		}
		do {
			let value = try PyTorchPickleDecoder.decode(pickle)
			guard case .dictionary = value else {
				throw PyTorchCheckpointError.notACheckpoint("the pickle is not a dictionary")
			}
			return value
		} catch let error as PickleDecoderError {
			throw PyTorchCheckpointError.unreadablePickle(String(describing: error))
		}
	}

	/// Builds the tensor table, cross-checking every storage against the archive.
	///
	/// The cross-check is the one place this reader can be caught being wrong by something other than
	/// a test author's belief. The pickle says a storage holds *n* elements of a given type; the
	/// central directory independently says that entry is *m* bytes. If `n x elementSize != m`, then
	/// either the dtype table is wrong or the persistent id is being misread — and both would
	/// otherwise stay invisible until M3 read a blob and got noise.
	private static func readTensors(
		_ top: PickleValue,
		archive: PyTorchZipArchive,
		root: String
	) throws -> [PyTorchTensorRef] {
		guard let stateDict = top["state_dict"], case .dictionary(let entries) = stateDict else {
			throw PyTorchCheckpointError.missingStateDictionary
		}
		guard entries.count <= maximumTensorCount else {
			throw PyTorchCheckpointError.tooManyTensors(entries.count)
		}

		return try entries.map { entry in
			guard case .string(let name) = entry.key else {
				throw PyTorchCheckpointError.notACheckpoint("a state_dict key is not a string")
			}
			guard case .tensor(let tensor) = entry.value else {
				throw PyTorchCheckpointError.notACheckpoint("state_dict entry '\(name)' is not a tensor")
			}

			let dataType: PyTorchTensorDataType = tensor.storage.kind == .float32 ? .float32 : .int64
			let entryName = "\(root)/data/\(tensor.storage.key)"
			guard let blob = archive.entry(named: entryName) else {
				throw PyTorchCheckpointError.storageMissingFromArchive(tensor: name, entry: entryName)
			}
			// A declared size that overflows is reported as -1 rather than being wrapped into a
			// plausible-looking number that might happen to match.
			let declared = checkedProduct(tensor.storage.elementCount, dataType.byteCount) ?? -1
			guard declared == blob.uncompressedSize else {
				throw PyTorchCheckpointError.storageSizeDisagreesWithArchive(
					tensor: name, declared: declared, archive: blob.uncompressedSize
				)
			}

			let reference = PyTorchTensorRef(
				name: name,
				dataType: dataType,
				shape: tensor.shape,
				stride: tensor.stride,
				storageOffset: tensor.storageOffset,
				storageKey: tensor.storage.key,
				storageElementCount: tensor.storage.elementCount
			)
			// A view must fit the storage it views. The published checkpoints are all contiguous and
			// offset zero, so nothing here is exercised by them -- which is exactly why it is checked
			// rather than assumed.
			guard let span = checkedSum(reference.elementCount, tensor.storageOffset),
				span <= tensor.storage.elementCount
			else {
				throw PyTorchCheckpointError.tensorOutsideItsStorage(tensor: name)
			}
			return reference
		}
	}

	/// Counts every storage the pickle mentions, without looking any of them up.
	///
	/// The optimizer's 528 storages are 344 MB of the file and are counted here purely so the total
	/// can be checked against the archive's entry count. Nothing resolves them, which is what keeps
	/// two thirds of the download unread.
	///
	/// Iterative rather than recursive: the decoder caps nesting at 64 so recursion would be safe
	/// today, but a traversal that cannot overflow regardless of its input is one fewer thing to
	/// re-check when a cap moves.
	private static func countStorages(in value: PickleValue) -> Int {
		var pending = [value]
		var count = 0
		while let current = pending.popLast() {
			switch current {
			case .storage:
				count += 1
			case .tensor(let tensor):
				_ = tensor
				count += 1
			case .tuple(let items), .list(let items):
				pending.append(contentsOf: items)
			case .dictionary(let entries):
				for entry in entries {
					pending.append(entry.key)
					pending.append(entry.value)
				}
			case .none, .bool, .int, .double, .string, .global:
				break
			}
		}
		return count
	}
}

extension PickleValue {
	var stringValue: String? {
		guard case .string(let value) = self else { return nil }
		return value
	}

	var intValue: Int? {
		guard case .int(let value) = self else { return nil }
		return value
	}

	var doubleValue: Double? {
		guard case .double(let value) = self else { return nil }
		return value
	}

	subscript(key: String) -> PickleValue? {
		guard case .dictionary(let entries) = self else { return nil }
		return entries.first { $0.key == .string(key) }?.value
	}
}
