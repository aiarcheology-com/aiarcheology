//
//  StringExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
@testable import ML_Browser

final class StringExtensionsTests: XCTestCase {
    
    // MARK: - withHTTPS Tests
    
    func testWithHTTPS_AlreadyHasHTTPS_ReturnsOriginal() {
        let input = "https://example.com"
        XCTAssertEqual(input.withHTTPS, "https://example.com")
    }
    
    func testWithHTTPS_AlreadyHasHTTP_ReturnsOriginal() {
        let input = "http://example.com"
        XCTAssertEqual(input.withHTTPS, "http://example.com")
    }
    
    func testWithHTTPS_NoScheme_PrependsHTTPS() {
        let input = "example.com"
        XCTAssertEqual(input.withHTTPS, "https://example.com")
    }
    
    func testWithHTTPS_PathOnly_PrependsHTTPS() {
        let input = "example.com/path/to/page"
        XCTAssertEqual(input.withHTTPS, "https://example.com/path/to/page")
    }
    
    func testWithHTTPS_EmptyString_PrependsHTTPS() {
        let input = ""
        XCTAssertEqual(input.withHTTPS, "https://")
    }
    
    // MARK: - browserInputType Tests
    
    func testBrowserInputType_EmptyString_ReturnsUnusable() {
        let input = ""
        XCTAssertEqual(input.browserInputType, .unusable)
    }
    
    func testBrowserInputType_OnlyWhitespace_ReturnsUnusable() {
        let input = "   \n\t  "
        XCTAssertEqual(input.browserInputType, .unusable)
    }
    
    func testBrowserInputType_ContainsSpaces_ReturnsSearchTerm() {
        let input = "how to cook pasta"
        XCTAssertEqual(input.browserInputType, .searchTerm)
    }
    
    func testBrowserInputType_ValidURLWithHTTPS_ReturnsURL() {
        let input = "https://www.google.com"
        XCTAssertEqual(input.browserInputType, .url)
    }
    
    func testBrowserInputType_ValidURLWithHTTP_ReturnsURL() {
        let input = "http://example.com"
        XCTAssertEqual(input.browserInputType, .url)
    }
    
    func testBrowserInputType_DomainWithoutScheme_ReturnsURL() {
        let input = "google.com"
        XCTAssertEqual(input.browserInputType, .url)
    }
    
    func testBrowserInputType_DomainWithPath_ReturnsURL() {
        let input = "example.com/path/to/page"
        XCTAssertEqual(input.browserInputType, .url)
    }
    
    func testBrowserInputType_SingleWord_ReturnsSearchTerm() {
        let input = "google"
        XCTAssertEqual(input.browserInputType, .searchTerm)
    }
    
    func testBrowserInputType_URLWithQueryParams_ReturnsURL() {
        let input = "https://example.com/search?q=test&page=1"
        XCTAssertEqual(input.browserInputType, .url)
    }
    
    func testBrowserInputType_SubdomainURL_ReturnsURL() {
        let input = "www.subdomain.example.com"
        XCTAssertEqual(input.browserInputType, .url)
    }
    
    func testBrowserInputType_LocalhostWithPort_ReturnsSearchTerm() {
        // localhost without a TLD-like suffix is treated as a search term
        let input = "localhost:8080"
        XCTAssertEqual(input.browserInputType, .searchTerm)
    }
    
    // MARK: - search(using:) Tests
    
    func testSearch_GoogleWithSearchTerm_ReturnsGoogleSearchURL() {
        let input = "swift programming"
        let result = input.search(using: .google)
        XCTAssertTrue(result.hasPrefix("https://www.google.com/search?q="))
        XCTAssertTrue(result.contains("swift"))
        XCTAssertTrue(result.contains("programming"))
    }
    
    func testSearch_BingWithSearchTerm_ReturnsBingSearchURL() {
        let input = "swift programming"
        let result = input.search(using: .bing)
        XCTAssertTrue(result.hasPrefix("https://www.bing.com/search?q="))
        XCTAssertTrue(result.contains("swift"))
    }
    
    func testSearch_GoogleWithURL_QuotesTheURL() {
        let input = "https://example.com"
        let result = input.search(using: .google)
        // URL should be quoted in the search
        XCTAssertTrue(result.contains("%22")) // URL-encoded quote
    }
    
    func testSearch_WithSpecialCharacters_EncodesCorrectly() {
        let input = "café & restaurants"
        let result = input.search(using: .google)
        XCTAssertTrue(result.hasPrefix("https://www.google.com/search?q="))
        // Should be URL encoded
        XCTAssertFalse(result.contains(" "))
    }
    
    // MARK: - SearchEngine Tests
    
    func testSearchEngine_GoogleSearchURL() {
        let url = SearchEngine.google.searchURL(for: "test")
        XCTAssertEqual(url, "https://www.google.com/search?q=test")
    }
    
    func testSearchEngine_BingSearchURL() {
        let url = SearchEngine.bing.searchURL(for: "test")
        XCTAssertEqual(url, "https://www.bing.com/search?q=test")
    }
    
