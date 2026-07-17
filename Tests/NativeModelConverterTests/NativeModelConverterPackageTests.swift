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
}
