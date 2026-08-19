//
//  PyTorchPickleDecoderTests.swift
//  NativeModelConverterTests
//
//  AIA-0666.
//

import XCTest
@testable import NativeModelConverter

/// Assembles pickle programs opcode by opcode, so a test says what it means.
struct PickleProgram {
	var bytes: [UInt8] = [0x80, 0x02]

	static func raw(_ bytes: [UInt8]) -> PickleProgram {
		var program = PickleProgram()
		program.bytes = bytes
		return program
	}

	mutating func op(_ byte: UInt8) { bytes.append(byte) }
	mutating func mark() { op(0x28) }
	mutating func none() { op(0x4E) }
	mutating func newTrue() { op(0x88) }
	mutating func newFalse() { op(0x89) }
	mutating func emptyTuple() { op(0x29) }
	mutating func emptyList() { op(0x5D) }
	mutating func emptyDict() { op(0x7D) }
	mutating func tuple() { op(0x74) }
	mutating func tuple1() { op(0x85) }
	mutating func tuple2() { op(0x86) }
	mutating func append() { op(0x61) }
	mutating func appends() { op(0x65) }
	mutating func setItem() { op(0x73) }
	mutating func setItems() { op(0x75) }
	mutating func reduce() { op(0x52) }
	mutating func persistentID() { op(0x51) }
	mutating func build() { op(0x62) }
	mutating func stop() { op(0x2E) }

	mutating func int1(_ value: UInt8) { op(0x4B); bytes.append(value) }
	mutating func int2(_ value: UInt16) { op(0x4D); bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
	mutating func int4(_ value: Int32) {
		op(0x4A)
		bytes += (0..<4).map { UInt8((UInt32(bitPattern: value) >> ($0 * 8)) & 0xFF) }
	}

	mutating func double(_ value: Double) {
		op(0x47)
		bytes += (0..<8).reversed().map { UInt8((value.bitPattern >> ($0 * 8)) & 0xFF) }
	}

	mutating func string(_ value: String) {
		let utf8 = Array(value.utf8)
		op(0x58)
		bytes += (0..<4).map { UInt8((UInt32(utf8.count) >> ($0 * 8)) & 0xFF) }
		bytes += utf8
	}

	/// A string whose declared length does not match what follows, for truncation tests.
	mutating func stringHeader(length: UInt32) {
		op(0x58)
		bytes += (0..<4).map { UInt8((length >> ($0 * 8)) & 0xFF) }
	}

	mutating func global(_ module: String, _ name: String) {
		op(0x63)
		bytes += Array(module.utf8) + [0x0A] + Array(name.utf8) + [0x0A]
	}

	mutating func put(_ index: UInt8) { op(0x71); bytes.append(index) }
	mutating func get(_ index: UInt8) { op(0x68); bytes.append(index) }
	mutating func longPut(_ index: UInt32) { op(0x72); bytes += (0..<4).map { UInt8((index >> ($0 * 8)) & 0xFF) } }
	mutating func longGet(_ index: UInt32) { op(0x6A); bytes += (0..<4).map { UInt8((index >> ($0 * 8)) & 0xFF) } }

	/// `("storage", <kind>, key, location, numel)` followed by BINPERSID.
	mutating func storage(kind: String = "FloatStorage", key: String, location: String = "cpu", count: UInt8) {
		mark()
		string("storage")
		global("torch", kind)
		string(key)
		string(location)
		int1(count)
		tuple()
		persistentID()
	}
}

final class PyTorchPickleDecoderTests: XCTestCase {

	// MARK: - The real pickles

	private func realPickle(_ id: String) throws -> [UInt8] {
		let archive = try PyTorchZipArchive.open(try ADAFFixtures.sparseBytes(id))
		let (_, entry) = try archive.torchPickleEntry()
		return try archive.bytes(of: entry, maximumByteCount: 8 * 1024 * 1024)
	}

