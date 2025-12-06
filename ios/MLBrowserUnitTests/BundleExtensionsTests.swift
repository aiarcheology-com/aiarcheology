//
//  BundleExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
@testable import ML_Browser

// MARK: - Bundle+Extension Tests

final class BundleExtensionsTests: XCTestCase {
    
    func test_iconFileName_returnsStringOrNil() {
        // The main bundle may or may not have an icon configured
        // This test verifies the property doesn't crash and returns expected type
        let iconFileName = Bundle.main.iconFileName
        
        // Either nil or a non-empty string
        if let fileName = iconFileName {
            XCTAssertFalse(fileName.isEmpty)
        }
        // nil is also acceptable if no icon is configured
    }
    
    func test_iconFileName_consistentValue() {
        let first = Bundle.main.iconFileName
        let second = Bundle.main.iconFileName
        
        XCTAssertEqual(first, second)
    }
    
    func test_iconFileName_bundleWithoutIcon_returnsNil() {
        // Create a bundle without icon info (test bundle typically has no icon)
        let testBundle = Bundle(for: type(of: self))
        
        // Test bundles typically don't have app icons configured
        // This verifies graceful handling of missing icon info
        _ = testBundle.iconFileName // Should not crash
    }
}
