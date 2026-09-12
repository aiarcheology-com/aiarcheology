//
//  PyTorchPickleDecoder.swift
//  NativeModelConverter
//
//  A restricted, data-only decoder for the pickle inside a torch.save checkpoint (AIA-0666).
//

import Foundation

/// The dtype of a tensor storage, named by the global that produced it.
///
/// Exactly the two that the pinned ADAF checkpoints use. This is not a simplification to be relaxed
/// later: the allow-list of globals *is* the containment argument, so a third entry is a deliberate
/// decision with its own evidence, not a convenience.
enum PickleStorageKind: Equatable, Hashable {
	case float32
	case int64

	var byteCount: Int {
		switch self {
		case .float32: return 4
		case .int64: return 8
		}
	}
}

/// A reference to one `data/<key>` blob in the archive. Nothing is read here — this is what the
/// pickle *says* exists.
struct PickleStorage: Equatable, Hashable {
	let kind: PickleStorageKind
	let key: String
	let location: String
	/// The element count of the **storage**, which is not necessarily the element count of a tensor
	/// viewing it. Conflating the two is how a view's bounds stop being checked.
	let elementCount: Int
}

/// A tensor as `torch._utils._rebuild_tensor_v2` describes it: a view onto a storage.
struct PickleTensor: Equatable, Hashable {
	let storage: PickleStorage
	let storageOffset: Int
	let shape: [Int]
	let stride: [Int]
	let requiresGrad: Bool
}

/// A decoded pickle value.
///
/// - Important: every case is a value type, and that is load-bearing rather than stylistic. Pickle's
///   memo is reference-semantic by definition, so in CPython the three-opcode program
///   `EMPTY_LIST; BINPUT 0; BINGET 0; APPEND` builds a list containing *itself*. Here `BINGET`
///   pushes a copy, so the same program yields `[[]]` — a two-node graph. Cycles are therefore not
///   detected, they are **unrepresentable**, and every traversal terminates without a visited set.
///   Introducing a reference type anywhere in this enum would silently give that guarantee away and
///   hand an attacker infinite loops in equality, hashing, description and deallocation.
///
///   The price is a real divergence from CPython for a container that is memoized, then populated,
///   then re-fetched: the re-fetch sees the empty version. `PyTorchPickleDecoderTests` pins both
///   halves. It is safe in practice because the real checkpoints are decoded in the same suite: if
///   torch ever relied on that aliasing for `state_dict`, the tensor count would collapse from 404
///   to 0 and the assertion would fail loudly.
indirect enum PickleValue: Equatable, Hashable {
	case none
	case bool(Bool)
	case int(Int)
	case double(Double)
	case string(String)
	case tuple([PickleValue])
	case list([PickleValue])
	/// Insertion-ordered, because a `state_dict` is an `OrderedDict` and the tensor order is the
	/// model's layer order — information a Swift `Dictionary` would throw away.
	case dictionary([PickleEntry])
	case storage(PickleStorage)
	case tensor(PickleTensor)
	/// One of the four permitted globals, on the stack only until the opcode that consumes it. It is
	/// an opaque token: nothing can be done with it except the single transition it is allowed.
	case global(PickleGlobal)
}

struct PickleEntry: Equatable, Hashable {
	let key: PickleValue
	let value: PickleValue
}

/// The complete set of globals this decoder will resolve.
///
/// Measured: `GLOBAL` appears exactly four times in every ADAF checkpoint, and these are the four.
/// There is no mechanism to call any of them — see ``PyTorchPickleDecoder``'s note on `REDUCE`.
enum PickleGlobal: Equatable, Hashable {
	case orderedDict
	case rebuildTensorV2
	case storage(PickleStorageKind)

	static func named(module: String, name: String) -> PickleGlobal? {
		switch (module, name) {
		case ("collections", "OrderedDict"): return .orderedDict
		case ("torch._utils", "_rebuild_tensor_v2"): return .rebuildTensorV2
		case ("torch", "FloatStorage"): return .storage(.float32)
		case ("torch", "LongStorage"): return .storage(.int64)
		default: return nil
		}
	}
}

enum PickleDecoderError: Error, Equatable {
	case empty
	case truncated(atOffset: Int)
	case missingProtocolHeader
	case unsupportedProtocol(Int)
	case unsupportedOpcode(UInt8, atOffset: Int)
	case stackUnderflow(opcode: UInt8, atOffset: Int)
	case typeMismatch(String, atOffset: Int)
	case forbiddenGlobal(module: String, name: String)
	case unsupportedReduction(String)
	case unsupportedBuild(String)
	case malformedPersistentID(String)
	case invalidMemoReference(Int)
	case notUTF8(atOffset: Int)
	case trailingBytes(count: Int)
	case capExceeded(Cap)

