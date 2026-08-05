//
//  FreeAccessAnchorService.swift
//  AI Archeology
//
//  Durable storage and reconciliation for the free-access anchor (AIA-0556).
//

import Foundation
import Security

/// Why a free-access anchor could not be read or written.
enum FreeAccessAnchorError: Error, Equatable {
	/// A Keychain call failed with a status other than "not found".
	case keychain(OSStatus)

	/// The stored payload was not a decodable record.
	case malformedRecord
}

/// The durable half of the free-access anchor.
///
/// A protocol for exactly one reason: the grant path has to fail closed when the durable write
/// fails, and that failure cannot be provoked against a real Keychain. Production has a single
/// implementation, ``KeychainFreeAccessAnchorService``.
protocol FreeAccessAnchorDurableStore {
	/// The stored record, or `nil` when the store holds none. Throws when the store could not be
	/// consulted at all, which is *not* the same answer as "there is none".
	func loadRecord() throws -> FreeAccessWindow.Record?
	func saveRecord(_ record: FreeAccessWindow.Record) throws
	func deleteRecord() throws
}

/// Mirrors the free-access anchor into the Keychain, where deleting the app does not reach.
///
/// This is the entire anti-farm mechanic: a UserDefaults copy dies with the app container, a
/// Keychain item does not, so delete-and-reinstall *resumes* the window instead of restarting it.
///
/// The service name and account are injectable because Keychain items deliberately outlive both
/// app deletion and `simctl erase`. A test that wrote under the production name would pass once
/// and then fail on every later run on that simulator, forever.
///
/// `kSecAttrAccessibleAfterFirstUnlock` is load-bearing rather than decorative: the anchor is read
/// during launch, which can happen before the user has unlocked the device, and `WhenUnlocked`
/// would answer `errSecInteractionNotAllowed` there — a read failure that must not be mistaken for
/// "no anchor".
///
/// It is **not** the `…ThisDeviceOnly` variant, and that is a deliberate choice rather than an
/// oversight. This class is excluded from iCloud Keychain sync, so the anchor never syncs sideways
/// to a second device the user is holding — but it *does* travel in an encrypted backup or a
/// device-to-device transfer. That is the behaviour worth having: replacing a phone mid-window
/// resumes it rather than restarting it, and replacing one after the window is spent does not hand
/// out a second free period. `…ThisDeviceOnly` would make a hardware upgrade a reliable way to
/// farm another fourteen days.
///
/// What it is not is a guarantee. A device wiped and set up as new starts fresh, which is the
/// accepted limit recorded in #557.
/// No entitlement is added: with no keychain-access-group the item lands in the default group (the
/// bundle id), and declaring one would change signing.
final class KeychainFreeAccessAnchorService: FreeAccessAnchorDurableStore {

	/// The production service name, namespaced under the bundle id so it cannot collide with
	/// anything the app might store later.
	static let productionServiceName = "com.aiarcheology.ios.freeAccess"

	/// The production account name.
	static let productionAccount = "anchor"

	private let serviceName: String
	private let account: String

	init(
		serviceName: String = KeychainFreeAccessAnchorService.productionServiceName,
		account: String = KeychainFreeAccessAnchorService.productionAccount
	) {
		self.serviceName = serviceName
		self.account = account
	}

	func loadRecord() throws -> FreeAccessWindow.Record? {
		var query = baseQuery
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		switch status {
		case errSecSuccess:
			guard let data = item as? Data else { throw FreeAccessAnchorError.malformedRecord }
			do {
				return try JSONDecoder().decode(FreeAccessWindow.Record.self, from: data)
			} catch {
				throw FreeAccessAnchorError.malformedRecord
			}
		case errSecItemNotFound:
			return nil
		default:
			throw FreeAccessAnchorError.keychain(status)
		}
	}