    func testSearchEngine_EncodesSpaces() {
        let url = SearchEngine.google.searchURL(for: "hello world")
        XCTAssertTrue(url.contains("hello%20world"))
    }
    
    // MARK: - trimmedString Tests
    
    func testTrimmedString_RemovesLeadingWhitespace() {
        let input = "   hello"
        XCTAssertEqual(input.trimmedString, "hello")
    }
    
    func testTrimmedString_RemovesTrailingWhitespace() {
        let input = "hello   "
        XCTAssertEqual(input.trimmedString, "hello")
    }
    
    func testTrimmedString_RemovesEmptyLines() {
        let input = "hello\n\n\nworld"
        XCTAssertEqual(input.trimmedString, "hello\nworld")
    }
    
    func testTrimmedString_PreservesNonEmptyLines() {
        let input = "line1\nline2\nline3"
        XCTAssertEqual(input.trimmedString, "line1\nline2\nline3")
    }
    
    func testTrimmedString_EmptyString_ReturnsEmpty() {
        let input = ""
        XCTAssertEqual(input.trimmedString, "")
    }
    
    func testTrimmedString_OnlyWhitespace_ReturnsEmpty() {
        let input = "   \n\n   "
        XCTAssertEqual(input.trimmedString, "")
    }
    
    // MARK: - toDate Tests
    
    func testToDate_ISODate_ParsesCorrectly() {
        let input = "2023-12-25"
        let date = input.toDate(.isoDate)
        
        XCTAssertNotNil(date)
        
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: date!), 2023)
        XCTAssertEqual(calendar.component(.month, from: date!), 12)
        XCTAssertEqual(calendar.component(.day, from: date!), 25)
    }
    
    func testToDate_InvalidFormat_ReturnsNil() {
        let input = "not a date"
        let date = input.toDate(.isoDate)
        XCTAssertNil(date)
    }
    
    func testToDate_ISOYear_ParsesYear() {
        let input = "2023"
        let date = input.toDate(.isoYear)
        XCTAssertNotNil(date)
    }
    
    func testToDate_ISOYearMonth_ParsesYearMonth() {
        let input = "2023-07"
        let date = input.toDate(.isoYearMonth)
        XCTAssertNotNil(date)
    }
    
    func testToDate_LocalDateTimeSec_ParsesCorrectly() {
        let input = "2023-12-25 14:30:00"
        let date = input.toDate(.localDateTimeSec)
        XCTAssertNotNil(date)
    }
    
    // MARK: - fileName Tests
    
    func testFileName_WithExtension_ReturnsNameWithoutExtension() {
        let input = "/path/to/file.txt"
        XCTAssertEqual(input.fileName, "file")
    }
    
    func testFileName_WithMultipleDots_ReturnsCorrectName() {
        let input = "/path/to/file.name.txt"
        XCTAssertEqual(input.fileName, "file.name")
    }
    
    func testFileName_NoPath_ReturnsName() {
        let input = "file.txt"
        XCTAssertEqual(input.fileName, "file")
    }
    
    func testFileName_NoExtension_ReturnsFullName() {
        let input = "/path/to/filename"
        XCTAssertEqual(input.fileName, "filename")
    }
    
    // MARK: - fileExtension Tests
    
    func testFileExtension_WithExtension_ReturnsExtension() {
        let input = "/path/to/file.txt"
        XCTAssertEqual(input.fileExtension, "txt")
    }
    
    func testFileExtension_MLModel_ReturnsCorrectExtension() {
        let input = "/path/to/model.mlmodel"
        XCTAssertEqual(input.fileExtension, "mlmodel")
    }
    
    func testFileExtension_NoExtension_ReturnsEmpty() {
        let input = "/path/to/filename"
        XCTAssertEqual(input.fileExtension, "")
    }
    
    func testFileExtension_MultipleDots_ReturnsLastExtension() {
        let input = "/path/to/archive.tar.gz"
        XCTAssertEqual(input.fileExtension, "gz")
    }
    
    // MARK: - DateFormatType Tests
    
    func testDateFormatType_ISODate_HasCorrectFormat() {
        XCTAssertEqual(String.DateFormatType.isoDate.stringFormat, "yyyy-MM-dd")
    }
    
    func testDateFormatType_ISODateTime_HasCorrectFormat() {
        XCTAssertEqual(String.DateFormatType.isoDateTime.stringFormat, "yyyy-MM-dd'T'HH:mmZ")
    }
    
    func testDateFormatType_Custom_ReturnsCustomFormat() {
        let customFormat = "dd/MM/yyyy"
        XCTAssertEqual(String.DateFormatType.custom(customFormat).stringFormat, customFormat)
    }
    
    func testDateFormatType_CreateML_HasCorrectFormat() {
        XCTAssertEqual(String.DateFormatType.createMl.stringFormat, "yyyy-MM-dd'T'HH:mm:ss.SSS")
    }
}

// MARK: - BrowserInputType Equatable for testing

extension BrowserInpuType: Equatable {}