	enum Cap: String, Equatable {
		case opcodes
		case memoEntries
		case materializedNodes
		case containerWork
		case containerWidth
		case stringLength
		case nestingDepth
		case stackDepth
		case marks
		case pickleBytes
		case tensorRank
	}
}

/// Decodes the object graph in a `torch.save` archive's `data.pkl`, without executing anything.
///
/// **Containment is by construction, not by validation.** A pickle is a program for a virtual
/// machine whose `REDUCE` opcode calls an arbitrary callable — that is what makes `torch.load`
/// dangerous. This decoder has no call mechanism at all: `REDUCE` pattern-matches two shapes and
/// yields a value, and `GLOBAL` resolves only four names, so there is no arrangement of bytes that
/// reaches code. Everything else is refusal.
///
/// The remaining risks in a hand-written parser are resource exhaustion and traps, and those are
/// answered by the cap table in ``Caps`` — every cap sized from the largest real checkpoint
/// (`AO_HRNet`, 621,064 bytes and 161,796 opcodes) rather than the smallest, because a cap picked
/// from the smallest is a cap that rejects a real file.
enum PyTorchPickleDecoder {

	/// Limits, each with a measured floor. The observed columns are asserted in the test suite, so a
	/// change that inflates one shows up before it starts rejecting real checkpoints.
	///
	/// | cap | ringfort | AO_HRNet | here | margin |
	/// |-|-|-|-|-|
	/// | bytes | 113,659 | 621,064 | 16 MiB | 27x |
	/// | opcodes | 31,438 | 161,795 | 4,000,000 | 24x |
	/// | memo entries | 7,853 | 40,387 | 1,000,000 | 24x |
	/// | materialized nodes | 109,622 | 562,689 | 16,000,000 | 28x |
	/// | container work | 0 | 2,000 | 4,000,000 | 2,000x |
	/// | stack depth | 820 | 2,012 | 100,000 | 49x |
	/// | container width | 404 | 1,964 | 50,000 | 25x |
	/// | string length | 56 | 68 | 4,096 | 60x |
	/// | nesting depth | 5 | 5 | 128 | 25x |
	/// | tensor rank | 4 | 4 | 16 | 4x |
	/// | simultaneous marks | 6 | 6 | 1,024 | 170x |
	///
	/// The node and depth figures rose when tensors and storages started retaining the weight of the
	/// arguments they were built from — a fix, not drift: charging a tensor as one node let a wide
	/// memoized shape be recalled thousands of times for nothing. The two-sided assertion is what
	/// surfaced the change, which is the reason it measures floors as well as ceilings.
	///
	/// Container work is the outlier and deliberately so: it meters copy *cost*, not size, and its
	/// real-file floor is near zero because `torch.save` fills each container in one batch. It is
	/// sized to bound wall-clock rather than to hug the floor -- 4,000,000 element copies is a
	/// fraction of a second, where the original 40,000,000 allowed about ten.
	enum Caps {
		static let pickleBytes = 16 * 1024 * 1024
		static let opcodes = 4_000_000
		static let memoEntries = 1_000_000
		static let materializedNodes = 16_000_000
		/// The summed size of every container rebuilt during a decode.
		///
		/// Value semantics make each `SETITEM` or `APPEND` copy the container it grows, so the *work*
		/// a pickle costs is not bounded by the size of anything it produces. Without this, a dict
		/// grown one key at a time to the width cap is quadratic: measured at 0.034 s for 1,000 keys,
		/// 0.541 s for 4,000 and 8.588 s for 16,000, which extrapolates to about 335 s at 100,000 —
		/// a hang, from a pickle of a few megabytes. Charging the size of every container touched is
		/// what turns that into a refusal.
		static let containerWork = 4_000_000
		static let stackDepth = 100_000
		/// Kept below ``stackDepth`` on purpose: a container is assembled on the stack, so if the two
		/// were equal an over-wide container would trip the stack cap first and the refusal would name
		/// the wrong thing.
		static let containerWidth = 50_000
		static let stringLength = 4_096
		static let nestingDepth = 128
		static let marks = 1_024
		/// Dimensions in one tensor's `size`/`stride`. Every published ADAF tensor has rank 4 or less.
		///
		/// Without it a `size` tuple can be as wide as the container cap, and rank multiplies every
		/// later traversal of the table: 50,000 dimensions across 50,000 tensors is billions of
		/// multiplications from a pickle that trips no other limit.
		static let tensorRank = 16
	}