	func test_theRealDetectionCheckpoint_decodes() throws {
		let value = try PyTorchPickleDecoder.decode(try realPickle("OD_ringfort"))
		let top = try XCTUnwrap(value.entries)

		XCTAssertEqual(top.map(\.key), [.string("epoch"), .string("state_dict"), .string("optimizer"),
									    .string("loss"), .string("start"), .string("id")])
		XCTAssertEqual(value["epoch"], .int(18))
		XCTAssertEqual(value["start"], .int(1_691_591_478))
		XCTAssertEqual(value["id"], .string("train_ringfort_OD_SLRM_512px pretrained_train_12_val_124"))

		let stateDict = try XCTUnwrap(value["state_dict"]?.entries)
		XCTAssertEqual(stateDict.count, 404)
		XCTAssertEqual(stateDict.first?.key, .string("backbone.body.conv1.weight"))
		guard case .tensor(let first)? = stateDict.first?.value else { return XCTFail("not a tensor") }
		XCTAssertEqual(first.shape, [64, 3, 7, 7])
		XCTAssertEqual(first.storage.kind, .float32)
		XCTAssertEqual(first.storageOffset, 0)
		XCTAssertEqual(first.requiresGrad, false)
	}

	func test_theRealSegmentationCheckpoint_decodes() throws {
		let value = try PyTorchPickleDecoder.decode(try realPickle("AO_HRNet"))
		XCTAssertEqual(value["id"], .string("train_AO_HRNet_SLRM_512px_pretrained_train_12_val_124_Transformation"))
		let stateDict = try XCTUnwrap(value["state_dict"]?.entries)
		XCTAssertEqual(stateDict.count, 1_964)
		XCTAssertEqual(stateDict.first?.key, .string("head.projection.0.weight"))
	}

	/// Every tensor in the real file, checked against the two invariants the checkpoint reader will
	/// rely on. Measured across all 404: no shared storages, every offset zero, `prod(shape)` equal to
	/// the storage's element count.
	func test_everyRealTensor_isContiguousAndUnshared() throws {
		let value = try PyTorchPickleDecoder.decode(try realPickle("OD_ringfort"))
		let stateDict = try XCTUnwrap(value["state_dict"]?.entries)
		var storageKeys = Set<String>()
		var totalParameters = 0

		for entry in stateDict {
			guard case .tensor(let tensor) = entry.value else { return XCTFail("\(entry.key) is not a tensor") }
			XCTAssertEqual(tensor.storageOffset, 0)
			XCTAssertTrue(storageKeys.insert(tensor.storage.key).inserted, "storage \(tensor.storage.key) is shared")
			let elements = tensor.shape.reduce(1, *)
			XCTAssertEqual(elements, tensor.storage.elementCount, "\(entry.key) does not fill its storage")
			totalParameters += elements
		}
		XCTAssertEqual(totalParameters, 43_315_482)
		XCTAssertEqual(storageKeys.count, 404)
	}

