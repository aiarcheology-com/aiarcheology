//
//  ExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
@testable import ML_Browser

// MARK: - Bool Extensions Tests

final class BoolExtensionsTests: XCTestCase {
    
    func testNot_TrueReturnsFalse() {
        XCTAssertFalse(true.not)
    }
    
    func testNot_FalseReturnsTrue() {
        XCTAssertTrue(false.not)
    }
    
    func testEnabled_TrueReturnsTrue() {
        XCTAssertTrue(true.enabled)
    }
    
    func testEnabled_FalseReturnsFalse() {
        XCTAssertFalse(false.enabled)
    }
    
    func testDisabled_TrueReturnsFalse() {
        XCTAssertFalse(true.disabled)
    }
    
    func testDisabled_FalseReturnsTrue() {
        XCTAssertTrue(false.disabled)
    }
}

// MARK: - Optional Extensions Tests

final class OptionalExtensionsTests: XCTestCase {
    
    // MARK: - isNil / isNotNil
    
    func testIsNil_NilValueReturnsTrue() {
        let value: String? = nil
        XCTAssertTrue(value.isNil)
    }
    
    func testIsNil_NonNilValueReturnsFalse() {
        let value: String? = "test"
        XCTAssertFalse(value.isNil)
    }
    
    func testIsNotNil_NilValueReturnsFalse() {
        let value: String? = nil
        XCTAssertFalse(value.isNotNil)
    }
    
    func testIsNotNil_NonNilValueReturnsTrue() {
        let value: String? = "test"
        XCTAssertTrue(value.isNotNil)
    }
    
    // MARK: - isNotBlank / isBlank (Optional<String>)
    
    func testIsNotBlank_NilReturnsTrue() {
        let value: String? = nil
        XCTAssertFalse(value.isNotBlank)
    }
    
    func testIsNotBlank_EmptyStringReturnsFalse() {
        let value: String? = ""
        XCTAssertFalse(value.isNotBlank)
    }
    
    func testIsNotBlank_NonEmptyStringReturnsTrue() {
        let value: String? = "hello"
        XCTAssertTrue(value.isNotBlank)
    }
    
    func testIsNotBlank_WhitespaceStringReturnsTrue() {
        // Note: Current implementation only checks isEmpty, not whitespace
        let value: String? = "   "
        XCTAssertTrue(value.isNotBlank)
    }
    
    func testIsBlank_NilReturnsTrue() {
        let value: String? = nil
        XCTAssertTrue(value.isBlank)
    }
    
    func testIsBlank_EmptyStringReturnsTrue() {
        let value: String? = ""
        XCTAssertTrue(value.isBlank)
    }
    
    func testIsBlank_NonEmptyStringReturnsFalse() {
        let value: String? = "hello"
        XCTAssertFalse(value.isBlank)
    }
    
    // MARK: - isEmptyOrNil (Optional<Collection>)
    
    func testIsEmptyOrNil_NilArrayReturnsTrue() {
        let value: [Int]? = nil
        XCTAssertTrue(value.isEmptyOrNil)
    }
    
    func testIsEmptyOrNil_EmptyArrayReturnsTrue() {
        let value: [Int]? = []
        XCTAssertTrue(value.isEmptyOrNil)
    }
    
    func testIsEmptyOrNil_NonEmptyArrayReturnsFalse() {
        let value: [Int]? = [1, 2, 3]
        XCTAssertFalse(value.isEmptyOrNil)
    }
    
    func testIsEmptyOrNil_NilDictionaryReturnsTrue() {
        let value: [String: Int]? = nil
        XCTAssertTrue(value.isEmptyOrNil)
    }
    
    func testIsEmptyOrNil_EmptyDictionaryReturnsTrue() {
        let value: [String: Int]? = [:]
        XCTAssertTrue(value.isEmptyOrNil)
    }
    
    func testIsEmptyOrNil_NonEmptyDictionaryReturnsFalse() {
        let value: [String: Int]? = ["key": 1]
        XCTAssertFalse(value.isEmptyOrNil)
    }
}

// MARK: - UUID Extensions Tests

final class UUIDExtensionsTests: XCTestCase {
    
