//
//  TargetingCoordinatorTests.swift
//  AI ArcheologyTests
//
//  Identity-driven ConfigCat targeting (AIA-0115).
//

import Combine
import XCTest
@testable import ML_Browser

@MainActor
final class TargetingCoordinatorTests: XCTestCase {

	private var suiteName: String!
	private var defaults: UserDefaults!
	private var gateSubject: CurrentValueSubject<AuthGate, Never>!
	private var subscribedSubject: CurrentValueSubject<Bool, Never>!
	private var userID: String?
	private var isSignedIn = false
	private var subscribed = false

	override func setUp() async throws {
		try await super.setUp()
		suiteName = "TargetingCoordinatorTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
		gateSubject = CurrentValueSubject(.checkingSession)
		subscribedSubject = CurrentValueSubject(false)
		userID = nil
		isSignedIn = false
		subscribed = false
	}

	override func tearDown() async throws {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		try await super.tearDown()
	}

	/// Records set/clear calls; static snapshot values otherwise.
	private final class RecordingFlagProvider: FeatureFlagProviding, @unchecked Sendable {
		enum Call: Equatable {
			case set(id: String, custom: [String: String])
			case clear
		}
		private let lock = NSLock()
		private var _calls: [Call] = []
		var calls: [Call] {
			lock.lock(); defer { lock.unlock() }
			return _calls
		}
		private(set) var refreshCount = 0

		func currentSnapshot() -> FeatureFlagSnapshot { FeatureFlagSnapshot() }
		func refresh() async {
			refreshCount += 1
		}
		func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
		func setUser(id: String, custom: [String: String]) {
			lock.lock(); _calls.append(.set(id: id, custom: custom)); lock.unlock()
		}
		func clearUser() {
			lock.lock(); _calls.append(.clear); lock.unlock()
		}
	}

	private func makeSUT(provider: RecordingFlagProvider) -> (TargetingCoordinator, MessageCenterState) {
		let flags = FeatureFlagsState(provider: provider)
		let center = MessageCenterState(
			featureFlags: flags,
			userContext: { [weak self] in (self?.userID, self?.isSignedIn ?? false) },
			serverRepliedIDs: { [] },
			defaults: defaults,
			foregroundNotification: Notification.Name("TargetingCoordinatorTests.foreground")
		)
		let coordinator = TargetingCoordinator(
			identity: { [weak self] in (self?.userID, self?.isSignedIn ?? false) },
			isSubscribed: { [weak self] in self?.subscribed ?? false },
			authGateChanges: gateSubject.eraseToAnyPublisher(),
			subscriptionChanges: subscribedSubject.eraseToAnyPublisher(),
			provider: provider,
			featureFlags: flags,
			messageCenter: center,
			defaults: defaults,
			appVersion: "1.5.0",
			localeIdentifier: "en_US"
		)
		return (coordinator, center)
	}

	func test_seed_signedOut_clearsUserAndContext() {
		let provider = RecordingFlagProvider()
		let (coordinator, _) = makeSUT(provider: provider)
		_ = coordinator

		XCTAssertEqual(provider.calls, [.clear])
		XCTAssertNil(defaults.data(forKey: TargetingCoordinator.contextDefaultsKey))
	}

	func test_signIn_setsUserWithAttributes_andPersistsContext() throws {
		let provider = RecordingFlagProvider()
		let (coordinator, _) = makeSUT(provider: provider)
		_ = coordinator

		userID = "user_abc"
		isSignedIn = true
		subscribed = true
		gateSubject.send(.ready)

		guard case let .set(id, custom)? = provider.calls.last else {
			return XCTFail("expected a set call, got \(provider.calls)")
		}
		XCTAssertEqual(id, "user_abc")
		XCTAssertEqual(custom, [
			"appVersion": "1.5.0", "platform": "iOS", "locale": "en_US", "subscribed": "true"
		])

		let data = try XCTUnwrap(defaults.data(forKey: TargetingCoordinator.contextDefaultsKey))
		let context = try JSONDecoder().decode(TargetingCoordinator.Context.self, from: data)
		XCTAssertEqual(context.id, "user_abc")
	}

	func test_signOut_clearsUserAndPersistedContext() {
		let provider = RecordingFlagProvider()
		let (coordinator, _) = makeSUT(provider: provider)
		_ = coordinator

		userID = "user_abc"
		isSignedIn = true
		gateSubject.send(.ready)
		XCTAssertNotNil(defaults.data(forKey: TargetingCoordinator.contextDefaultsKey))

		userID = nil
		isSignedIn = false
		gateSubject.send(.signedOut)

		XCTAssertEqual(provider.calls.last, .clear)
		XCTAssertNil(defaults.data(forKey: TargetingCoordinator.contextDefaultsKey))
	}

	/// Subscription entitlement moves independently of the auth gate and must retarget too.
	func test_subscriptionChange_retargetsWithUpdatedAttribute() {
		let provider = RecordingFlagProvider()
		let (coordinator, _) = makeSUT(provider: provider)
		_ = coordinator

		userID = "user_abc"
		isSignedIn = true
		gateSubject.send(.ready)

		subscribed = true
		subscribedSubject.send(true)

		guard case let .set(_, custom)? = provider.calls.last else {
			return XCTFail("expected a set call, got \(provider.calls)")
		}
		XCTAssertEqual(custom["subscribed"], "true")
	}

	/// Review finding #2 (the mainline flow): sign-in must re-run message visibility immediately —
	/// an interactive message becomes presentable without waiting for a config change or foreground.
	func test_signIn_reevaluatesMessageVisibility_withoutConfigChange() {
		let provider = RecordingFlagProvider()
		// Note: the provider serves NO message payload changes; visibility flips on identity alone.
		let json = #"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"buttons":[{"id":"ok","label":"OK"}]}]"#
		let flags = FeatureFlagsState(provider: StaticFeatureFlagProvider(
			overrides: [.isAppMessagingEnabled: true], appMessagesJSON: json
		))
		let center = MessageCenterState(
			featureFlags: flags,
			userContext: { [weak self] in (self?.userID, self?.isSignedIn ?? false) },
			serverRepliedIDs: { [] },
			defaults: defaults,
			foregroundNotification: Notification.Name("TargetingCoordinatorTests.foreground")
		)
		let coordinator = TargetingCoordinator(
			identity: { [weak self] in (self?.userID, self?.isSignedIn ?? false) },
			isSubscribed: { false },
			authGateChanges: gateSubject.eraseToAnyPublisher(),
			subscriptionChanges: subscribedSubject.eraseToAnyPublisher(),
			provider: provider,
			featureFlags: flags,
			messageCenter: center,
			defaults: defaults
		)
		_ = coordinator

		XCTAssertNil(center.nextMessage(for: .inApp), "signed out: interactive hidden")

		userID = "user_abc"
		isSignedIn = true
		gateSubject.send(.ready)

		XCTAssertEqual(center.nextMessage(for: .inApp)?.id, "m1",
					   "sign-in re-evaluates visibility with no config change involved")

		userID = nil
		isSignedIn = false
		gateSubject.send(.signedOut)
		XCTAssertNil(center.nextMessage(for: .inApp), "sign-out hides interactive again")
	}
}