	/// The **floor** of every cap, measured on the real checkpoints.
	///
	/// A cap tested only against a hostile input says nothing about whether it is one change away
	/// from rejecting a file that matters — which is exactly how a cap sized from ringfort's 113,659
	/// bytes would have refused HRNet's 621,064. Each row here records what the real files actually
	/// cost and asserts the margin, so an inflated metric shows up as a failing test rather than as a
	/// refused import.
	func test_theRealPickles_costFarLessThanEveryCap() throws {
		let caps = PyTorchPickleDecoder.Caps.self
		let expected: [(id: String, bytes: Int, tensors: Int)] = [
			("OD_ringfort", 113_659, 404),
			("AO_HRNet", 621_064, 1_964)
		]

		for model in expected {
			let pickle = try realPickle(model.id)
			XCTAssertEqual(pickle.count, model.bytes)

			let (value, stats) = try PyTorchPickleDecoder.decodeWithStatistics(pickle)
			let stateDict = try XCTUnwrap(value["state_dict"]?.entries)
			XCTAssertEqual(stateDict.count, model.tensors)

			// Every cap must clear its observed cost by at least 16x. The multiplier is the point: a
			// margin of 2x is a cap waiting to reject the next model in the family.
			let margins: [(String, Int, Int)] = [
				("pickleBytes", pickle.count, caps.pickleBytes),
				("opcodes", stats.opcodes, caps.opcodes),
				("memoEntries", stats.memoEntries, caps.memoEntries),
				("materializedNodes", stats.materializedNodes, caps.materializedNodes),
				("containerWork", stats.containerWork, caps.containerWork),
				("stackDepth", stats.peakStackDepth, caps.stackDepth),
				("containerWidth", stateDict.count, caps.containerWidth),
				("nestingDepth", stats.peakNestingDepth, caps.nestingDepth),
				("stringLength", stats.peakStringLength, caps.stringLength),
				("tensorRank", stats.peakTensorRank, caps.tensorRank),
				("marks", stats.peakMarks, caps.marks)
			]
			for (name, observed, cap) in margins {
				// Tensor rank is deliberately the tight one: 4 observed against a cap of 16. Rank
				// multiplies the cost of every later walk of the tensor table, so a generous margin
				// here buys an attacker more than it buys a future model.
				let required = name == "tensorRank" ? 4 : 16
				XCTAssertGreaterThanOrEqual(
					cap, observed * required,
					"\(model.id): cap '\(name)' is \(cap) but \(model.id) already costs \(observed)"
				)
			}
		}
	}

	// MARK: - Nothing reaches code

	/// The opcode that makes `torch.load` arbitrary code execution.
	func test_aForbiddenGlobal_isRefusedRatherThanIgnored() {
		var program = PickleProgram()
		program.global("posix", "system")
		program.string("rm -rf /")
		program.tuple1()
		program.reduce()
		program.stop()
		assertThrows(program) {
			XCTAssertEqual($0, .forbiddenGlobal(module: "posix", name: "system"))
		}
	}

	func test_everyGlobalOutsideTheAllowList_isRefused() {
		let forbidden = [("builtins", "eval"), ("os", "popen"), ("subprocess", "Popen"),
						 ("torch", "HalfStorage"), ("torch._utils", "_rebuild_tensor"),
						 ("collections", "defaultdict"), ("numpy.core.multiarray", "_reconstruct")]
		for (module, name) in forbidden {
			var program = PickleProgram()
			program.global(module, name)
			program.stop()
			assertThrows(program) {
				XCTAssertEqual($0, .forbiddenGlobal(module: module, name: name), "\(module).\(name)")
			}
		}
	}

	func test_reduceOnAStorageType_isRefused() {
		var program = PickleProgram()
		program.global("torch", "FloatStorage")
		program.emptyTuple()
		program.reduce()
		program.stop()
		assertThrows(program) { guard case .unsupportedReduction = $0 else { return XCTFail("got \($0)") } }
	}

	func test_reduceOnANonGlobal_isRefused() {
		var program = PickleProgram()
		program.int1(1)
		program.emptyTuple()
		program.reduce()
		program.stop()
		assertThrows(program) { guard case .typeMismatch = $0 else { return XCTFail("got \($0)") } }
	}

	func test_aTensorCarryingBackwardHooks_isRefused() {
		// Backward hooks are callables; the real files always pass an empty OrderedDict.
		var program = PickleProgram()
		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: 4)
		program.int1(0)
		program.mark(); program.int1(4); program.tuple()
		program.mark(); program.int1(1); program.tuple()
		program.newFalse()
		program.emptyDict(); program.string("hook"); program.int1(1); program.setItem()
		program.tuple()
		program.reduce()
		program.stop()
		assertThrows(program) {
			XCTAssertEqual($0, .unsupportedReduction("_rebuild_tensor_v2 with backward hooks"))
		}
	}