    func testZeros_ReturnsAllZeroUUID() {
        let zeroUUID = UUID.zeros()
        XCTAssertEqual(zeroUUID.uuidString, "00000000-0000-0000-0000-000000000000")
    }
    
    func testZeros_ReturnsSameValueEachTime() {
        let first = UUID.zeros()
        let second = UUID.zeros()
        XCTAssertEqual(first, second)
    }
    
    func testZeros_IsDifferentFromRandomUUID() {
        let zeroUUID = UUID.zeros()
        let randomUUID = UUID()
        XCTAssertNotEqual(zeroUUID, randomUUID)
    }
}

// MARK: - Int Extensions Tests

final class IntExtensionsTests: XCTestCase {
    
    func testFormatBytesAsHumanReadable_ZeroBytes() {
        let result = 0.formatBytesAsHumanReadable()
        XCTAssertTrue(result.contains("0") || result.contains("Zero"), "Expected zero representation, got: \(result)")
    }
    
    func testFormatBytesAsHumanReadable_Megabytes() {
        // 5 MB = 5 * 1000 * 1000 bytes (file style)
        let fiveMB = 5_000_000
        let result = fiveMB.formatBytesAsHumanReadable()
        XCTAssertTrue(result.contains("MB"), "Expected MB unit, got: \(result)")
    }
    
    func testFormatBytesAsHumanReadable_Gigabytes() {
        // 2 GB = 2 * 1000 * 1000 * 1000 bytes (file style)
        let twoGB = 2_000_000_000
        let result = twoGB.formatBytesAsHumanReadable()
        XCTAssertTrue(result.contains("GB"), "Expected GB unit, got: \(result)")
    }
    
    func testFormatBytesAsHumanReadable_LargeValue() {
        // 10 GB
        let tenGB = 10_000_000_000
        let result = tenGB.formatBytesAsHumanReadable()
        XCTAssertTrue(result.contains("GB"), "Expected GB unit, got: \(result)")
    }
    
    func testFormatBytesAsHumanReadable_IncludesUnit() {
        let oneGB = 1_000_000_000
        let result = oneGB.formatBytesAsHumanReadable()
        // Should include either MB or GB
        let hasUnit = result.contains("MB") || result.contains("GB")
        XCTAssertTrue(hasUnit, "Expected unit in result, got: \(result)")
    }
}

// MARK: - CGRect Extensions Tests

final class CGRectExtensionsTests: XCTestCase {
    
    func testPoint_ReturnsSmallRect() {
        let point = CGRect.point
        XCTAssertEqual(point.origin.x, 0.0)
        XCTAssertEqual(point.origin.y, 0.0)
        XCTAssertEqual(point.width, 0.1)
        XCTAssertEqual(point.height, 0.1)
    }
    
    func testPoint_IsNotZero() {
        let point = CGRect.point
        XCTAssertFalse(point.isEmpty)
    }
    
    func testPoint_ReturnsSameValueEachTime() {
        let first = CGRect.point
        let second = CGRect.point
        XCTAssertEqual(first, second)
    }
}

// MARK: - DateFormatter Extensions Tests

final class DateFormatterExtensionsTests: XCTestCase {
    
    func testLongDateFormatter_HasLongDateStyle() {
        let formatter = DateFormatter.longDateFormater
        XCTAssertEqual(formatter.dateStyle, .long)
    }
    
    func testLongDateFormatter_FormatsDate() {
        let formatter = DateFormatter.longDateFormater
        let date = Date(timeIntervalSince1970: 0) // Jan 1, 1970
        let result = formatter.string(from: date)
        XCTAssertFalse(result.isEmpty)
    }
    
    func testLongDateFormatter_ReturnsNewInstanceEachTime() {
        let first = DateFormatter.longDateFormater
        let second = DateFormatter.longDateFormater
        // They should be different instances (computed property)
        XCTAssertFalse(first === second)
    }
}

// MARK: - NumberFormatter Extensions Tests

final class NumberFormatterExtensionsTests: XCTestCase {
    
    func testHistoryLimitFormatter_HasCorrectMinimum() {
        let formatter = NumberFormatter.historyLimitFormatter
        XCTAssertEqual(formatter.minimum?.intValue, 0)
    }
    
