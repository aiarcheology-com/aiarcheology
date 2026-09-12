import XCTest
import SwiftUI
import UIKit
@testable import ML_Browser

final class ColorExtensionsTests: XCTestCase {
	private struct RGBAComponents {
		let red: CGFloat
		let green: CGFloat
		let blue: CGFloat
		let alpha: CGFloat
	}

	private func rgba(_ color: Color, file: StaticString = #filePath, line: UInt = #line) -> RGBAComponents {
		let uiColor = UIColor(color)
		var red: CGFloat = 0
		var green: CGFloat = 0
		var blue: CGFloat = 0
		var alpha: CGFloat = 0
		XCTAssertTrue(uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "Failed to extract RGBA components from UIColor", file: file, line: line)

		func normalize(_ value: CGFloat) -> CGFloat {
			if value.isNaN || !value.isFinite { return 0 }
			// Some color conversions can yield 0...255-ish values. Normalize those.
			let normalized = value > 1 ? value / 255.0 : value
			return min(max(normalized, 0), 1)
		}

		return RGBAComponents(
			red: normalize(red),
			green: normalize(green),
			blue: normalize(blue),
			alpha: normalize(alpha)
		)
	}

	func testRGBInitializer_Normalizes255Scale() {
		let red: Int = 255, green: Int = 128, blue: Int = 0
		let result = rgba(Color(red: red, green: green, blue: blue, opacity: 0.5))
		XCTAssertEqual(result.red, 1.0, accuracy: 0.0001)
		XCTAssertEqual(result.green, 128.0 / 255.0, accuracy: 0.0001)
		XCTAssertEqual(result.blue, 0.0, accuracy: 0.0001)
		XCTAssertEqual(result.alpha, 0.5, accuracy: 0.0001)
	}

	func testRGBInitializer_ClampsOutOfRangeValues() {
		let red: Int = -10, green: Int = 300, blue: Int = 999
		let result = rgba(Color(red: red, green: green, blue: blue, opacity: -1))
		XCTAssertEqual(result.red, 0.0, accuracy: 0.0001)
		XCTAssertEqual(result.green, 1.0, accuracy: 0.0001)
		XCTAssertEqual(result.blue, 1.0, accuracy: 0.0001)
		XCTAssertEqual(result.alpha, 0.0, accuracy: 0.0001)
	}

	func testRGBInitializer_DefaultOpacityIsOne() {
		let red: Int = 0, green: Int = 0, blue: Int = 0
		let result = rgba(Color(red: red, green: green, blue: blue))
		XCTAssertEqual(result.red, 0.0, accuracy: 0.0001)
		XCTAssertEqual(result.green, 0.0, accuracy: 0.0001)
		XCTAssertEqual(result.blue, 0.0, accuracy: 0.0001)
		XCTAssertEqual(result.alpha, 1.0, accuracy: 0.0001)
	}

	// MARK: - Random Color Tests

	func testRandomColor_ProducesValidRGBAComponents() {
		let color = Color.random()
		let result = rgba(color)
		XCTAssertGreaterThanOrEqual(result.red, 0.0)
		XCTAssertLessThanOrEqual(result.red, 1.0)
		XCTAssertGreaterThanOrEqual(result.green, 0.0)
		XCTAssertLessThanOrEqual(result.green, 1.0)
		XCTAssertGreaterThanOrEqual(result.blue, 0.0)
		XCTAssertLessThanOrEqual(result.blue, 1.0)
		XCTAssertEqual(result.alpha, 1.0, accuracy: 0.0001)
	}

	func testRandomColor_RespectsCustomOpacity() {
		let color = Color.random(opacity: 0.5)
		let result = rgba(color)
		XCTAssertEqual(result.alpha, 0.5, accuracy: 0.0001)
	}

	func testRandomColor_CanBeConvertedToUIColorAndBack() {
		// This test ensures Color.random() works with Core Data archiving
		let originalColor = Color.random()
		let uiColor = UIColor(originalColor)

		// Archive and unarchive (simulates Core Data storage)
		guard let data = try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false),
			  let unarchivedUIColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
			XCTFail("Failed to archive/unarchive UIColor")
			return
		}

		let restoredColor = Color(unarchivedUIColor)
		let original = rgba(originalColor)
		let restored = rgba(restoredColor)

		XCTAssertEqual(original.red, restored.red, accuracy: 0.0001)
		XCTAssertEqual(original.green, restored.green, accuracy: 0.0001)
		XCTAssertEqual(original.blue, restored.blue, accuracy: 0.0001)
		XCTAssertEqual(original.alpha, restored.alpha, accuracy: 0.0001)
	}

	func testUIColorRandom_ProducesValidComponents() {
		let color = UIColor.random()
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
		XCTAssertGreaterThanOrEqual(red, 0.0)
		XCTAssertLessThanOrEqual(red, 1.0)
		XCTAssertGreaterThanOrEqual(green, 0.0)
		XCTAssertLessThanOrEqual(green, 1.0)
		XCTAssertGreaterThanOrEqual(blue, 0.0)
		XCTAssertLessThanOrEqual(blue, 1.0)
		XCTAssertEqual(alpha, 1.0, accuracy: 0.0001)
	}

	func testRandomColor_RespectsCustomRange() {
		// Test with custom range 0.0...0.5 (darker colors, as used in DeepConfiguration)
		let numSamples = 10
		for _ in 0..<numSamples {
			let color = Color.random(range: 0.0...0.5)
			let result = rgba(color)
			
			// All RGB components should be within the specified range
			XCTAssertGreaterThanOrEqual(result.red, 0.0, "Red component should be >= 0.0")
			XCTAssertLessThanOrEqual(result.red, 0.5, "Red component should be <= 0.5")
			XCTAssertGreaterThanOrEqual(result.green, 0.0, "Green component should be >= 0.0")
			XCTAssertLessThanOrEqual(result.green, 0.5, "Green component should be <= 0.5")
			XCTAssertGreaterThanOrEqual(result.blue, 0.0, "Blue component should be >= 0.0")
			XCTAssertLessThanOrEqual(result.blue, 0.5, "Blue component should be <= 0.5")
			XCTAssertEqual(result.alpha, 1.0, accuracy: 0.0001)
		}
	}

	func testUIColorRandom_RespectsCustomRange() {
		// Test UIColor.random() with custom range
		let numSamples = 10
		for _ in 0..<numSamples {
			let color = UIColor.random(range: 0.0...0.5)
			var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
			XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
			
			XCTAssertGreaterThanOrEqual(red, 0.0, "Red component should be >= 0.0")
			XCTAssertLessThanOrEqual(red, 0.5, "Red component should be <= 0.5")
			XCTAssertGreaterThanOrEqual(green, 0.0, "Green component should be >= 0.0")
			XCTAssertLessThanOrEqual(green, 0.5, "Green component should be <= 0.5")
			XCTAssertGreaterThanOrEqual(blue, 0.0, "Blue component should be >= 0.0")
			XCTAssertLessThanOrEqual(blue, 0.5, "Blue component should be <= 0.5")
			XCTAssertEqual(alpha, 1.0, accuracy: 0.0001)
		}
	}
}
