//
//  FeatureFlags.swift
//  AI Archeology
//
//  In-source feature flags (AIA-0343). See AGENTS.md §3 "Feature flags".
//

import Foundation

/// Compile-time feature flags. Deliberately the simple version: a single typed
/// constants file read at each feature's entry point, so a feature can ship dark
/// and be flipped on without ripping code out.
///
/// Keep these few and meaningful — one per shippable feature — and remove a flag
/// once its feature is permanently on and stable.
enum FeatureFlags {
	/// Gates the in-app subscription/paywall surface (AIA-0343): the Settings
	/// "Upgrade" entry point and any feature gated on entitlement.
	// TODO(AIA-0343): move to a real (remote) feature-flag system.
	static let isPaymentsEnabled = false
}
