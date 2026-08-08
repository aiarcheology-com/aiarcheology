//
//  HostPlatformTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
@testable import ML_Browser

// MARK: - HostPlatform Tests

@MainActor
final class HostPlatformTests: XCTestCase {
    
    // MARK: - Current Platform Tests
    
    func test_current_returnsValidPlatform() {
        let platform = HostPlatform.current
        
        let validPlatforms: [HostPlatform] = [.iOS, .iPadOS, .macViaCatalyst, .macDesignedForiPad]
        XCTAssertTrue(validPlatforms.contains(platform))
    }
    
    func test_current_returnsConsistentValue() {
        let first = HostPlatform.current
        let second = HostPlatform.current
        
        XCTAssertEqual(first, second)
    }
    
    // MARK: - isMac Tests
    
    func test_isMac_iOS_returnsFalse() {
        XCTAssertFalse(HostPlatform.iOS.isMac)
    }
    
    func test_isMac_iPadOS_returnsFalse() {
        XCTAssertFalse(HostPlatform.iPadOS.isMac)
    }
    
    func test_isMac_macViaCatalyst_returnsTrue() {
        XCTAssertTrue(HostPlatform.macViaCatalyst.isMac)
    }
    
    func test_isMac_macDesignedForiPad_returnsTrue() {
        XCTAssertTrue(HostPlatform.macDesignedForiPad.isMac)
    }
    
    // MARK: - isiPad Tests
    
    func test_isiPad_iOS_returnsFalse() {
        XCTAssertFalse(HostPlatform.iOS.isiPad)
    }
    
    func test_isiPad_iPadOS_returnsTrue() {
        XCTAssertTrue(HostPlatform.iPadOS.isiPad)
    }
    
    func test_isiPad_macViaCatalyst_returnsFalse() {
        XCTAssertFalse(HostPlatform.macViaCatalyst.isiPad)
    }
    
    func test_isiPad_macDesignedForiPad_returnsFalse() {
        XCTAssertFalse(HostPlatform.macDesignedForiPad.isiPad)
    }
    
    // MARK: - isiPhone Tests
    
    func test_isiPhone_iOS_returnsTrue() {
        XCTAssertTrue(HostPlatform.iOS.isiPhone)
    }
    
    func test_isiPhone_iPadOS_returnsFalse() {
        XCTAssertFalse(HostPlatform.iPadOS.isiPhone)
    }
    
    func test_isiPhone_macViaCatalyst_returnsFalse() {
        XCTAssertFalse(HostPlatform.macViaCatalyst.isiPhone)
    }
    
    func test_isiPhone_macDesignedForiPad_returnsFalse() {
        XCTAssertFalse(HostPlatform.macDesignedForiPad.isiPhone)
    }
    
    // MARK: - prefersContextMenuOverSwipe Tests
    
    func test_prefersContextMenuOverSwipe_iOS_returnsFalse() {
        XCTAssertFalse(HostPlatform.iOS.prefersContextMenuOverSwipe)
    }
    
    func test_prefersContextMenuOverSwipe_iPadOS_returnsTrue() {
        XCTAssertTrue(HostPlatform.iPadOS.prefersContextMenuOverSwipe)
    }
    
    func test_prefersContextMenuOverSwipe_macViaCatalyst_returnsTrue() {
        XCTAssertTrue(HostPlatform.macViaCatalyst.prefersContextMenuOverSwipe)
    }
    
    func test_prefersContextMenuOverSwipe_macDesignedForiPad_returnsTrue() {
        XCTAssertTrue(HostPlatform.macDesignedForiPad.prefersContextMenuOverSwipe)
    }
    
    // MARK: - supportsManageSubscriptionsSheet Tests

    func test_supportsManageSubscriptionsSheet_iOS_returnsTrue() {
        XCTAssertTrue(HostPlatform.iOS.supportsManageSubscriptionsSheet)
    }

    func test_supportsManageSubscriptionsSheet_iPadOS_returnsTrue() {
        XCTAssertTrue(HostPlatform.iPadOS.supportsManageSubscriptionsSheet)
    }

    /// StoreKit declares the sheet available on macCatalyst, and this target does not build
    /// Catalyst — so it must not inherit the iOS-on-Mac workaround untested.
    func test_supportsManageSubscriptionsSheet_macViaCatalyst_returnsTrue() {
        XCTAssertTrue(HostPlatform.macViaCatalyst.supportsManageSubscriptionsSheet)
    }

    /// The regression this guards: `storekitagent` rejects the manage-subscriptions request on
    /// iOS-on-Mac, and the SwiftUI modifier swallows the error, so the button did nothing.
    func test_supportsManageSubscriptionsSheet_macDesignedForiPad_returnsFalse() {
        XCTAssertFalse(HostPlatform.macDesignedForiPad.supportsManageSubscriptionsSheet)
    }

    // MARK: - Platform Property Consistency Tests

    func test_allPlatforms_haveMutuallyExclusiveDeviceTypes() {
        let platforms: [HostPlatform] = [.iOS, .iPadOS, .macViaCatalyst, .macDesignedForiPad]
        
        for platform in platforms {
            // Each platform should be exactly one of: iPhone, iPad, or Mac
            let deviceFlags = [platform.isiPhone, platform.isiPad, platform.isMac]
            let trueCount = deviceFlags.filter { $0 }.count
            
            XCTAssertEqual(trueCount, 1, "\(platform) should be exactly one device type")
        }
    }
    
    func test_onlyiOS_isPhone() {
        let platforms: [HostPlatform] = [.iOS, .iPadOS, .macViaCatalyst, .macDesignedForiPad]
        let phonePlatforms = platforms.filter { $0.isiPhone }
        
        XCTAssertEqual(phonePlatforms, [.iOS])
    }
    
    func test_onlyiPadOS_isPad() {
        let platforms: [HostPlatform] = [.iOS, .iPadOS, .macViaCatalyst, .macDesignedForiPad]
        let padPlatforms = platforms.filter { $0.isiPad }
        
        XCTAssertEqual(padPlatforms, [.iPadOS])
    }
    
    func test_macPlatforms_areBothMacVariants() {
        let platforms: [HostPlatform] = [.iOS, .iPadOS, .macViaCatalyst, .macDesignedForiPad]
        let macPlatforms = platforms.filter { $0.isMac }
        
        XCTAssertEqual(Set(macPlatforms), Set([.macViaCatalyst, .macDesignedForiPad]))
    }
}

// MARK: - HostPlatform Equatable Tests

final class HostPlatformEquatableTests: XCTestCase {
    
    func test_samePlatforms_areEqual() {
        XCTAssertEqual(HostPlatform.iOS, HostPlatform.iOS)
        XCTAssertEqual(HostPlatform.iPadOS, HostPlatform.iPadOS)
        XCTAssertEqual(HostPlatform.macViaCatalyst, HostPlatform.macViaCatalyst)
        XCTAssertEqual(HostPlatform.macDesignedForiPad, HostPlatform.macDesignedForiPad)
    }
    
    func test_differentPlatforms_areNotEqual() {
        XCTAssertNotEqual(HostPlatform.iOS, HostPlatform.iPadOS)
        XCTAssertNotEqual(HostPlatform.iOS, HostPlatform.macViaCatalyst)
        XCTAssertNotEqual(HostPlatform.iPadOS, HostPlatform.macDesignedForiPad)
    }
}
