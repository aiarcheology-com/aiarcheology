//
//  SentryStatsView.swift
//  AI Archeology
//

import SwiftUI

struct SentryStatsView: View {
	var body: some View {
		TimelineView(.periodic(from: Date(), by: 1.0)) { _ in
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
		if c.attoseconds == 0 {
			return "\(c.seconds)s"
		}
		return "\(c.seconds)s + \(c.attoseconds)as"
	}
}
