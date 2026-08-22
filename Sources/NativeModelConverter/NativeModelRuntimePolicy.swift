//
//  NativeModelRuntimePolicy.swift
//  NativeModelConverter
//
//  Runtime requirements that travel with an emitted model.
//

import Foundation

/// A compute-unit choice that a converted model may require at runtime.
///
/// Core ML's default `.all` placement is intentionally not represented here: absence of this
/// metadata means that the importing app may keep its normal default. A policy is emitted only
/// when the converter has evidence that a particular graph needs a narrower placement for its
/// numerical contract.
public enum NativeModelComputeUnitPolicy: String, Codable, Equatable, Sendable {
	case cpuOnly
	case cpuAndGPU
}

/// The metadata contract used by an app to honor a converted model's compute-unit requirement.
public enum NativeModelRuntimePolicy {
	/// The `creatorDefined` entry carrying the policy. Values are the raw strings of
	/// ``NativeModelComputeUnitPolicy``.
	public static let computeUnitsKey = "com.aiarcheology.native.runtime.compute-units"

	/// The graph producer stamped by the pinned ADAF Faster R-CNN registry.
	public static let adafFasterRCNNProducerName = "aiarcheology-adaf-fasterrcnn"

	/// Reads a complete, known policy from Core ML's user-defined metadata. Unknown values are
	/// ignored so an older app never guesses at a requirement introduced by a newer converter.
	public static func computeUnitPolicy(from userDefined: [String: String]) -> NativeModelComputeUnitPolicy? {
		guard let rawValue = userDefined[computeUnitsKey] else { return nil }
		return NativeModelComputeUnitPolicy(rawValue: rawValue)
	}

	/// Returns the policy required by a known graph producer, or nil when the graph may use the
	/// importing app's default placement.
	public static func computeUnitPolicy(forProducer producerName: String) -> NativeModelComputeUnitPolicy? {
		guard producerName == adafFasterRCNNProducerName else { return nil }
		// AIA-0688 measured a deterministic 3.9135 px box drift on the iPhone 16 Pro Max when this
		// graph was dispatched through `.all`/ANE. The emitted graph's CPU path satisfies the
		// torchvision decision rule, so the model carries an explicit CPU requirement.
		return .cpuOnly
	}
}