	func saveRecord(_ record: FreeAccessWindow.Record) throws {
		let data = try JSONEncoder().encode(record)
		let status = SecItemUpdate(
			baseQuery as CFDictionary,
			[kSecValueData as String: data] as CFDictionary
		)
		switch status {
		case errSecSuccess:
			return
		case errSecItemNotFound:
			var addQuery = baseQuery
			addQuery[kSecValueData as String] = data
			addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
			let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
			guard addStatus == errSecSuccess else { throw FreeAccessAnchorError.keychain(addStatus) }
		default:
			throw FreeAccessAnchorError.keychain(status)
		}
	}

	func deleteRecord() throws {
		let status = SecItemDelete(baseQuery as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw FreeAccessAnchorError.keychain(status)
		}
	}

	/// Identity of the item. Never carries `kSecAttrAccessible`: that is an attribute to write,
	/// not part of the item's identity, and including it in a lookup silently matches nothing.
	private var baseQuery: [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: serviceName,
			kSecAttrAccount as String: account
		]
	}
}

/// Reads, reconciles and writes the free-access anchor across its two stores (AIA-0556).
///
/// UserDefaults is the fast path; the Keychain is the durable one. The ordering *is* the feature:
///
/// 1. **Both stores are read before any grant decision exists.** Until they are, the window stays
///    in ``FreeAccessWindow/Anchor/reconciling`` and `canGrant` is `false`. An app that starts as
///    "not granted", reads the flag and grants before reading the Keychain writes a brand-new
///    anchor over a mirror nobody consulted, and reinstall-farming succeeds anyway.
/// 2. **The earliest anchor wins**, never the newest.
/// 3. **The durable write happens first, and its failure aborts the grant.** A UserDefaults-only
///    grant dies with the app container, which is exactly what makes a grant farmable.
///
/// The injected clock is the reason no caller needs a raw `Date`: ``phase(of:)``, ``grant(_:)``
/// and ``observe(_:)`` all read it themselves.
final class FreeAccessAnchorService {

	/// The UserDefaults key holding the fast-path copy of the anchor.
	///
	/// Deliberately not a `Settings` property: the anchor is a fact about the install rather than
	/// a user preference, and this service is not `@MainActor`. `Settings.reset()` must never
	/// remove this key — see the comment there.
	static let defaultsKey = "freeAccessAnchor"

	private let defaults: UserDefaults
	private let durableStore: FreeAccessAnchorDurableStore
	private let thresholds: FreeAccessThresholds
	private let calendar: Calendar
	private let now: () -> Date

	init(
		defaults: UserDefaults = .standard,
		durableStore: FreeAccessAnchorDurableStore = KeychainFreeAccessAnchorService(),
		thresholds: FreeAccessThresholds = .standard,
		calendar: Calendar = .current,
		now: @escaping () -> Date = Date.init
	) {
		self.defaults = defaults
		self.durableStore = durableStore
		self.thresholds = thresholds
		self.calendar = calendar
		self.now = now
	}

	// MARK: - Reconciliation