	/// A stack entry, carrying the weight and depth of the value it holds.
	///
	/// The weight is what bounds aliasing. A memoized subtree re-fetched `k` times costs `k` times
	/// its size here, which is exactly what it costs a consumer walking the result — so a pickle that
	/// is small on disk but expands into millions of nodes is refused at construction rather than
	/// discovered by whatever traverses it later.
	private struct Slot {
		let value: PickleValue
		let nodes: Int
		let depth: Int
		/// For a dictionary, key → position, carried so `SETITEM` does not rebuild it.
		///
		/// Rebuilding the index per opcode is O(width) *hashes*, and a hash is proportional to the key,
		/// so a dictionary of long keys grown one at a time costs far more than the element copies
		/// ``Caps/containerWork`` charges for — tens of seconds while staying inside every limit.
		/// Carrying it makes the charge honest: the work really is the copy.
		let dictionaryIndex: [PickleValue: Int]

		init(_ value: PickleValue, nodes: Int = 1, depth: Int = 1, dictionaryIndex: [PickleValue: Int] = [:]) {
			self.value = value
			self.nodes = nodes
			self.depth = depth
			self.dictionaryIndex = dictionaryIndex
		}
	}

	/// What a decode actually cost, against the caps that bound it.
	///
	/// Exposed so the suite can assert the **floor** of every cap on the real checkpoints, not only
	/// its ceiling on a hostile one. A cap tested in one direction says nothing about whether it is
	/// about to start rejecting a file that matters.
	struct Statistics: Equatable {
		var opcodes = 0
		var memoEntries = 0
		var materializedNodes = 0
		var containerWork = 0
		var peakStackDepth = 0
		var peakNestingDepth = 0
		var peakMarks = 0
		var peakStringLength = 0
		var peakTensorRank = 0
	}

	static func decode(_ bytes: [UInt8]) throws -> PickleValue {
		try decodeWithStatistics(bytes).value
	}

	static func decodeWithStatistics(_ bytes: [UInt8]) throws -> (value: PickleValue, statistics: Statistics) {
		guard bytes.isEmpty == false else { throw PickleDecoderError.empty }
		guard bytes.count <= Caps.pickleBytes else { throw PickleDecoderError.capExceeded(.pickleBytes) }

		var machine = Machine(bytes: bytes)
		let value = try machine.run()
		return (value, machine.statistics)
	}

	private struct Machine {
		let bytes: [UInt8]
		var cursor = 0
		var stack: [Slot] = []
		var memo: [Int: Slot] = [:]
		var marks: [Int] = []
		var opcodeCount = 0
		var materializedNodes = 0
		var containerWork = 0
		var peakStackDepth = 0
		var peakNestingDepth = 0
		var peakMarks = 0
		var peakStringLength = 0
		var peakTensorRank = 0

		var statistics: Statistics {
			Statistics(
				opcodes: opcodeCount,
				memoEntries: memo.count,
				materializedNodes: materializedNodes,
				containerWork: containerWork,
				peakStackDepth: peakStackDepth,
				peakNestingDepth: peakNestingDepth,
				peakMarks: peakMarks,
				peakStringLength: peakStringLength,
				peakTensorRank: peakTensorRank
			)
		}

		init(bytes: [UInt8]) {
			self.bytes = bytes
		}

		mutating func run() throws -> PickleValue {
			try readProtocolHeader()
			while cursor < bytes.count {
				opcodeCount += 1
				guard opcodeCount <= Caps.opcodes else { throw PickleDecoderError.capExceeded(.opcodes) }
				let offset = cursor
				let opcode = bytes[cursor]
				cursor += 1
				if try step(opcode, at: offset) {
					// STOP. Anything after it was never part of the program.
					guard cursor == bytes.count else {
						throw PickleDecoderError.trailingBytes(count: bytes.count - cursor)
					}
					return try pop(opcode, at: offset).value
				}
				peakStackDepth = max(peakStackDepth, stack.count)
				guard stack.count <= Caps.stackDepth else { throw PickleDecoderError.capExceeded(.stackDepth) }
			}
			throw PickleDecoderError.truncated(atOffset: cursor)
		}

		/// `torch.save` writes protocol 2 and this decoder implements protocol 2. A protocol-4 pickle
		/// uses framing and opcodes that are not here, and would fail opcode by opcode with a
		/// confusing message; refusing it up front says the useful thing instead.
		private mutating func readProtocolHeader() throws {
			guard bytes.count >= 2, bytes[0] == 0x80 else {
				throw PickleDecoderError.missingProtocolHeader
			}
			let version = Int(bytes[1])
			guard version == 2 else { throw PickleDecoderError.unsupportedProtocol(version) }
			cursor = 2
		}

