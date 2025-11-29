import XCTest
import UniformTypeIdentifiers

final class UTTypeTests: XCTestCase {
	
	func testCoreMLUTTypes() {
		// Test the identifier-based types
		let mlmodelType = UTType("com.apple.coreml.mlmodel")
		let mlpackageType = UTType("com.apple.coreml.mlpackage")
		
		print("com.apple.coreml.mlmodel: \(mlmodelType?.identifier ?? "nil")")
		print("com.apple.coreml.mlpackage: \(mlpackageType?.identifier ?? "nil")")
		
		// Test extension-based types
		let mlmodelExt = UTType(filenameExtension: "mlmodel")
		let mlpackageExt = UTType(filenameExtension: "mlpackage")
		let mlmodelcExt = UTType(filenameExtension: "mlmodelc")
		
		print("mlmodel extension: \(mlmodelExt?.identifier ?? "nil")")
		print("mlpackage extension: \(mlpackageExt?.identifier ?? "nil")")
		print("mlmodelc extension: \(mlmodelcExt?.identifier ?? "nil")")
		
		// Verify at least one works
		XCTAssertTrue(mlmodelType != nil || mlmodelExt != nil, "At least one mlmodel type should be valid")
		XCTAssertTrue(mlpackageType != nil || mlpackageExt != nil, "At least one mlpackage type should be valid")
	}
}
