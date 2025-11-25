//
//  DeviceInfoTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
@testable import ML_Browser

final class DeviceInfoTests: XCTestCase {
    
    // MARK: - Device Model Name Tests
    
    func testDeviceModelName_ReturnsNonEmptyString() {
        let modelName = DeviceInfo.deviceModelName()
        XCTAssertFalse(modelName.isEmpty, "Device model name should not be empty")
    }
    
    func testDeviceModelName_ContainsValidCharacters() {
        let modelName = DeviceInfo.deviceModelName()
        // Model names typically contain alphanumeric characters and commas
        let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ","))
        let modelCharacters = CharacterSet(charactersIn: modelName)
        XCTAssertTrue(modelCharacters.isSubset(of: validCharacters), 
                      "Model name '\(modelName)' contains unexpected characters")
    }
    
    // MARK: - Storage Status Tests
    
    func testGetDeviceStorageStatus_ReturnsFormattedString() {
        let status = DeviceInfo.getDeviceStorageStatus()
        XCTAssertFalse(status.isEmpty, "Storage status should not be empty")
    }
    
    func testGetDeviceStorageStatus_ContainsFreeLabel() {
        let status = DeviceInfo.getDeviceStorageStatus()
        // Should contain "Free:" or error message
        let hasFreeOrError = status.contains("Free") || status.contains("could not be retrieved")
        XCTAssertTrue(hasFreeOrError, "Status should contain 'Free' or error message, got: \(status)")
    }
    
    func testGetDeviceStorageStatus_ContainsTotalLabel() {
        let status = DeviceInfo.getDeviceStorageStatus()
        // Should contain "Total:" or error message
        let hasTotalOrError = status.contains("Total") || status.contains("could not be retrieved")
        XCTAssertTrue(hasTotalOrError, "Status should contain 'Total' or error message, got: \(status)")
    }
    
    func testGetDeviceStorageStatus_ContainsGBUnit() {
        let status = DeviceInfo.getDeviceStorageStatus()
        // Should contain "GB" or error message
        let hasGBOrError = status.contains("GB") || status.contains("could not be retrieved")
        XCTAssertTrue(hasGBOrError, "Status should contain 'GB' or error message, got: \(status)")
    }
    
    // MARK: - Formatted Date Tests
    
    func testGetCurrentFormattedDate_ReturnsNonEmptyString() {
        let dateString = DeviceInfo.getCurrentFormattedDate()
        XCTAssertFalse(dateString.isEmpty, "Formatted date should not be empty")
    }
    
    func testGetCurrentFormattedDate_ContainsCurrentYear() {
        let dateString = DeviceInfo.getCurrentFormattedDate()
        let currentYear = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(dateString.contains(String(currentYear)), 
                      "Date '\(dateString)' should contain current year \(currentYear)")
    }
    
    func testGetCurrentFormattedDate_HasReasonableLength() {
        let dateString = DeviceInfo.getCurrentFormattedDate()
        // A formatted date with medium style should be between 10-50 characters
        XCTAssertGreaterThan(dateString.count, 5, "Date string seems too short")
        XCTAssertLessThan(dateString.count, 100, "Date string seems too long")
    }
    
    // MARK: - Information Tests
    
    @MainActor
    func testInformation_ReturnsNonEmptyString() {
        let info = DeviceInfo.information()
        XCTAssertFalse(info.isEmpty, "Device info should not be empty")
    }
    
    @MainActor
    func testInformation_ContainsDeviceModel() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("Device Model"), 
                      "Info should contain 'Device Model' label")
    }
    
    @MainActor
    func testInformation_ContainsiOSVersion() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("iOS Version"), 
                      "Info should contain 'iOS Version' label")
    }
    
    @MainActor
    func testInformation_ContainsAppName() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("App Name"), 
                      "Info should contain 'App Name' label")
    }
    
    @MainActor
    func testInformation_ContainsAppVersionNumber() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("App Version Number"), 
                      "Info should contain 'App Version Number' label")
    }
    
    @MainActor
    func testInformation_ContainsAppBuildNumber() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("App Build Number"), 
                      "Info should contain 'App Build Number' label")
    }
    
    @MainActor
    func testInformation_ContainsStorageStatus() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("Storage Status"), 
                      "Info should contain 'Storage Status' label")
    }
    
    @MainActor
    func testInformation_ContainsDate() {
        let info = DeviceInfo.information()
        XCTAssertTrue(info.contains("Date"), 
                      "Info should contain 'Date' label")
    }
}