		/// Executes one opcode. Returns true for STOP.
		///
		/// Split three ways along a real seam in the opcode set rather than as one 29-case switch:
		private mutating func step(_ opcode: UInt8, at offset: Int) throws -> Bool {
			if opcode == 0x2E { return true }														// STOP
			if try stepLiteral(opcode, at: offset) { return false }
			if try stepMemo(opcode, at: offset) { return false }
			try stepStack(opcode, at: offset)
			return false
		}

		/// Opcodes that consume operand bytes and push one value. Nothing on the stack is read.
		private mutating func stepLiteral(_ opcode: UInt8, at offset: Int) throws -> Bool {
			switch opcode {
			case 0x4E: push(Slot(.none))															// NONE
			case 0x88: push(Slot(.bool(true)))														// NEWTRUE
			case 0x89: push(Slot(.bool(false)))														// NEWFALSE
			case 0x29: try pushContainer(.tuple([]), children: [])									// EMPTY_TUPLE
			case 0x5D: try pushContainer(.list([]), children: [])									// EMPTY_LIST
			case 0x7D: try pushContainer(.dictionary([]), children: [])								// EMPTY_DICT
			case 0x4B: push(Slot(.int(Int(try readByte(at: offset)))))								// BININT1
			case 0x4D: push(Slot(.int(Int(try readUInt16(at: offset)))))							// BININT2
			case 0x4A: push(Slot(.int(Int(try readInt32(at: offset)))))								// BININT
			case 0x47: push(Slot(.double(try readDouble(at: offset))))								// BINFLOAT
			case 0x58: push(Slot(.string(try readUnicode(at: offset))))								// BINUNICODE
			default: return false
			}
			return true
		}

		/// Memo traffic: the only opcodes that make a value appear twice, and therefore the only ones
		/// that can amplify work without adding bytes.
		private mutating func stepMemo(_ opcode: UInt8, at offset: Int) throws -> Bool {
			switch opcode {
			case 0x71: try memoize(Int(try readByte(at: offset)), opcode: opcode, at: offset)		// BINPUT
			case 0x72: try memoize(Int(try readUInt32(at: offset)), opcode: opcode, at: offset)		// LONG_BINPUT
			case 0x68: try recall(Int(try readByte(at: offset)))									// BINGET
			case 0x6A: try recall(Int(try readUInt32(at: offset)))									// LONG_BINGET
			default: return false
			}
			return true
		}

		/// Opcodes that transform what is already on the stack -- where every underflow and type
		/// confusion lives, and where the two object-producing transitions are.
		private mutating func stepStack(_ opcode: UInt8, at offset: Int) throws {
			switch opcode {
			case 0x28: try pushMark()																// MARK
			case 0x85: try makeTuple(count: 1, opcode: opcode, at: offset)							// TUPLE1
			case 0x86: try makeTuple(count: 2, opcode: opcode, at: offset)							// TUPLE2
			case 0x74: try makeTupleFromMark(opcode: opcode, at: offset)							// TUPLE
			case 0x61: try append(opcode: opcode, at: offset)										// APPEND
			case 0x65: try appendFromMark(opcode: opcode, at: offset)								// APPENDS
			case 0x73: try setItem(opcode: opcode, at: offset)										// SETITEM
			case 0x75: try setItemsFromMark(opcode: opcode, at: offset)								// SETITEMS
			case 0x63: try readGlobal(at: offset)													// GLOBAL
			case 0x52: try reduce(opcode: opcode, at: offset)										// REDUCE
			case 0x51: try persistentLoad(opcode: opcode, at: offset)								// BINPERSID
			case 0x62: try build(opcode: opcode, at: offset)										// BUILD
			default: throw PickleDecoderError.unsupportedOpcode(opcode, atOffset: offset)
			}
		}

		// MARK: - Stack, memo and marks

		private mutating func push(_ slot: Slot) {
			stack.append(slot)
		}

		/// Pushes a container, charging its whole subtree and checking its depth.
		private mutating func pushContainer(_ value: PickleValue, children: [Slot]) throws {
			guard children.count <= Caps.containerWidth else {
				throw PickleDecoderError.capExceeded(.containerWidth)
			}
			var nodes = 1
			var depth = 1
			for child in children {
				guard let sum = checkedSum(nodes, child.nodes) else {
					throw PickleDecoderError.capExceeded(.materializedNodes)
				}
				nodes = sum
				depth = max(depth, child.depth + 1)
			}
			guard depth <= Caps.nestingDepth else { throw PickleDecoderError.capExceeded(.nestingDepth) }
			peakNestingDepth = max(peakNestingDepth, depth)
			try charge(nodes)
			push(Slot(value, nodes: nodes, depth: depth))
		}

