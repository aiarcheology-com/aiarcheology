//
//  SentryStatsView.swift
//  AI Archeology
//

import SwiftUI

struct SentryStatsView: View {
	var body: some View {
		TimelineView(.periodic(from: Date(), by: 5.0)) { _ in
			Form {
				if let snapshot = SentryThrottleDiagnostics.snapshot() {
					Section(header: Text("Config")) {
						row("enabled", snapshot.config.isEnabled.description)
						row("perSignatureCooldown", format(snapshot.config.perSignatureCooldown))
						row("perSignatureBurst", "\(snapshot.config.perSignatureBurst)")
						row("globalCapPerHour", "\(snapshot.config.globalCapPerHour)")
						row("sessionCap", "\(snapshot.config.sessionCap)")
						row("signatureCacheLimit", "\(snapshot.config.signatureCacheLimit)")
						row("sampleEveryNthDuplicate", "\(snapshot.config.sampleEveryNthDuplicate)")
						row("suppressedCountBreadcrumb", snapshot.config.enableSuppressedCountBreadcrumb.description)
					}
					
					Section(header: Text("Counters")) {
						row("events.attempted", "\(snapshot.stats.attempted)")
						row("events.sent", "\(snapshot.stats.sent)")
						row("events.dropped.duplicate", "\(snapshot.stats.droppedDuplicate)")
						row("events.dropped.global_cap", "\(snapshot.stats.droppedGlobalCap)")
						row("events.dropped.session_cap", "\(snapshot.stats.droppedSessionCap)")
						row("events.dropped.server_rate_limit", "\(snapshot.stats.droppedServerRateLimit)")
					}
				} else {
					Section {
						Text("Sentry throttle diagnostics not available in this build.")
							.foregroundColor(.secondary)
					}
				}
			}
			.navigationTitle("Sentry Stats")
		}
	}
	
	@ViewBuilder
	private func row(_ key: String, _ value: String) -> some View {
		HStack {
			Text(key)
			Spacer()
			Text(value)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.trailing)
		}
	}
	
	private func format(_ d: Duration) -> String {
		let c = d.components
		// Preserve existing simple formatting when there is no fractional component.
		if c.attoseconds == 0 {
			return "\(c.seconds)s"
		}
		
		// Convert attoseconds to a fractional number of seconds.
		let attosecondsPerSecond = 1_000_000_000_000_000_000.0
		let totalSeconds = Double(c.seconds) + Double(c.attoseconds) / attosecondsPerSecond
		
		// If we have at least one whole second, show fractional seconds with limited precision.
		if c.seconds != 0 {
			return String(format: "%.3fs", totalSeconds)
		}
		
		// For sub-second durations, show milliseconds with limited precision.
		let milliseconds = totalSeconds * 1_000.0
		if milliseconds >= 1.0 {
			return String(format: "%.3fms", milliseconds)
		}
		
		// For extremely small durations, fall back to microseconds as an integer.
		let microseconds = totalSeconds * 1_000_000.0
		return String(format: "%.0fµs", microseconds)
	}
}