	func test_aRebuildWithTheWrongArity_isRefused() {
		var program = PickleProgram()
		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: 4)
		program.int1(0)
		program.tuple()
		program.reduce()
		program.stop()
		assertThrows(program) {
			XCTAssertEqual($0, .unsupportedReduction("_rebuild_tensor_v2 with 2 arguments"))
		}
	}

	func test_aBuildCarryingAnythingButMetadata_isRefused() {
		var program = PickleProgram()
		program.emptyDict()
		program.emptyDict(); program.string("__reduce__"); program.int1(1); program.setItem()
		program.build()
		program.stop()
		assertThrows(program) { guard case .unsupportedBuild = $0 else { return XCTFail("got \($0)") } }
	}

	func test_aMalformedPersistentID_isRefused() {
		var program = PickleProgram()
		program.mark(); program.string("not-storage"); program.int1(1); program.tuple()
		program.persistentID()
		program.stop()
		assertThrows(program) { guard case .malformedPersistentID = $0 else { return XCTFail("got \($0)") } }
	}

	// MARK: - Cycles are unrepresentable

	/// The program that builds a self-referential list in CPython. Value semantics turn it into a
	/// two-node graph, so nothing downstream can loop on it. Pinned as a decision, not an accident.
	func test_theSelfReferentialListProgram_decodesToANestedEmptyListAndTerminates() throws {
		var program = PickleProgram()
		program.emptyList()
		program.put(0)
		program.get(0)
		program.append()
		program.stop()

		let value = try PyTorchPickleDecoder.decode(program.bytes)
		XCTAssertEqual(value, .list([.list([])]))
	}

	/// The price of the above, stated outright: pickle's memo is reference-semantic, so a container
	/// memoized before it is filled is re-fetched here in its empty state. CPython would yield
	/// `[[1], [1]]`.
	func test_aContainerMemoizedBeforeItIsPopulated_divergesFromCPython() throws {
		var program = PickleProgram()
		program.emptyList()
		program.put(0)
		program.int1(1)
		program.append()
		program.emptyList()
		program.get(0)
		program.append()
		program.stop()

		let value = try PyTorchPickleDecoder.decode(program.bytes)
		XCTAssertEqual(value, .list([.list([])]), """
			Documented divergence: the memo holds a copy taken at BINPUT, so the re-fetch sees the \
			list as it was, not as it became. If a real checkpoint ever depended on this, \
			test_theRealDetectionCheckpoint_decodes would fail first.
			""")
	}

	func test_deepNesting_isRefusedRatherThanRecursingOnRelease() {
		var program = PickleProgram()
		program.emptyTuple()
		for _ in 0..<10_000 { program.tuple1() }
		program.stop()
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.nestingDepth)) }
	}

	/// Flat memory, exponential logical size: each round doubles the referenced subtree without
	/// allocating one. The node charge is what notices.
	func test_aliasedSubtrees_areChargedEveryTimeTheyAreReferenced() {
		var program = PickleProgram()
		program.emptyList()
		program.put(0)
		for _ in 0..<40 {
			program.mark()
			program.get(0)
			program.get(0)
			program.appends()
			program.put(0)
		}
		program.stop()
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.materializedNodes)) }
	}

	/// A tensor keeps the weight of the arguments it was built from. Charging it as one node let a
	/// wide memoized shape be recalled thousands of times for nothing, and every later walk of the
	/// tensor table paid for what the cap never saw.
	func test_aMemoizedTensorRecalledManyTimes_isChargedEachTime() throws {
		var program = PickleProgram()
		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: 4)
		program.int1(0)
		program.mark(); program.int1(2); program.int1(2); program.tuple()
		program.mark(); program.int1(2); program.int1(1); program.tuple()
		program.newFalse()
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		program.tuple(); program.reduce()
		program.put(0)

		let (_, single) = try PyTorchPickleDecoder.decodeWithStatistics(program.bytes + [0x2E])
		var repeated = program
		repeated.emptyList()
		repeated.mark()
		for _ in 0..<50 { repeated.get(0) }
		repeated.appends()
		repeated.stop()
		let (_, many) = try PyTorchPickleDecoder.decodeWithStatistics(repeated.bytes)

		// What matters is the cost *per recall*, not the ratio of two whole programs: `single` already
		// includes the storage tuple, its strings and the empty hooks dict. Under the defect each
		// `BINGET` charged exactly 1 no matter how large the value it brought back.
		let perRecall = (many.materializedNodes - single.materializedNodes) / 50
		XCTAssertGreaterThanOrEqual(perRecall, 10,
									"a recalled tensor cost \(perRecall) nodes; charging it as 1 is the defect")
	}

	/// Rank is a multiplier on every later traversal of the tensor table, so it is capped tightly.
	/// Real tensors have rank 4.
	func test_aTensorWithAnAbsurdRank_isRefused() {
		var program = PickleProgram()
		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: 1)
		program.int1(0)
		program.mark()
		for _ in 0...PyTorchPickleDecoder.Caps.tensorRank { program.int1(1) }
		program.tuple()
		program.mark(); program.int1(1); program.tuple()
		program.newFalse()
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		program.tuple(); program.reduce()
		program.stop()
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.tensorRank)) }
	}

	/// The overflow that would abort the process rather than refuse the file.
	func test_aShapeWhoseProductOverflows_isRefusedByTheDecoder() {
		var program = PickleProgram()
		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: 1)
		program.int1(0)
		program.mark(); program.int4(2_147_483_647); program.int4(2_147_483_647); program.int4(2_147_483_647); program.tuple()
		program.mark(); program.int1(1); program.int1(1); program.int1(1); program.tuple()
		program.newFalse()
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		program.tuple(); program.reduce()
		program.stop()
		assertThrows(program) {
			XCTAssertEqual($0, .unsupportedReduction("_rebuild_tensor_v2 size overflows"))
		}
	}

	/// A forbidden global's name is attacker-authored and ends up in a logged error.
	func test_aForbiddenGlobalsNameIsClampedInTheError() {
		var program = PickleProgram()
		program.global(String(repeating: "m", count: 3_000), String(repeating: "n", count: 3_000))
		program.stop()
		assertThrows(program) { error in
			guard case .forbiddenGlobal(let module, let name) = error else { return XCTFail("got \(error)") }
			XCTAssertLessThanOrEqual(module.count, 65)
			XCTAssertLessThanOrEqual(name.count, 65)
		}
	}

	// MARK: - Caps

	/// A dictionary grown one key at a time. Nothing it produces is oversized — the result is an
	/// ordinary dictionary well inside the width cap — but each insertion copies the container, so the
	/// *work* is quadratic in the width. This is the cost that no size-based cap can see, and it is
	/// the difference between a refusal and a five-minute hang on import.
	func test_aDictionaryGrownOneKeyAtATime_isRefusedForItsCopyCost() {
		var program = PickleProgram()
		program.emptyDict()
		for index in 0..<12_000 {
			program.string("k\(index)")
			program.int1(1)
			program.setItem()
		}
		program.stop()
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.containerWork)) }
	}

	func test_aWideContainer_isRefused() {
		var program = PickleProgram()
		program.emptyList()
		program.mark()
		for _ in 0...PyTorchPickleDecoder.Caps.containerWidth { program.none() }
		program.appends()
		program.stop()
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.containerWidth)) }
	}

	func test_anOverlongString_isRefused() {
		var program = PickleProgram()
		program.stringHeader(length: UInt32(PyTorchPickleDecoder.Caps.stringLength + 1))
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.stringLength)) }
	}

	func test_aPickleLargerThanTheCap_isRefusedBeforeItIsParsed() {
		let bytes = [UInt8](repeating: 0x2E, count: PyTorchPickleDecoder.Caps.pickleBytes + 1)
		assertThrows(PickleProgram.raw(bytes)) { XCTAssertEqual($0, .capExceeded(.pickleBytes)) }
	}

	func test_tooManyMarks_isRefused() {
		var program = PickleProgram()
		for _ in 0...PyTorchPickleDecoder.Caps.marks { program.mark() }
		assertThrows(program) { XCTAssertEqual($0, .capExceeded(.marks)) }
	}

	// MARK: - Malformed programs

	func test_anEmptyInput_isRefused() {
		assertThrows(PickleProgram.raw([])) { XCTAssertEqual($0, .empty) }
	}

	func test_aMissingProtocolHeader_isRefused() {
		assertThrows(PickleProgram.raw([0x4E, 0x2E])) { XCTAssertEqual($0, .missingProtocolHeader) }
	}

	func test_protocolFour_isRefusedWithItsVersion() {
		assertThrows(PickleProgram.raw([0x80, 0x04, 0x2E])) { XCTAssertEqual($0, .unsupportedProtocol(4)) }
	}

	func test_anUnknownOpcode_namesTheByte() {
		var program = PickleProgram()
		program.op(0xFF)
		assertThrows(program) { XCTAssertEqual($0, .unsupportedOpcode(0xFF, atOffset: 2)) }
	}

	func test_bytesAfterStop_areRefused() {
		var program = PickleProgram()
		program.none()
		program.stop()
		program.op(0x4E)
		assertThrows(program) { XCTAssertEqual($0, .trailingBytes(count: 1)) }
	}

	func test_aProgramWithNoStop_isTruncated() {
		var program = PickleProgram()
		program.none()
		assertThrows(program) { guard case .truncated = $0 else { return XCTFail("got \($0)") } }
	}

	func test_anUnknownMemoIndex_isRefused() {
		var program = PickleProgram()
		program.get(7)
		program.stop()
		assertThrows(program) { XCTAssertEqual($0, .invalidMemoReference(7)) }
	}

	/// Stack underflow on every opcode that consumes operands — the family that would otherwise be a
	/// crash rather than a refusal.
	func test_everyConsumingOpcode_underflowsSafely() {
		let opcodes: [UInt8] = [0x2E, 0x85, 0x86, 0x74, 0x61, 0x65, 0x73, 0x75, 0x52, 0x51, 0x62, 0x71]
		for opcode in opcodes {
			var program = PickleProgram()
			program.op(opcode)
			if opcode == 0x71 { program.bytes.append(0) }
			XCTAssertThrowsError(try PyTorchPickleDecoder.decode(program.bytes), "opcode \(opcode)") { error in
				guard let error = error as? PickleDecoderError else { return XCTFail("\(error)") }
				switch error {
				case .stackUnderflow, .typeMismatch, .truncated: break
				default: XCTFail("opcode \(opcode) gave \(error)")
				}
			}
		}
	}

	func test_typeConfusionOnContainerOpcodes_isRefused() {
		for opcode: UInt8 in [0x61, 0x73] {
			var program = PickleProgram()
			program.int1(1)
			program.int1(2)
			program.int1(3)
			program.op(opcode)
			program.stop()
			assertThrows(program) { guard case .typeMismatch = $0 else { return XCTFail("opcode \(opcode): \($0)") } }
		}
	}

	func test_aTruncatedOperand_isRefusedForEveryLengthPrefixedOpcode() {
		let truncated: [[UInt8]] = [
			[0x80, 0x02, 0x4B],								// BININT1 with no byte
			[0x80, 0x02, 0x4D, 0x01],						// BININT2 with one byte
			[0x80, 0x02, 0x4A, 0x01, 0x02],					// BININT with two bytes
			[0x80, 0x02, 0x47, 0x00],						// BINFLOAT with one byte
			[0x80, 0x02, 0x58, 0x04, 0x00, 0x00, 0x00, 0x41],	// BINUNICODE claiming 4, giving 1
			[0x80, 0x02, 0x63, 0x74, 0x6F, 0x72, 0x63, 0x68]	// GLOBAL with no newline
		]
		for bytes in truncated {
			assertThrows(PickleProgram.raw(bytes)) {
				guard case .truncated = $0 else { return XCTFail("\(bytes) gave \($0)") }
			}
		}
	}

	func test_invalidUTF8InAString_isRefusedRatherThanReplaced() {
		// 0xFF is never valid UTF-8. Substituting U+FFFD would let two distinct names collide.
		let bytes: [UInt8] = [0x80, 0x02, 0x58, 0x02, 0x00, 0x00, 0x00, 0xFF, 0xFE, 0x2E]
		assertThrows(PickleProgram.raw(bytes)) { guard case .notUTF8 = $0 else { return XCTFail("got \($0)") } }
	}

	// MARK: - Truncation and mutation of the real pickle

	/// Every truncation of a real checkpoint's pickle must be refused, never accepted and never a
	/// crash. Sampled rather than exhaustive: 113,659 prefixes is billions of opcode transitions and
	/// would be the kind of gate that quietly gets disabled.
	func test_truncatingTheRealPickleAtAnyPoint_isAlwaysRefused() throws {
		let pickle = try realPickle("OD_ringfort")
		var checked = 0
		for length in stride(from: 0, to: pickle.count, by: 149) {
			checked += 1
			XCTAssertThrowsError(try PyTorchPickleDecoder.decode(Array(pickle.prefix(length))),
								 "prefix of \(length) bytes decoded")
		}
		XCTAssertGreaterThan(checked, 700, "the sweep should cover the whole pickle")
	}

	/// Deterministic single-byte mutations of a real pickle: each must decode or throw, and none may
	/// crash, hang or trip an assertion. The seed and stride are fixed so a failure is reproducible.
	func test_mutatingTheRealPickle_neverCrashes() throws {
		let pickle = try realPickle("OD_ringfort")
		var generator = SplitMix64(seed: 0x0666_ADAF_0666_ADAF)
		var decoded = 0
		var refused = 0

		for _ in 0..<600 {
			var mutated = pickle
			let position = Int(generator.next() % UInt64(mutated.count))
			mutated[position] ^= UInt8(generator.next() % 255 + 1)
			do {
				_ = try PyTorchPickleDecoder.decode(mutated)
				decoded += 1
			} catch is PickleDecoderError {
				refused += 1
			} catch {
				XCTFail("mutation at \(position) threw an unexpected error type: \(error)")
			}
		}
		XCTAssertEqual(decoded + refused, 600)
		XCTAssertGreaterThan(refused, 0, "a mutation sweep that refuses nothing is not testing anything")
	}

	// MARK: - Helpers

	private func assertThrows(
		_ program: PickleProgram,
		file: StaticString = #filePath,
		line: UInt = #line,
		_ check: (PickleDecoderError) -> Void
	) {
		XCTAssertThrowsError(try PyTorchPickleDecoder.decode(program.bytes), file: file, line: line) { error in
			guard let error = error as? PickleDecoderError else {
				return XCTFail("unexpected error type: \(error)", file: file, line: line)
			}
			check(error)
		}
	}
}

/// A tiny deterministic generator, so the fuzz corpus is reproducible from its seed.
private struct SplitMix64 {
	private var state: UInt64

	init(seed: UInt64) { state = seed }

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

extension PickleValue {
	/// The entries of a dictionary value, for tests that read a decoded checkpoint.
	var entries: [PickleEntry]? {
		guard case .dictionary(let entries) = self else { return nil }
		return entries
	}

	subscript(key: String) -> PickleValue? {
		entries?.first { $0.key == .string(key) }?.value
	}
}