		/// Adds to the running total of materialised nodes.
		///
		/// Charged at every construction *and* at every memo re-fetch, so an aliased subtree costs its
		/// full weight each time it is referenced. That is the invariant that bounds the shape a
		/// 10 KB pickle can expand into — memory stays flat under copy-on-write while the logical tree
		/// does not, and a consumer walking the result pays for the logical tree.
		private mutating func charge(_ nodes: Int) throws {
			guard let total = checkedSum(materializedNodes, nodes), total <= Caps.materializedNodes else {
				throw PickleDecoderError.capExceeded(.materializedNodes)
			}
			materializedNodes = total
		}

		/// Charges the copy cost of rebuilding a container of `size` elements.
		///
		/// Growing a value-semantic container copies it, so a pickle's *cost* is not bounded by the
		/// size of anything it leaves behind: a dictionary grown one key at a time to the width cap
		/// does quadratic work while producing one ordinary dictionary. Metering the copies is the
		/// only counter that sees it.
		private mutating func chargeWork(_ size: Int) throws {
			guard let total = checkedSum(containerWork, size), total <= Caps.containerWork else {
				throw PickleDecoderError.capExceeded(.containerWork)
			}
			containerWork = total
		}

		private mutating func pop(_ opcode: UInt8, at offset: Int) throws -> Slot {
			guard let slot = stack.popLast() else {
				throw PickleDecoderError.stackUnderflow(opcode: opcode, atOffset: offset)
			}
			return slot
		}

		private mutating func pushMark() throws {
			guard marks.count < Caps.marks else { throw PickleDecoderError.capExceeded(.marks) }
			marks.append(stack.count)
			peakMarks = max(peakMarks, marks.count)
		}

		private mutating func popMark(opcode: UInt8, at offset: Int) throws -> [Slot] {
			guard let start = marks.popLast(), start <= stack.count else {
				throw PickleDecoderError.stackUnderflow(opcode: opcode, atOffset: offset)
			}
			let items = Array(stack[start...])
			stack.removeSubrange(start...)
			return items
		}

		private mutating func memoize(_ index: Int, opcode: UInt8, at offset: Int) throws {
			guard let slot = stack.last else {
				throw PickleDecoderError.stackUnderflow(opcode: opcode, atOffset: offset)
			}
			if memo[index] == nil {
				guard memo.count < Caps.memoEntries else { throw PickleDecoderError.capExceeded(.memoEntries) }
			}
			memo[index] = slot
		}

		private mutating func recall(_ index: Int) throws {
			guard let slot = memo[index] else { throw PickleDecoderError.invalidMemoReference(index) }
			try charge(slot.nodes)
			push(slot)
		}

		// MARK: - Containers

		private mutating func makeTuple(count: Int, opcode: UInt8, at offset: Int) throws {
			guard stack.count >= count else {
				throw PickleDecoderError.stackUnderflow(opcode: opcode, atOffset: offset)
			}
			let children = Array(stack.suffix(count))
			stack.removeLast(count)
			try pushContainer(.tuple(children.map(\.value)), children: children)
		}

		private mutating func makeTupleFromMark(opcode: UInt8, at offset: Int) throws {
			let children = try popMark(opcode: opcode, at: offset)
			try pushContainer(.tuple(children.map(\.value)), children: children)
		}

		private mutating func append(opcode: UInt8, at offset: Int) throws {
			let item = try pop(opcode, at: offset)
			let target = try pop(opcode, at: offset)
			guard case .list(let elements) = target.value else {
				throw PickleDecoderError.typeMismatch("APPEND onto a non-list", atOffset: offset)
			}
			try pushList(elements + [item.value], existing: target, added: [item])
		}

		private mutating func appendFromMark(opcode: UInt8, at offset: Int) throws {
			let items = try popMark(opcode: opcode, at: offset)
			let target = try pop(opcode, at: offset)
			guard case .list(let elements) = target.value else {
				throw PickleDecoderError.typeMismatch("APPENDS onto a non-list", atOffset: offset)
			}
			try pushList(elements + items.map(\.value), existing: target, added: items)
		}

		private mutating func pushList(_ elements: [PickleValue], existing: Slot, added: [Slot]) throws {
			guard elements.count <= Caps.containerWidth else {
				throw PickleDecoderError.capExceeded(.containerWidth)
			}
			try chargeWork(elements.count - added.count)
			var nodes = existing.nodes
			var depth = existing.depth
			for item in added {
				guard let sum = checkedSum(nodes, item.nodes) else {
					throw PickleDecoderError.capExceeded(.materializedNodes)
				}
				nodes = sum
				depth = max(depth, item.depth + 1)
			}
			guard depth <= Caps.nestingDepth else { throw PickleDecoderError.capExceeded(.nestingDepth) }
			try charge(added.reduce(0) { $0 + $1.nodes })
			push(Slot(.list(elements), nodes: nodes, depth: depth))
		}

