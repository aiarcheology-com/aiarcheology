//
//  NativeModelConversionExporterTests.swift
//  MLBrowserUnitTests
//

import Foundation
import NativeModelConverter
import XCTest
@testable import MLBrowser

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
