//
//  NativeModelConversionMemory.swift
//  NativeModelConverter
//
//  Lightweight, on-device process-memory observations for conversion clients.
//

import Foundation
import MachO

/// A sampled memory value for the process that is performing a conversion.
///
/// The value is the operating system's physical-footprint accounting for the *whole app process*.
/// It is useful to make an import's device demand visible, but it must not be interpreted as bytes
/// exclusively owned by `NativeModelConverter`: SwiftUI, Core ML, caches, and other app work share
/// the same process. Samples are taken at converter progress boundaries rather than continuously,
/// so `peakObservedProcessFootprintByteCount` is an observed lower bound, not a guaranteed peak.
public struct NativeModelConversionProcessMemoryUsage: Codable, Equatable, Sendable {
	/// The process physical footprint when the conversion acquired exclusive access.
	public let baselineProcessFootprintByteCount: UInt64
	/// The process physical footprint at this progress boundary.
	public let currentProcessFootprintByteCount: UInt64
	/// The largest process physical footprint observed at a conversion progress boundary so far.
	public let peakObservedProcessFootprintByteCount: UInt64

	public init(
		baselineProcessFootprintByteCount: UInt64,
		currentProcessFootprintByteCount: UInt64,
		peakObservedProcessFootprintByteCount: UInt64
	) {
		self.baselineProcessFootprintByteCount = baselineProcessFootprintByteCount
		self.currentProcessFootprintByteCount = currentProcessFootprintByteCount
		self.peakObservedProcessFootprintByteCount = peakObservedProcessFootprintByteCount
	}

	/// The non-negative increase from the observed baseline to the observed peak.
	///
	/// This is a process-level difference, not a per-library allocation measurement.
	public var observedPeakIncreaseByteCount: UInt64 {
		peakObservedProcessFootprintByteCount >= baselineProcessFootprintByteCount
			? peakObservedProcessFootprintByteCount - baselineProcessFootprintByteCount
			: 0
	}
}

/// Reads the platform's physical-footprint accounting for this process.
///
/// This is public so a host can present the same clearly-labelled process-level value between
/// conversion callbacks if it chooses. It does not start polling or retain a background task.
public enum NativeModelConversionProcessMemory {
	public static func currentProcessFootprintByteCount() -> UInt64? {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(
			MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
		)
		let result = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		guard result == KERN_SUCCESS else { return nil }
		return UInt64(info.phys_footprint)
	}
}

/// Serializes process-memory observations made from synchronous progress callbacks.
final class NativeModelConversionMemoryTracker: @unchecked Sendable {
	private let lock = NSLock()
	private var baseline: UInt64?
	private var peak: UInt64?

	func sample() -> NativeModelConversionProcessMemoryUsage? {
		guard let current = NativeModelConversionProcessMemory.currentProcessFootprintByteCount() else {
			return nil
		}
		lock.lock()
		defer { lock.unlock() }
		if baseline == nil {
			baseline = current
		}
		peak = max(peak ?? current, current)
		return NativeModelConversionProcessMemoryUsage(
			baselineProcessFootprintByteCount: baseline ?? current,
			currentProcessFootprintByteCount: current,
			peakObservedProcessFootprintByteCount: peak ?? current
		)
	}
}
