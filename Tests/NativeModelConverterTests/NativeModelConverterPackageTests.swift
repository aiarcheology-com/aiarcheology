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
}