	/// Reads both stores and returns a settled window.
	///
	/// A durable **read failure** never grants — an unreadable Keychain is not proof that no anchor
	/// exists, and granting on that assumption is the reinstall farm itself. What it does with an
	/// *existing* window depends on the fast record, and that asymmetry is deliberate:
	///
	/// - **A fast record is present** → settle on it and honour the window. A present fast record
	///   proves the app container survived, so this is not a reinstall; walling a legitimate
	///   mid-window user because the Keychain was momentarily unreadable is the worse failure. It
	///   opens no farm: ``FreeAccessWindow/canGrant`` is only ever true for
	///   ``FreeAccessWindow/Anchor/absent``, so honouring a record can never itself hand out a window.
	/// - **No fast record** → stay in ``FreeAccessWindow/Anchor/reconciling``, where granting is
	///   forbidden. That is exactly the reinstall shape, because deleting the app destroys the
	///   container the fast record lived in. Such a user simply has no free window this session and
	///   lands wherever a user without one lands.
	///
	/// A store that is missing the anchor the other one has is repaired here, which is what lets a
	/// reinstall resume rather than restart. The repair is best-effort: the returned window is
	/// already correct without it.
	func reconciledWindow() -> FreeAccessWindow {
		var window = FreeAccessWindow(calendar: calendar)

		let durableRecord: FreeAccessWindow.Record?
		do {
			durableRecord = try durableStore.loadRecord()
		} catch {
			// See the asymmetry above. No repair is attempted on this path: the store that would be
			// written is the one that just failed to answer.
			guard let survivingFastRecord = loadFastRecord() else { return window }
			window.settle(fast: survivingFastRecord, durable: nil)
			return window
		}

		let fastRecord = loadFastRecord()
		window.settle(fast: fastRecord, durable: durableRecord)

		guard case let .granted(settled) = window.anchor else { return window }

		// A record stamped in the future cannot be honest, and honouring it is unbounded: the
		// monotonic floor would hold the window open until real time caught up with the forged
		// date. Repaired here, before anything reads the phase, so no caller ever sees the forged
		// window — and written straight back to both stores so the repair is not re-done every
		// launch. See `FreeAccessWindow.reanchoredIfGrantedInTheFuture`.
		let record = FreeAccessWindow.reanchoredIfGrantedInTheFuture(
			settled,
			now: now(),
			calendar: calendar
		) ?? settled
		if record != settled { window.settle(fast: record, durable: record) }

		if durableRecord != record { try? durableStore.saveRecord(record) }
		if fastRecord != record { writeFastRecord(record) }
		return window
	}

	// MARK: - Mutation

	/// Opens a window when one may be opened.
	///
	/// Returns `false` when the gate refuses (still reconciling, or an anchor already exists), and
	/// throws when the durable write fails. In both cases `window` is left exactly as it was: the
	/// transition is applied to a copy and only committed once the Keychain has accepted the
	/// record, because a grant that exists only in UserDefaults is a farmable grant.
	///
	/// The caller is responsible for the feature flag; this method answers the storage half.
	@discardableResult
	func grant(_ window: inout FreeAccessWindow) throws -> Bool {
		var candidate = window
		guard let record = candidate.grant(at: now(), thresholds: thresholds) else { return false }
		try durableStore.saveRecord(record)
		writeFastRecord(record)
		window = candidate
		return true
	}

	/// The phase of `window` at the injected clock.
	func phase(of window: FreeAccessWindow) -> FreeAccessPhase {
		window.phase(at: now())
	}

	/// Which paywall `window` still owes the user at the injected clock.
	func duePrompt(for window: FreeAccessWindow) -> FreeAccessPrompt? {
		window.duePrompt(at: now())
	}

	/// Advances the monotonic floor to the injected clock and persists it when it moved.
	func observe(_ window: inout FreeAccessWindow) {
		guard let record = window.observe(at: now()) else { return }
		persistProgress(record)
	}

	/// Records that the reminder has been surfaced, and persists that.
	func markReminderShown(_ window: inout FreeAccessWindow) {
		guard let record = window.markReminderShown() else { return }
		persistProgress(record)
	}

	/// Records that the day-0 paywall has been surfaced, and persists that.
	func markDay0Shown(_ window: inout FreeAccessWindow) {
		guard let record = window.markDay0Shown() else { return }
		persistProgress(record)
	}

	/// Writes a progress-only change (the monotonic floor, the two shown-markers) to both stores.
	///
	/// Unlike a grant this does not fail closed, because the anchor's identity — the grant date and
	/// the frozen thresholds — is already durable and unchanged. A dropped progress write costs at
	/// most one repeated paywall or a weaker clamp, never an extra window.
	private func persistProgress(_ record: FreeAccessWindow.Record) {
		writeFastRecord(record)
		try? durableStore.saveRecord(record)
	}

	// MARK: - Fast path

	private func loadFastRecord() -> FreeAccessWindow.Record? {
		guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
		return try? JSONDecoder().decode(FreeAccessWindow.Record.self, from: data)
	}

	private func writeFastRecord(_ record: FreeAccessWindow.Record) {
		guard let data = try? JSONEncoder().encode(record) else { return }
		defaults.set(data, forKey: Self.defaultsKey)
	}
}
