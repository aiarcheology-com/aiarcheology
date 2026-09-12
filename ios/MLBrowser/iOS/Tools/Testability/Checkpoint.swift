//
//  Checkpoint.swift
//  AI Archeology
//
//  In-app state introspection for UI tests (AIA-0189).
//

import SwiftUI

extension View {
	/// Publishes `value` as a hidden accessibility element identified
	/// `_AIA:Checkpoint.<name>`, so a UI test can assert internal state that is not
	/// otherwise reachable through the visible accessibility tree (e.g. which page the
	/// browser decided to load, the active size class).
	///
	/// The marker is rendered **only** under UI tests (`AppEnvironment.isRunningUITests`)
	/// and is fully inert in every shipping build. It carries the value as both the
	/// accessibility value and label, and never participates in hit-testing or layout
	/// (it sits in a 1pt background behind the content).
	///
	/// Tests read it with `waitForCheckpoint(_:equals:)` — the element can exist before
	/// the value settles, so assert on the value, not on existence alone.
	func checkpoint(_ name: Testability.Checkpoint, value: String) -> some View {
		background(CheckpointMarker(name: name, value: value))
	}
}

/// A clear, 1pt, non-interactive `Text`. A `Text` reliably surfaces as a `staticText`
/// in XCUITest; a clear foreground keeps it in the accessibility tree while invisible,
/// avoiding the pruning that near-zero-opacity or zero-size elements can suffer across
/// framework releases.
private struct CheckpointMarker: View {
	let name: Testability.Checkpoint
	let value: String

	var body: some View {
		if AppEnvironment.isRunningUITests {
			Text(value)
				.font(.system(size: 1))
				.foregroundColor(.clear)
				.frame(width: 1, height: 1)
				.allowsHitTesting(false)
				.accessibilityIdentifier(name())
				.accessibilityValue(value)
				.accessibilityLabel(value)
		}
	}
}
