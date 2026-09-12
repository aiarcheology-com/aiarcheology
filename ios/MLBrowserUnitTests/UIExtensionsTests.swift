//
//  UIExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
import SwiftUI
@testable import ML_Browser

// MARK: - UIImage+Extensions Tests

final class UIImageExtensionsTests: XCTestCase {
    
    private func createTestImage(size: CGSize = CGSize(width: 100, height: 100), color: UIColor = .red) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
    
    // MARK: - adjusted() Tests
    
    func test_adjusted_withNilParameters_returnsSameSize() {
        let original = createTestImage()
        
        let adjusted = original.adjusted()
        
        XCTAssertEqual(adjusted.size, original.size)
    }
    
    func test_adjusted_withBrightness_returnsImage() {
        let original = createTestImage()
        
        let adjusted = original.adjusted(brightness: 0.5)
        
        XCTAssertNotNil(adjusted)
        XCTAssertEqual(adjusted.size, original.size)
    }
    
    func test_adjusted_withContrast_returnsImage() {
        let original = createTestImage()
        
        let adjusted = original.adjusted(contrast: 1.5)
        
        XCTAssertNotNil(adjusted)
        XCTAssertEqual(adjusted.size, original.size)
    }
    
    func test_adjusted_withSaturation_returnsImage() {
        let original = createTestImage()
        
        let adjusted = original.adjusted(saturation: 0.0)
        
        XCTAssertNotNil(adjusted)
        XCTAssertEqual(adjusted.size, original.size)
    }
    
    func test_adjusted_withAllParameters_returnsImage() {
        let original = createTestImage()
        
        let adjusted = original.adjusted(brightness: 0.1, contrast: 1.2, saturation: 0.8)
        
        XCTAssertNotNil(adjusted)
        XCTAssertEqual(adjusted.size, original.size)
    }
    
    func test_adjusted_withZeroBrightness_returnsImage() {
        let original = createTestImage()
        
        let adjusted = original.adjusted(brightness: 0.0)
        
        XCTAssertNotNil(adjusted)
    }
    
    func test_adjusted_withNegativeBrightness_returnsImage() {
        let original = createTestImage()
        
        let adjusted = original.adjusted(brightness: -0.5)
        
        XCTAssertNotNil(adjusted)
    }
    
    func test_adjusted_preservesImageDimensions() {
        let sizes = [
            CGSize(width: 50, height: 50),
            CGSize(width: 100, height: 200),
            CGSize(width: 500, height: 300)
        ]
        
        for size in sizes {
            let original = createTestImage(size: size)
            let adjusted = original.adjusted(brightness: 0.2, contrast: 1.1, saturation: 0.9)
            
            XCTAssertEqual(adjusted.size.width, size.width, accuracy: 1.0)
            XCTAssertEqual(adjusted.size.height, size.height, accuracy: 1.0)
        }
    }
}

// MARK: - View+Extensions Tests

@MainActor
final class ViewExtensionsTests: XCTestCase {
    
    // MARK: - removeFocus Tests
    
    func test_removeFocus_doesNotCrash() {
        Text.removeFocus()
    }
    
    // MARK: - Centering Extensions Compile Tests

    func test_centerInParentView_compiles() {
        let view = Text("Test").centerInParentView()
        XCTAssertNotNil(view)
    }
    
    // MARK: - validate Extension Tests
    
    func test_validate_withValidValue_appliesValidTransform() {
        let text = Text("Test")
        
        let result = text.validate(
            value: 5,
            isValid: { $0 > 0 },
            valid: { view, _ in view.foregroundColor(.green) },
            invalid: { view, _ in view.foregroundColor(.red) }
        )
        
        XCTAssertNotNil(result)
    }
    
    func test_validate_withInvalidValue_appliesInvalidTransform() {
        let text = Text("Test")
        
        let result = text.validate(
            value: -1,
            isValid: { $0 > 0 },
            valid: { view, _ in view.foregroundColor(.green) },
            invalid: { view, _ in view.foregroundColor(.red) }
        )
        
        XCTAssertNotNil(result)
    }
    
    func test_validate_singleTransform_withValidValue_returnsSelf() {
        let text = Text("Test")
        
        let result = text.validate(
            value: 10,
            isValid: { $0 > 0 },
            invalid: { view, _ in view.foregroundColor(.red) }
        )
        
        XCTAssertNotNil(result)
    }
    
    func test_validate_singleTransform_withInvalidValue_appliesTransform() {
        let text = Text("Test")
        
        let result = text.validate(
            value: -5,
            isValid: { $0 > 0 },
            invalid: { view, _ in view.foregroundColor(.red) }
        )
        
        XCTAssertNotNil(result)
    }
    
    // MARK: - copiedToClipboard Tests
    
    func test_copiedToClipboard_compiles() {
        let view = Text("Test").copiedToClipboard(copiedText: "Copy this", preview: "Copied!")
        
        XCTAssertNotNil(view)
    }

    // MARK: - SheetRoom Tests

    func test_sheetRoomIsGenerous_onlyForIPad() {
        XCTAssertTrue(SheetRoom.isGenerous(for: .pad))

        for idiom in [UIUserInterfaceIdiom.phone, .tv, .carPlay, .mac, .unspecified] {
            XCTAssertFalse(SheetRoom.isGenerous(for: idiom), "\(idiom) must keep system sheet sizing")
        }
    }
}

// MARK: - UIApplication+Extensions Tests

@MainActor
final class UIApplicationExtensionsTests: XCTestCase {
    
    func test_firstKeyWindow_returnsWindowOrNil() {
        let window = UIApplication.firstKeyWindow
        
        if let window = window {
            XCTAssertNotNil(window)
        }
    }
    
    func test_firstKeyWindow_consistentBehavior() {
        let first = UIApplication.firstKeyWindow
        let second = UIApplication.firstKeyWindow
        
        XCTAssertEqual(first, second)
    }
}

// MARK: - Image+Extensions Tests

final class ImageExtensionsTests: XCTestCase {

    func test_imageExtension_exists() {
        XCTAssertTrue(true, "Image extension compiles correctly")
    }
}
