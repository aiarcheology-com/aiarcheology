//
//  NativeModelGraphPackageTests.swift
//  NativeModelConverterTests
//

import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelGraphPackageTests: XCTestCase {

	func testRead_verifiedPackage_returnsGraphAndWeights() async throws {
		let graph = makeReLUGraph()
		let packageURL = try makePackage(graph: graph, weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }

		let package = try await NativeModelGraphPackageReader().read(from: packageURL)

		XCTAssertEqual(package.manifest.format, NativeModelGraphPackageManifest.formatIdentifier)
		XCTAssertEqual(package.graph, graph)
		XCTAssertEqual(package.weights, Data())
	}

	func testRead_modifiedWeights_reportsChecksumMismatch() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data([1, 2, 3]))
		defer { try? FileManager.default.removeItem(at: packageURL) }
		try Data([1, 2, 4]).write(to: packageURL.appendingPathComponent("weights.bin"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .weightsChecksumMismatch = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected a weights checksum mismatch, got \(error).")
			}
		}
	}

	func testEmit_verifiedPackage_compilesWithCoreML() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let package = try await NativeModelGraphPackageReader().read(from: packageURL)
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")

		try NativeModelCoreMLEmitter().emit(package: package, to: modelURL)

		do {
			_ = try await MLModel.compileModel(at: modelURL)
		} catch {
			XCTFail("Expected package-emitted model to compile: \(error)")
		}
	}

	private func makeReLUGraph() -> NativeModelGraph {
		NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 1, 2, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 1, 2, 2])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
	}

	private func makePackage(graph: NativeModelGraph, weights: Data) throws -> URL {
		let packageURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
			.appendingPathExtension("aiagraph")
		try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
		let manifest = NativeModelGraphPackageManifest(
			formatVersion: graph.formatVersion,
			weightsSHA256: checksum(of: weights)
		)
		try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent("manifest.json"))
		try JSONEncoder().encode(graph).write(to: packageURL.appendingPathComponent("graph.json"))
		try weights.write(to: packageURL.appendingPathComponent("weights.bin"))
		return packageURL
	}

	private func checksum(of data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

private func XCTAssertThrowsErrorAsync<T>(
	_ expression: @autoclosure () async throws -> T,
	_ errorHandler: (Error) -> Void
) async {
	do {
		_ = try await expression()
		XCTFail("Expected an error to be thrown.")
	} catch {
		errorHandler(error)
	}
}
