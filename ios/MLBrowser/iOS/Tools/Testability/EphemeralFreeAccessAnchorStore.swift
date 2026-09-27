//
//  EphemeralFreeAccessAnchorStore.swift
//  AI Archeology
//
//  A durable free-access anchor store that does not survive the process (AIA-0556).
//

import Foundation

#if DEBUG
/// The durable half of the free-access anchor, held in memory only.
///
/// Exists because the real one is *too* durable for a test harness. `Settings.init()` wipes the
/// UI-test `UserDefaults` suite on every launch, but the Keychain item deliberately outlives app
/// deletion, and test runs reinstall rather than erase — so the first UI test that granted a window
/// would leave an anchor behind that no later run could clear, permanently poisoning every "fresh
/// install" path on that simulator. A per-process store makes each launch a genuine first install again.
///
/// `#if DEBUG` for the same reason as ``MockAuthProvider``: the environment markers that select it
/// are launch-controlled, so the only guarantee that a shipping build cannot take this path is that
/// the type is not in the binary.
final class EphemeralFreeAccessAnchorStore: FreeAccessAnchorDurableStore {
	private var record: FreeAccessWindow.Record?

	init(record: FreeAccessWindow.Record? = nil) {
		self.record = record
	}

	func loadRecord() throws -> FreeAccessWindow.Record? { record }

	func saveRecord(_ record: FreeAccessWindow.Record) throws { self.record = record }

	func deleteRecord() throws { record = nil }
}
#endif
