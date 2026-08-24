//
//  NativeModelConversionPerformanceTests.swift
//  MLBrowserUnitTests
//
//  Physical-device performance evidence for native model conversion.
//

import CryptoKit
import Foundation
import UIKit
import XCTest
import NativeModelConverter

@MainActor
final class NativeModelConversionPerformanceTests: XCTestCase {
	private static let adafCheckpointFilename = "OD_ringfort.tar"
	private static let adafCheckpointByteCount: UInt64 = 517_823_445
	private static let adafCheckpointMD5 = "4518e1966cafa0544bd3ea78be3b711a"
	/// Frozen from the established dense app-vs-CLI artifact test. This benchmark is not allowed to
	/// turn a memory optimisation into a new model format.
	private static let adafArtifactSHA256 = "16ad7c884a35c5c5e4f6939fc6ccf887bb4cc9dfcb7f09913d5ec4e0ddc139f6"

	/// Measures package validation, reading, and `.mlmodel` emission for a 14 MiB Float32 weight
	/// fixture. The fixture is deliberately convolution-heavy because the current emitter copies
	/// every weight into the protobuf model. It matches MobileNetV2's Float32 weight-size class, but
	/// it is not used as a numerical-parity substitute for MobileNetV2.
	///
	/// This test is opt-in and physical-device-only. XCTest records the clock and physical-memory
	/// metrics in the `.xcresult`; the JSON attachment records the exact fixture/output sizes and
	/// per-run library timings needed to interpret those aggregate metrics.
	func testPhysicalDeviceMetrics_float32ConvolutionWeightFixture() async throws {
		try requirePhysicalDeviceBenchmark()

		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let packageURL = try makeConvolutionWeightFixture(in: directory)
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		let converter = NativeModelConverter()

		let preflight = try await converter.convert(from: packageURL, to: modelURL)
		addBenchmarkAttachment(for: preflight)
		try? FileManager.default.removeItem(at: modelURL)

		measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
			do {
				_ = try synchronously {
					try await converter.convert(from: packageURL, to: modelURL)
				}
			} catch {
				XCTFail("Native conversion failed during performance measurement: \(error)")
			}
		}
	}

	/// Measures the actual 518 MB dense checkpoint conversion on a physical iPhone.
	///
	/// This is separately staged and opt-in because copying the checkpoint into an XCTest bundle is
	/// expensive. The preflight validates both the exact source fixture and the pre-existing Core ML
	/// artifact before `XCTMemoryMetric` records the repeated conversion process. Use
	/// `scripts/prepare_adaf_conversion_benchmark_assets.sh` and pass its output through
	/// `AIA_ADAF_CONVERSION_BENCHMARK_ASSETS` at build time.
	func testPhysicalIPhoneMetrics_fullADAFCheckpoint() async throws {
		try requirePhysicalADAFBenchmark()
		let checkpointURL = try stagedADAFCheckpointURL()
		let checkpointDigest = try streamingDigest(of: checkpointURL)
		XCTAssertEqual(checkpointDigest.byteCount, Self.adafCheckpointByteCount)
		XCTAssertEqual(checkpointDigest.md5, Self.adafCheckpointMD5)

		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let modelURL = directory.appendingPathComponent("OD_ringfort.mlmodel", isDirectory: false)
		let converter = NativeModelConverter()

		let preflight = try await converter.convert(adafDetector: checkpointURL, to: modelURL)
		let modelDigest = try streamingDigest(of: modelURL)
		XCTAssertEqual(modelDigest.sha256, Self.adafArtifactSHA256)
		addADAFBenchmarkAttachment(
			checkpoint: checkpointDigest,
			model: modelDigest,
			metrics: preflight
		)
		try FileManager.default.removeItem(at: modelURL)

		let options = XCTMeasureOptions()
		options.iterationCount = 3
		measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
			do {
				_ = try synchronously {
					try await converter.convert(adafDetector: checkpointURL, to: modelURL)
				}
			} catch {
				XCTFail("ADAF conversion failed during physical-memory measurement: \(error)")
			}
		}
	}

	private func requirePhysicalDeviceBenchmark() throws {
		guard ProcessInfo.processInfo.environment["NATIVE_MODEL_CONVERSION_DEVICE_BENCHMARK"] == "1" else {
			throw XCTSkip("Set NATIVE_MODEL_CONVERSION_DEVICE_BENCHMARK=1 in the Test action to run the opt-in device benchmark.")
		}
		guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil else {
			throw XCTSkip("XCTMemoryMetric device evidence must come from a physical iPhone or iPad, not a simulator.")
		}
	}

	private func requirePhysicalADAFBenchmark() throws {
		guard ProcessInfo.processInfo.environment["ADAF_CONVERSION_DEVICE_BENCHMARK"] == "1" else {
			throw XCTSkip(
				"Set ADAF_CONVERSION_DEVICE_BENCHMARK=1 to record the opt-in full-checkpoint physical-iPhone metric."
			)
		}
		guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil else {
			throw XCTSkip("The full ADAF conversion benchmark requires a physical iPhone, not a simulator.")
		}
		guard UIDevice.current.userInterfaceIdiom == .phone else {
			throw XCTSkip("The full ADAF conversion benchmark is recorded on a physical iPhone; this device is not an iPhone.")
		}
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("NativeModelConversionBenchmark-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func makeConvolutionWeightFixture(in directory: URL) throws -> URL {
		let packageURL = directory.appendingPathComponent("ConvolutionWeightFixture.aiagraph", isDirectory: true)
		try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

		let channelCount = 256
		let layerCount = 6
		let kernelShape = [channelCount, channelCount, 3, 3]
		let kernelByteCount = UInt64(kernelShape.reduce(1, *)) * 4
		let biasByteCount = UInt64(channelCount * 4)
		let attributes: [String: NativeModelAttribute] = [
			"kernelSize": .integers([3, 3]),
			"strides": .integers([1, 1]),
			"padding": .integers([1, 1]),
			"dilations": .integers([1, 1]),
			"groups": .integer(1)
		]

		var offset: UInt64 = 0
		var weights: [NativeModelWeight] = []
		var operations: [NativeModelOperation] = []
		var inputName = "input"
		for index in 0..<layerCount {
			let kernelName = "conv\(index).weight"
			let biasName = "conv\(index).bias"
			let outputName = "conv\(index).output"
			weights.append(NativeModelWeight(
				name: kernelName,
				dataType: .float32,
				shape: kernelShape,
				offset: offset,
				byteCount: kernelByteCount
			))
			offset += kernelByteCount
			weights.append(NativeModelWeight(
				name: biasName,
				dataType: .float32,
				shape: [channelCount],
				offset: offset,
				byteCount: biasByteCount
			))
			offset += biasByteCount
			operations.append(NativeModelOperation(
				name: "conv\(index)",
				kind: .convolution2D,
				inputs: [inputName, kernelName, biasName],
				outputs: [NativeModelTensor(name: outputName, dataType: .float32, shape: [1, channelCount, 8, 8])],
				attributes: attributes
			))
			inputName = outputName
		}

		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "aiarcheology-device-benchmark", version: "1"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, channelCount, 8, 8])],
			weights: weights,
			operations: operations,
			outputs: [inputName]
		)
		let graphData = try JSONEncoder().encode(graph)
		let weightsData = Data(count: Int(offset))
		let manifest = NativeModelGraphPackageManifest(
			formatVersion: graph.formatVersion,
			graphSHA256: checksum(of: graphData),
			weightsSHA256: checksum(of: weightsData)
		)

		try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent("manifest.json"))
		try graphData.write(to: packageURL.appendingPathComponent("graph.json"))
		try weightsData.write(to: packageURL.appendingPathComponent("weights.bin"))
		return packageURL
	}

	private func stagedADAFCheckpointURL() throws -> URL {
		let resourceName = (Self.adafCheckpointFilename as NSString).deletingPathExtension
		let fileExtension = (Self.adafCheckpointFilename as NSString).pathExtension
		try XCTUnwrap(
			Bundle(for: Self.self).url(forResource: resourceName, withExtension: fileExtension),
			"The dense ADAF checkpoint is absent. Run scripts/prepare_adaf_conversion_benchmark_assets.sh "
				+ "and set AIA_ADAF_CONVERSION_BENCHMARK_ASSETS before building the test bundle."
		)
	}

	private func streamingDigest(of fileURL: URL) throws -> ADAFBenchmarkFileDigest {
		let handle = try FileHandle(forReadingFrom: fileURL)
		defer { try? handle.close() }
		var sha256 = SHA256()
		var md5 = Insecure.MD5()
		var byteCount: UInt64 = 0
		while let chunk = try handle.read(upToCount: 1 * 1_024 * 1_024), !chunk.isEmpty {
			sha256.update(data: chunk)
			md5.update(data: chunk)
			byteCount += UInt64(chunk.count)
		}
		return ADAFBenchmarkFileDigest(
			byteCount: byteCount,
			sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined(),
			md5: md5.finalize().map { String(format: "%02x", $0) }.joined()
		)
	}

	private func addBenchmarkAttachment(for metrics: NativeModelConversionMetrics) {
		let report = NativeModelDeviceBenchmarkReport(
			deviceFamily: UIDevice.current.model,
			operatingSystemVersion: UIDevice.current.systemVersion,
			metrics: metrics
		)
		guard let data = try? JSONEncoder.prettySorted.encode(report) else {
			return XCTFail("Could not encode native-model benchmark report.")
		}
		let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
		attachment.name = "native-model-conversion-device-preflight.json"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	private func addADAFBenchmarkAttachment(
		checkpoint: ADAFBenchmarkFileDigest,
		model: ADAFBenchmarkFileDigest,
		metrics: NativeModelConversionMetrics
	) {
		let report = ADAFConversionDeviceBenchmarkReport(
			deviceFamily: UIDevice.current.model,
			operatingSystemVersion: UIDevice.current.systemVersion,
			xcodeBuild: Bundle(for: Self.self).object(forInfoDictionaryKey: "DTXcodeBuild") as? String,
			converterPackageVersion: NativeModelConverterVersion.packageVersion,
			converterConversionRevision: NativeModelConverterVersion.conversionRevision,
			checkpoint: checkpoint,
			model: model,
			preflightMetrics: metrics
		)
		guard let data = try? JSONEncoder.prettySorted.encode(report) else {
			return XCTFail("Could not encode the ADAF conversion benchmark report.")
		}
		let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
		attachment.name = "adaf-full-checkpoint-conversion-preflight.json"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	private func synchronously<T: Sendable>(
		_ operation: @escaping @Sendable () async throws -> T
	) throws -> T {
		let result = LockedResult<T>()
		let semaphore = DispatchSemaphore(value: 0)
		Task.detached {
			defer { semaphore.signal() }
			do {
				result.store(.success(try await operation()))
			} catch {
				result.store(.failure(error))
			}
		}
		semaphore.wait()
		return try result.take().get()
	}

	private func checksum(of data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

private final class LockedResult<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var result: Result<Value, Error>?

	func store(_ result: Result<Value, Error>) {
		lock.lock()
		defer { lock.unlock() }
		self.result = result
	}

	func take() -> Result<Value, Error> {
		lock.lock()
		defer { lock.unlock() }
		guard let result else {
			fatalError("Native-model benchmark did not produce a result.")
		}
		return result
	}
}

private struct NativeModelDeviceBenchmarkReport: Encodable {
	let deviceFamily: String
	let operatingSystemVersion: String
	let metrics: NativeModelConversionMetrics
}

private struct ADAFBenchmarkFileDigest: Encodable {
	let byteCount: UInt64
	let sha256: String
	let md5: String
}

private struct ADAFConversionDeviceBenchmarkReport: Encodable {
	let deviceFamily: String
	let operatingSystemVersion: String
	let xcodeBuild: String?
	let converterPackageVersion: String
	let converterConversionRevision: Int
	let checkpoint: ADAFBenchmarkFileDigest
	let model: ADAFBenchmarkFileDigest
	let preflightMetrics: NativeModelConversionMetrics
}

private extension JSONEncoder {
	static var prettySorted: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return encoder
	}
}