		private mutating func setItem(opcode: UInt8, at offset: Int) throws {
			let value = try pop(opcode, at: offset)
			let key = try pop(opcode, at: offset)
			try setItems([(key, value)], opcode: opcode, at: offset)
		}

		private mutating func setItemsFromMark(opcode: UInt8, at offset: Int) throws {
			let items = try popMark(opcode: opcode, at: offset)
			guard items.count % 2 == 0 else {
				throw PickleDecoderError.typeMismatch("SETITEMS with an odd number of items", atOffset: offset)
			}
			var pairs: [(Slot, Slot)] = []
			pairs.reserveCapacity(items.count / 2)
			for index in stride(from: 0, to: items.count, by: 2) {
				pairs.append((items[index], items[index + 1]))
			}
			try setItems(pairs, opcode: opcode, at: offset)
		}

		private mutating func setItems(_ pairs: [(key: Slot, value: Slot)], opcode: UInt8, at offset: Int) throws {
			let target = try pop(opcode, at: offset)
			guard case .dictionary(let existing) = target.value else {
				throw PickleDecoderError.typeMismatch("SETITEM onto a non-dictionary", atOffset: offset)
			}
			try chargeWork(existing.count)
			var entries = existing
			var nodes = target.nodes
			var depth = target.depth
			// Inherited from the target rather than rebuilt: see `Slot.dictionaryIndex`. A rebuild here
			// re-hashes every existing key on every `SETITEM`, which is work proportional to key
			// *length* while `chargeWork` only meters element copies.
			var positions = target.dictionaryIndex
			for pair in pairs {
				// Insertion order is preserved and a repeated key replaces in place, which is what
				// Python does and what keeps a `state_dict`'s tensor order meaningful.
				if let position = positions[pair.key.value] {
					entries[position] = PickleEntry(key: pair.key.value, value: pair.value.value)
				} else {
					positions[pair.key.value] = entries.count
					entries.append(PickleEntry(key: pair.key.value, value: pair.value.value))
				}
				guard let withKey = checkedSum(nodes, pair.key.nodes),
					let sum = checkedSum(withKey, pair.value.nodes)
				else {
					throw PickleDecoderError.capExceeded(.materializedNodes)
				}
				nodes = sum
				depth = max(depth, pair.key.depth + 1, pair.value.depth + 1)
			}
			guard entries.count <= Caps.containerWidth else {
				throw PickleDecoderError.capExceeded(.containerWidth)
			}
			guard depth <= Caps.nestingDepth else { throw PickleDecoderError.capExceeded(.nestingDepth) }
			try charge(pairs.reduce(0) { $0 + $1.key.nodes + $1.value.nodes })
			push(Slot(.dictionary(entries), nodes: nodes, depth: depth, dictionaryIndex: positions))
		}

		// MARK: - The four globals, and the two things that may be done with them

		private mutating func readGlobal(at offset: Int) throws {
			let module = try readLine(at: offset)
			let name = try readLine(at: offset)
			guard let global = PickleGlobal.named(module: module, name: name) else {
				// Refused before it can reach the stack. This is the opcode that makes `torch.load`
				// arbitrary code execution, so the allow-list is the whole containment argument and
				// nothing outside it is tolerated, ignored, or deferred.
				//
				// The names are clamped because they are attacker-authored and this error is logged:
				// each may be up to `Caps.stringLength` bytes, which is a log-flood primitive for free.
				throw PickleDecoderError.forbiddenGlobal(
					module: Machine.clamped(module), name: Machine.clamped(name)
				)
			}
			push(Slot(.global(global)))
		}

		/// `REDUCE`, which in CPython means "call this callable".
		///
		/// Here it means neither call nor construct: it matches two exact shapes and produces the
		/// corresponding value. There is deliberately no default branch that does something generic,
		/// because a generic branch is the thing that would turn four allow-listed names into an
		/// attack surface.
		private mutating func reduce(opcode: UInt8, at offset: Int) throws {
			let arguments = try pop(opcode, at: offset)
			let callable = try pop(opcode, at: offset)
			guard case .global(let global) = callable.value else {
				throw PickleDecoderError.typeMismatch("REDUCE on a non-global", atOffset: offset)
			}
			guard case .tuple(let args) = arguments.value else {
				throw PickleDecoderError.typeMismatch("REDUCE without an argument tuple", atOffset: offset)
			}

			switch global {
			case .orderedDict:
				// Measured: called with no arguments, 934 times in ringfort and 4,726 in HRNet.
				guard args.isEmpty else {
					throw PickleDecoderError.unsupportedReduction("OrderedDict with \(args.count) arguments")
				}
				try pushContainer(.dictionary([]), children: [])

			case .rebuildTensorV2:
				// `children: [arguments]`, not `[]`. A tensor retains its whole argument subtree — two
				// dimension tuples that may each be thousands of elements — so charging it as a single
				// node would let one memoized tensor be recalled tens of thousands of times for a
				// weight of one apiece, and every later walk of the tensor table would pay for what the
				// cap never saw.
				let tensor = try rebuildTensor(args)
				peakTensorRank = max(peakTensorRank, tensor.shape.count)
				try pushContainer(.tensor(tensor), children: [arguments])

			case .storage:
				throw PickleDecoderError.unsupportedReduction("a storage type is not callable")
			}
		}

