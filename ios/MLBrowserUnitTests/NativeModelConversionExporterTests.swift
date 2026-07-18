//
//  NativeModelConversionExporterTests.swift
//  MLBrowserUnitTests
//

import Foundation
import NativeModelConverter
import XCTest
@testable import ML_Browser

final class NativeModelConversionExporterTests: XCTestCase {
	func testMakeZip_includesConvertedModelMetadataAndReportButNotOriginalPackage() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "original.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: true
		)
		report.transition(to: .registered)
		try report.write(in: configurationDirectory)
		try FileManager.default.createDirectory(
			at: report.sourcePackageURL(in: configurationDirectory),
			withIntermediateDirectories: true
		)
		let modelURL = report.convertedModelURL(in: configurationDirectory)
		try Data("converted model".utf8).write(to: modelURL)
		try Data("lossless source metadata".utf8).write(to: NativeModelMetadataSidecar.url(for: modelURL))

		let archiveURL = try NativeModelConversionExporter.makeZip(
			report: report,
			configurationDirectory: configurationDirectory,
			date: Date(timeIntervalSince1970: 0)
		)
		defer { NativeModelConversionExporter.removeExportArchive(at: archiveURL) }

		let names = try entryNames(of: archiveURL)
		XCTAssertTrue(names.contains("ConvertedModel/converted.mlmodel"))
		XCTAssertTrue(names.contains("ConvertedModel/converted.metadata.json"))
		XCTAssertTrue(names.contains("ConvertedModel/native-conversion-report.json"))
		XCTAssertTrue(names.contains("ConvertedModel/README.txt"))
		XCTAssertFalse(names.contains { $0.contains("original.aiagraph") })

		NativeModelConversionExporter.removeExportArchive(at: archiveURL)
		XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
	}

	func testMakeZip_rejectsUnregisteredConversion() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "original.aiagraph",
			retainOriginalPackage: false,
			wasRemoteImport: false
		)

		XCTAssertThrowsError(
			try NativeModelConversionExporter.makeZip(report: report, configurationDirectory: configurationDirectory)
		) { error in
			XCTAssertEqual(error as? NativeModelConversionExportError, .notRegistered)
		}
	}

	// MARK: - Model file export (droppable artifact)

	func testMakeShareableCopy_singleFileModel_isCopiedUnderItsOwnName() throws {
		// A .mlmodel is already the droppable artifact — it must be shared as a file, not an archive.
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let modelURL = directory.appendingPathComponent("MobileNetV2.mlmodel")
		try Data("converted model".utf8).write(to: modelURL)

		let exportURL = try ModelFileExporter.makeShareableCopy(of: modelURL)
		defer { ModelFileExporter.removeExport(at: exportURL) }

		XCTAssertEqual(exportURL.lastPathComponent, "MobileNetV2.mlmodel")
		XCTAssertEqual(try Data(contentsOf: exportURL), Data("converted model".utf8))
	}

	func testMakeShareableCopy_bundleModel_isZipped() throws {
		// A .mlpackage is a directory; most share destinations drop it, so it must travel zipped.
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let packageURL = directory.appendingPathComponent("Detector.mlpackage", isDirectory: true)
		try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
		try Data("manifest".utf8).write(to: packageURL.appendingPathComponent("Manifest.json"))

		let exportURL = try ModelFileExporter.makeShareableCopy(of: packageURL)
		defer { ModelFileExporter.removeExport(at: exportURL) }

		XCTAssertEqual(exportURL.lastPathComponent, "Detector.mlpackage.zip")
		XCTAssertGreaterThan(try Data(contentsOf: exportURL).count, 0)
	}

	func testMakeShareableCopy_missingModel_throws() {
		let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		XCTAssertThrowsError(try ModelFileExporter.makeShareableCopy(of: missingURL)) { error in
			XCTAssertEqual(error as? ModelFileExportError, .missingModelFile)
		}
	}

	// MARK: - Drawer provenance

	func testProvenance_configurationWithConversionReport_reportsSourceFormat() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "mobilenetv2-10.onnx",
			retainOriginalPackage: false,
			wasRemoteImport: true
		)
		try report.write(in: configurationDirectory)

		XCTAssertEqual(ModelProvenance.read(in: configurationDirectory), .converted(sourceFormat: "ONNX"))
	}

	func testProvenance_configurationWithoutReport_isCoreML() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }

		XCTAssertEqual(ModelProvenance.read(in: configurationDirectory), .coreML)
	}

	func testProvenance_sourceFormat_fallsBackForExtensionlessNames() {
		XCTAssertEqual(ModelProvenance.sourceFormat(of: "squeezenet1.0-12.onnx"), "ONNX")
		XCTAssertEqual(ModelProvenance.sourceFormat(of: "package.aiagraph"), "AIAGRAPH")
		XCTAssertEqual(ModelProvenance.sourceFormat(of: "no-extension"), "AIAGRAPH")
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func entryNames(of url: URL) throws -> [String] {
		let bytes = [UInt8](try Data(contentsOf: url))
		func u16(_ offset: Int) -> Int {
			Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
		}
		func u32(_ offset: Int) -> Int {
			Int(bytes[offset])
				| Int(bytes[offset + 1]) << 8
				| Int(bytes[offset + 2]) << 16
				| Int(bytes[offset + 3]) << 24
		}

		let endOfCentralDirectory: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
		var endOffset = bytes.count - endOfCentralDirectory.count
		while endOffset >= 0, Array(bytes[endOffset..<endOffset + 4]) != endOfCentralDirectory {
			endOffset -= 1
		}
		guard endOffset >= 0 else { return [] }

		let totalEntries = u16(endOffset + 10)
		var offset = u32(endOffset + 16)
		let centralHeader: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
		var names: [String] = []
		for _ in 0..<totalEntries {
			guard offset + 46 <= bytes.count, Array(bytes[offset..<offset + 4]) == centralHeader else { break }
			let nameLength = u16(offset + 28)
			let extraLength = u16(offset + 30)
			let commentLength = u16(offset + 32)
			let nameStart = offset + 46
			guard nameStart + nameLength <= bytes.count else { break }
			names.append(String(bytes: bytes[nameStart..<nameStart + nameLength], encoding: .utf8) ?? "")
			offset = nameStart + nameLength + extraLength + commentLength
		}
		return names
	}
}
