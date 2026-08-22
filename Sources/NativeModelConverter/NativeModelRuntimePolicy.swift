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
/// numerical contract.  The choice is deliberately expressed as a Core ML allow-list rather than as
/// a claim about one particular accelerator, because a measured requirement can name any of them:
/// the ADAF detector needs `.cpuOnly` not because the Neural Engine is singled out, but because
/// every non-CPU backend measured so far flips a near-tie in its terminal NMS.
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
		// Measured on an iPhone 16 Pro Max (iOS 26.5.2) against the torchvision oracle, maximum box
		// shift on the AO barrow fixture: .cpuOnly 0.00033 px, .cpuAndNeuralEngine/.all 3.9135 px,
		// .cpuAndGPU 9.6623 px.  Only the CPU path holds the 1 px budget.
		//
		// An earlier revision requested .cpuAndGPU on the strength of AIA-0676, which measured
		// .cpuAndGPU bit-identical to .cpuOnly.  That probe ran on a random-weights model and did not
		// generalise: on the real converted detector the GPU path is the *worst* of the three.  The
		// GPU executes this graph in Float32, so its divergence is reassociation alone — different
		// reduction order inside conv/matmul, different exp/log implementations, on the order of
		// 1e-06.  That cannot move a box 9.66 px by arithmetic; it moves it by flipping a near-tie in
		// the terminal NMS onto a different overlapping proposal.  Any non-CPU backend can do that,
		// which is why this is a CPU requirement rather than an anti-ANE one.
		//
		// This policy is the converter's *numerical* requirement, not a user-facing performance
		// choice.  The app may let a user override it per model; that override carries a separate,
		// explicitly wider product budget and is not this contract.
		return .cpuOnly
	}
}