		/// `_rebuild_tensor_v2(storage, storage_offset, size, stride, requires_grad, backward_hooks)`.
		///
		/// Arity and types are measured, not guessed: 6 arguments, of types
		/// `(Storage, int, tuple, tuple, bool, dict)`, in every one of the 5,656 calls across the two
		/// real checkpoints. Anything else is refused rather than tolerated — an extra argument means
		/// a torch version this has not been checked against.
		private func rebuildTensor(_ args: [PickleValue]) throws -> PickleTensor {
			guard args.count == 6 else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 with \(args.count) arguments")
			}
			guard case .storage(let storage) = args[0] else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 without a storage")
			}
			guard case .int(let storageOffset) = args[1], storageOffset >= 0 else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 storage offset")
			}
			let shape = try dimensions(args[2], label: "size")
			let stride = try dimensions(args[3], label: "stride")
			guard shape.count == stride.count else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 rank disagreement")
			}
			// The shape's product must exist as an `Int`. Every dimension is attacker-chosen, and Swift's
			// `*` **traps** on overflow — a trap is a process abort, not a thrown error, so no `catch`
			// anywhere above can turn it into a refused import. Enforcing it here means no `PickleTensor`
			// can ever hold a shape whose product does not fit, which is what makes `elementCount` safe
			// for every consumer rather than safe only where somebody remembered to check.
			var elements = 1
			for dimension in shape {
				guard let next = checkedProduct(elements, dimension) else {
					throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 size overflows")
				}
				elements = next
			}
			guard case .bool(let requiresGrad) = args[4] else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 requires_grad")
			}
			// Backward hooks are callables. The real checkpoints always pass an empty OrderedDict, and
			// a non-empty one would mean the file wants code attached to a tensor.
			guard case .dictionary(let hooks) = args[5], hooks.isEmpty else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 with backward hooks")
			}
			return PickleTensor(
				storage: storage,
				storageOffset: storageOffset,
				shape: shape,
				stride: stride,
				requiresGrad: requiresGrad
			)
		}

		private func dimensions(_ value: PickleValue, label: String) throws -> [Int] {
			guard case .tuple(let items) = value else {
				throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 \(label) is not a tuple")
			}
			guard items.count <= Caps.tensorRank else {
				throw PickleDecoderError.capExceeded(.tensorRank)
			}
			return try items.map {
				guard case .int(let dimension) = $0, dimension >= 0 else {
					throw PickleDecoderError.unsupportedReduction("_rebuild_tensor_v2 \(label) element")
				}
				return dimension
			}
		}

		/// The persistent id torch writes for a storage: `("storage", <type>, key, location, numel)`.
		private mutating func persistentLoad(opcode: UInt8, at offset: Int) throws {
			// Retained as `children: [identifier]` below, for the same reason as a tensor: the storage
			// keeps the strings the identifier tuple carried.
			let identifier = try pop(opcode, at: offset)
			guard case .tuple(let fields) = identifier.value, fields.count == 5 else {
				throw PickleDecoderError.malformedPersistentID("expected a 5-tuple")
			}
			guard case .string(let tag) = fields[0], tag == "storage" else {
				throw PickleDecoderError.malformedPersistentID("not a storage")
			}
			guard case .global(.storage(let kind)) = fields[1] else {
				throw PickleDecoderError.malformedPersistentID("storage type is not an allowed global")
			}
			guard case .string(let key) = fields[2] else {
				throw PickleDecoderError.malformedPersistentID("storage key")
			}
			guard case .string(let location) = fields[3] else {
				throw PickleDecoderError.malformedPersistentID("storage location")
			}
			guard case .int(let elementCount) = fields[4], elementCount >= 0 else {
				throw PickleDecoderError.malformedPersistentID("storage element count")
			}
			try pushContainer(
				.storage(PickleStorage(kind: kind, key: key, location: location, elementCount: elementCount)),
				children: [identifier]
			)
		}

		/// `BUILD`, restricted to the one shape the real checkpoints use.
		///
		/// In CPython this calls `__setstate__` or updates `__dict__` — arbitrary graph mutation. Here
		/// the only permitted state is a dictionary whose sole key is `_metadata`, which is what torch
		/// attaches to a `state_dict` (a per-module `{'version': N}` map: 217 entries in ringfort,
		/// 1,541 in HRNet). It is validated and then discarded, because nothing downstream reads it.
		private mutating func build(opcode: UInt8, at offset: Int) throws {
			let state = try pop(opcode, at: offset)
			guard stack.isEmpty == false else {
				throw PickleDecoderError.stackUnderflow(opcode: opcode, atOffset: offset)
			}
			guard case .dictionary(let entries) = state.value else {
				throw PickleDecoderError.unsupportedBuild("state is not a dictionary")
			}
			for entry in entries {
				guard case .string("_metadata") = entry.key else {
					throw PickleDecoderError.unsupportedBuild("state carries a key other than _metadata")
				}
			}
			guard case .dictionary = stack[stack.count - 1].value else {
				throw PickleDecoderError.unsupportedBuild("BUILD onto something other than a dictionary")
			}
		}

		// MARK: - Operand reads

		private mutating func readByte(at offset: Int) throws -> UInt8 {
			guard cursor < bytes.count else { throw PickleDecoderError.truncated(atOffset: offset) }
			defer { cursor += 1 }
			return bytes[cursor]
		}

		private mutating func readUInt16(at offset: Int) throws -> UInt16 {
			guard bytes.count - cursor >= 2 else { throw PickleDecoderError.truncated(atOffset: offset) }
			defer { cursor += 2 }
			return UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
		}

		private mutating func readUInt32(at offset: Int) throws -> UInt32 {
			guard bytes.count - cursor >= 4 else { throw PickleDecoderError.truncated(atOffset: offset) }
			defer { cursor += 4 }
			return UInt32(bytes[cursor])
				| (UInt32(bytes[cursor + 1]) << 8)
				| (UInt32(bytes[cursor + 2]) << 16)
				| (UInt32(bytes[cursor + 3]) << 24)
		}

		private mutating func readInt32(at offset: Int) throws -> Int32 {
			Int32(bitPattern: try readUInt32(at: offset))
		}

		private mutating func readDouble(at offset: Int) throws -> Double {
			guard bytes.count - cursor >= 8 else { throw PickleDecoderError.truncated(atOffset: offset) }
			var pattern: UInt64 = 0
			// Big-endian: BINFLOAT is the one field pickle does not store little-endian.
			for index in 0..<8 {
				pattern = (pattern << 8) | UInt64(bytes[cursor + index])
			}
			cursor += 8
			return Double(bitPattern: pattern)
		}

		private mutating func readUnicode(at offset: Int) throws -> String {
			let length = Int(try readUInt32(at: offset))
			guard length <= Caps.stringLength else { throw PickleDecoderError.capExceeded(.stringLength) }
			guard bytes.count - cursor >= length else { throw PickleDecoderError.truncated(atOffset: offset) }
			let slice = Array(bytes[cursor..<(cursor + length)])
			cursor += length
			peakStringLength = max(peakStringLength, length)
			// Strict, for the same reason entry names are: `String(decoding:as:)` substitutes U+FFFD
			// and never fails, so two different byte sequences would collapse into one dictionary key
			// and a tensor would be lost rather than the file refused.
			guard let string = String(bytes: slice, encoding: .utf8) else {
				throw PickleDecoderError.notUTF8(atOffset: offset)
			}
			return string
		}

		/// Shortens attacker-authored text to something a log line can carry.
		///
		/// Nothing here reaches a user-visible string — the app renders only closed enums and bounded
		/// integers — but a diagnostic that interpolates an unbounded attacker value is still a way to
		/// flood a log from a file.
		static func clamped(_ text: String, to limit: Int = 64) -> String {
			text.count <= limit ? text : String(text.prefix(limit)) + "…"
		}

		/// A newline-terminated ASCII token, as `GLOBAL` uses.
		private mutating func readLine(at offset: Int) throws -> String {
			var line: [UInt8] = []
			while cursor < bytes.count {
				let byte = bytes[cursor]
				cursor += 1
				if byte == 0x0A {
					guard let string = String(bytes: line, encoding: .utf8) else {
						throw PickleDecoderError.notUTF8(atOffset: offset)
					}
					return string
				}
				guard line.count < Caps.stringLength else {
					throw PickleDecoderError.capExceeded(.stringLength)
				}
				line.append(byte)
			}
			throw PickleDecoderError.truncated(atOffset: offset)
		}
	}
}
