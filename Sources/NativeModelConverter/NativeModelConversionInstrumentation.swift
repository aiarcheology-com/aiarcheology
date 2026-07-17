//
//  NativeModelConversionInstrumentation.swift
//  NativeModelConverter
//
//  Unified logging and Instruments signposts for conversion.
//

import OSLog

enum NativeModelConversionInstrumentation {
	static let log = OSLog(
		subsystem: "com.aiarcheology.NativeModelConverter",
		category: "Conversion"
	)

	static func begin(_ name: StaticString, signpostID: OSSignpostID) {
		os_signpost(.begin, log: log, name: name, signpostID: signpostID)
	}

	static func end(_ name: StaticString, signpostID: OSSignpostID) {
		os_signpost(.end, log: log, name: name, signpostID: signpostID)
	}

	static func event(_ phase: NativeModelConversionPhase) {
		os_signpost(.event, log: log, name: "Conversion phase", "%{public}s", phase.rawValue)
	}

	static func packageRead(inputByteCount: UInt64, operationCount: Int) {
		os_log(
			"Read native model package: input_bytes=%{public}llu operations=%{public}d",
			log: log,
			type: .info,
			inputByteCount,
			operationCount
		)
	}

	static func modelEmitted(outputByteCount: UInt64, operationCount: Int) {
		os_log(
			"Emitted Core ML model: output_bytes=%{public}llu operations=%{public}d",
			log: log,
			type: .info,
			outputByteCount,
			operationCount
		)
	}

	static func error(code: String, phase: NativeModelConversionPhase) {
		os_log(
			"Native model conversion failed: code=%{public}s phase=%{public}s",
			log: log,
			type: .error,
			code,
			phase.rawValue
		)
	}
}
