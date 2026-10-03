//
//  AuthProviderSelectionTests.swift
//  MLBrowserUnitTests
//
//  The DEBUG choice between the mock and the real Clerk provider (AIA-0984).
//

#if DEBUG
import XCTest
@testable import ML_Browser

final class AuthProviderSelectionTests: XCTestCase {

	private let key = "pk_test_placeholder"

	private func select(
		uiTests: Bool = false,
		anyTests: Bool = false,
		realAuth: Bool = false,
		key: String? = nil,
		environment: BackendEnvironment = .development
	) -> DependencyContainer.AuthProviderSelection {
		DependencyContainer.authProviderSelection(
			isRunningUITests: uiTests,
			isRunningUnderAnyTests: anyTests,
			realAuthRequested: realAuth,
			publishableKey: key ?? self.key,
			environment: environment
		)
	}

	// MARK: - Unchanged rules

	func test_aUITest_usesTheMock_byDefault() {
		XCTAssertEqual(select(uiTests: true), .mock)
	}

	func test_unitTests_useTheMock() {
		XCTAssertEqual(select(anyTests: true), .mock)
	}

	func test_aKeylessDebugRun_usesTheMock() {
		XCTAssertEqual(select(key: ""), .mock)
	}

	func test_aKeyedDebugRun_usesClerk() {
		XCTAssertEqual(select(), .real)
	}

	// MARK: - The UI-test opt-in

	func test_aUITest_thatRequestsRealAuth_usesClerk() {
		XCTAssertEqual(select(uiTests: true, realAuth: true), .real)
	}

	/// The request is weighed before the keyless rule: without a key it must refuse, never fall
	/// back to the mock and pass on the wrong provider.
	func test_aRealAuthRequest_withoutAKey_isRefused() {
		guard case .refused = select(uiTests: true, realAuth: true, key: "") else {
			return XCTFail("a keyless build must refuse real auth, not fall back to the mock")
		}
	}

	func test_aRealAuthRequest_offDevelopment_isRefused() {
		guard case .refused = select(uiTests: true, realAuth: true, environment: .production) else {
			return XCTFail("real auth in a UI test is development only")
		}
	}

	/// Only a UI test can ask: the flag reaches the app through the UI-test launch configuration.
	func test_aRealAuthRequest_outsideAUITest_changesNothing() {
		XCTAssertEqual(select(anyTests: true, realAuth: true), .mock)
		XCTAssertEqual(select(realAuth: true, key: ""), .mock)
	}
}
#endif
