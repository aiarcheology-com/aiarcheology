import XCTest
@testable import NativeModelConverter

final class NativeModelConverterPackageTests: XCTestCase {

	func testValidate_reluGraph_isConvertible() throws {
		let graph = try JSONDecoder().decode(NativeModelGraph.self, from: Data("""
		{
		  "formatVersion": 1,
		  "producer": { "name": "package-test", "version": "1.0.0" },
		  "inputs": [
		    { "name": "input", "dataType": "float32", "shape": [1, 3, 16, 16] }
		  ],
		  "weights": [],
		  "operations": [
		    {
		      "name": "relu",
		      "kind": "relu",
		      "inputs": ["input"],
		      "outputs": [
		        { "name": "output", "dataType": "float32", "shape": [1, 3, 16, 16] }
		      ],
		      "attributes": {}
		    }
		  ],
		  "outputs": ["output"]
		}
		""".utf8))

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertTrue(result.isConvertible, result.issues.map(\.localizedDescription).joined(separator: "\n"))
	}

	func testValidate_weightRangeOverflow_isRejected() {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1])],
			// offset + byteCount overflows UInt64. shape/type byte count still matches byteCount, so
			// this isolates the range-overflow issue from an invalidWeightByteCount issue.
			weights: [NativeModelWeight(name: "w", dataType: .float32, shape: [1], offset: .max - 3, byteCount: 4)],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertFalse(result.isConvertible)
		XCTAssertTrue(result.issues.contains(.overflowingWeightRange(name: "w")))
	}

	func testValidate_reservedMatrixMultiplicationReportsOneUnsupportedOperation() {
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.legacyFormatVersion,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "reserved-matmul",
					kind: .matrixMultiplication,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertEqual(
			result.issues.filter { $0 == .unsupportedOperation(operation: "reserved-matmul", kind: "matmul") }.count,
			1
		)
	}

	func testValidate_exactNDSliceRejectsNegativeBounds() {
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 3, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "slice",
					kind: .sliceND,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 3, 1])],
					attributes: [
						"beginIds": .integers([0, 0, -1]),
						"endIds": .integers([1, 3, -1]),
						"strides": .integers([1, 1, 1])
					]
				)
			],
			outputs: ["output"]
		)

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertFalse(result.isConvertible)
		XCTAssertTrue(result.issues.contains(
			.invalidAttribute(operation: "slice", attribute: "beginIds", expected: "3 non-negative integers")
		))
		XCTAssertTrue(result.issues.contains(
			.invalidAttribute(operation: "slice", attribute: "endIds", expected: "3 non-negative integers")
		))
	}
}