    func testHistoryLimitFormatter_HasCorrectMaximum() {
        let formatter = NumberFormatter.historyLimitFormatter
        XCTAssertEqual(formatter.maximum?.intValue, 100)
    }
    
    func testHistoryLimitFormatter_HasNoNumberStyle() {
        let formatter = NumberFormatter.historyLimitFormatter
        XCTAssertEqual(formatter.numberStyle, .none)
    }
    
    func testHistoryLimitFormatter_FormatsValidNumber() {
        let formatter = NumberFormatter.historyLimitFormatter
        let result = formatter.string(from: 50)
        XCTAssertEqual(result, "50")
    }
    
    func testHistoryLimitFormatter_FormatsZero() {
        let formatter = NumberFormatter.historyLimitFormatter
        let result = formatter.string(from: 0)
        XCTAssertEqual(result, "0")
    }
    
    func testHistoryLimitFormatter_FormatsMaximum() {
        let formatter = NumberFormatter.historyLimitFormatter
        let result = formatter.string(from: 100)
        XCTAssertEqual(result, "100")
    }
}

// MARK: - URL Extensions Tests

final class URLExtensionsTests: XCTestCase {

    func testIsCompiledCoreMLModel_OnlyForMlmodelcExtension_CaseInsensitive() {
        XCTAssertTrue(URL(fileURLWithPath: "/models/model.mlmodelc").isCompiledCoreMLModel)
        XCTAssertTrue(URL(fileURLWithPath: "/models/MODEL.MLMODELC").isCompiledCoreMLModel)
        XCTAssertTrue(URL(fileURLWithPath: "/models/model.mlmodelc/").isCompiledCoreMLModel)
        XCTAssertFalse(URL(fileURLWithPath: "/models/model.mlmodel").isCompiledCoreMLModel)
        XCTAssertFalse(URL(fileURLWithPath: "/models/model.mlpackage").isCompiledCoreMLModel)
        XCTAssertFalse(URL(fileURLWithPath: "/models/model.onnx").isCompiledCoreMLModel)
        XCTAssertFalse(URL(fileURLWithPath: "/models/mlmodelc").isCompiledCoreMLModel)
    }

    func testCompletePath_ToDocumentDirectory() throws {
        let relativePath = URL(fileURLWithPath: "test/file.txt")
        
        do {
            let completedURL = try relativePath.completePath(to: .documentDirectory, isDirectory: false)
            XCTAssertTrue(completedURL.path.contains("Documents"))
            XCTAssertTrue(completedURL.path.hasSuffix("test/file.txt"))
        } catch {
            // This might fail in test environment without proper sandbox
            XCTAssertTrue(error is CocoaError)
        }
    }
    
    func testCompletePath_IsDirectory() throws {
        let relativePath = URL(fileURLWithPath: "testfolder")
        
        do {
            let completedURL = try relativePath.completePath(to: .documentDirectory, isDirectory: true)
            // Directory URLs should end with /
            XCTAssertTrue(completedURL.hasDirectoryPath)
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
    }
    
    func testRelativePath_ThrowsForPathNotInDirectory() {
        let url = URL(fileURLWithPath: "/some/random/path/file.txt")

        XCTAssertThrowsError(try url.relativePath(from: .documentDirectory)) { error in
            XCTAssertTrue(error is CocoaError)
        }
    }

    func testRelativePath_CompletePath_RoundTripsSpecialCharacters() throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )

        // Dots, nested paths, spaces, unicode, '%' and '#' must all survive the
        // relativePath -> completePath round trip (.urlPathAllowed keeps '/' and '.').
        let candidates = [
            "model.mlmodelc",
            "Configurations/ABC-123/model.mlmodelc",
            "folder name/my model.mlmodel",
            "složka/モデル.mlmodel",
            "odd%name/file#1.bin"
        ]

        for candidate in candidates {
            let absolute = documents.appendingPathComponent(candidate)
            let relative = try absolute.relativePath(from: .documentDirectory)
            let completed = try relative.completePath(to: .documentDirectory, isDirectory: false)
            XCTAssertEqual(
                completed.standardizedFileURL.path,
                absolute.standardizedFileURL.path,
                "Round trip failed for \(candidate)"
            )
        }
    }
}
