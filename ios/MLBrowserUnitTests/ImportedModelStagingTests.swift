//
//  ImportedModelStagingTests.swift
//  MLBrowserUnitTests
//
//  AIA-0654.
//

import XCTest
@testable import ML_Browser

/// These drive the whole staging operation, not its pieces.
///
/// The pieces were already covered, and that was the gap: the *order* they run in — stage, name,
/// screen, and actually throw the screen's verdict — was not exercised anywhere, so deleting the
/// rejection call from the import path, or passing every import off as a direct download, left the
/// entire suite green. Each test here fails against one of those mutations.
final class ImportedModelStagingTests: XCTestCase {
	private var documents: URL!
	private var incoming: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		documents = try XCTUnwrap(FileManager.default.documentDirectory)
		incoming = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("staging-in-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let incoming { try? FileManager.default.removeItem(at: incoming) }
		incoming = nil
		try super.tearDownWithError()
	}

	// MARK: - The guard actually fires on the real path

	func test_aCheckpointFromADirectDownload_isRejected() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write(torchZipBytes(), named: "CFNetworkDownload_ab12.tmp")

		XCTAssertThrowsError(
			try ImportedModelStaging.stage(
				sourceURL: source,
				configurationID: id,
				downloadURL: URL(string: "https://zenodo.org/records/15848663/files/OD_ringfort.tar?download=1"),
				origin: .directDownload
			)
		) { error in
			XCTAssertEqual(error as? ModelContainerImportError, .unsupportedCheckpoint)
		}
	}

	func test_aTarFromADirectDownload_isRejected() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write(tarBytes(), named: "CFNetworkDownload_cd34.tmp")

		XCTAssertThrowsError(
			try ImportedModelStaging.stage(
				sourceURL: source,
				configurationID: id,
				downloadURL: URL(string: "https://example.com/bundle.tar"),
				origin: .directDownload
			)
		) { error in
			XCTAssertEqual(error as? ModelContainerImportError, .unsupportedArchive)
		}
	}

	// MARK: - The origin gate, on the real path

	/// The mutation this catches: passing `.directDownload` unconditionally, or dropping the origin
	/// check. A catalog install of the very same bytes must still stage successfully.
	func test_theSameCheckpointFromTheCatalog_stagesWithoutComplaint() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write(torchZipBytes(), named: "model.mlmodel")

		let staged = try ImportedModelStaging.stage(
			sourceURL: source,
			configurationID: id,
			downloadURL: URL(string: "https://huggingface.co/x/resolve/main/model.mlmodel"),
			origin: .catalog
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
	}

	func test_theSameCheckpointFromFiles_stagesWithoutComplaint() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write(torchZipBytes(), named: "model.mlmodel")

		let staged = try ImportedModelStaging.stage(
			sourceURL: source, configurationID: id, downloadURL: nil, origin: .fileImport
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
	}

	// MARK: - Formats the app imports today are untouched

	func test_anOnnxDownload_isStagedAndKeepsItsName() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write([0x08, 0x01, 0x12, 0x07] + [UInt8](repeating: 0x2A, count: 900),
							   named: "CFNetworkDownload_ef56.tmp")

		let staged = try ImportedModelStaging.stage(
			sourceURL: source,
			configurationID: id,
			downloadURL: URL(string: "https://example.com/MobileNetV2.onnx"),
			origin: .directDownload
		)
		XCTAssertEqual(staged.lastPathComponent, "MobileNetV2.onnx", "the download's filename must be restored")
		XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
	}

	/// A resumed conversion hands staging an `.aiagraph` **directory**. It must survive that.
	func test_anAiagraphDirectory_isStagedNotRejected() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let package = incoming.appendingPathComponent("Graph.aiagraph", isDirectory: true)
		try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: package.appendingPathComponent("manifest.json"))

		let staged = try ImportedModelStaging.stage(
			sourceURL: package,
			configurationID: id,
			downloadURL: URL(string: "https://example.com/Graph.aiagraph"),
			origin: .directDownload
		)
		XCTAssertEqual(staged.lastPathComponent, "Graph.aiagraph")
	}

	// MARK: - Naming, through the real path

	/// The traversal payload, driven end to end: a hostile download URL must not place the staged
	/// file outside its configuration directory, and must not delete anything there.
	func test_aTraversalNameCannotEscapeTheConfigurationDirectory() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write([0x08, 0x01, 0x12, 0x07] + [UInt8](repeating: 0x2A, count: 900),
							   named: "CFNetworkDownload_99zz.tmp")
		let configuration = try XCTUnwrap(FileManager.deepConfigurationDirectory(id: id))
		try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
		let bystander = configuration.deletingLastPathComponent().appendingPathComponent("escape.onnx")
		try Data("do not delete me".utf8).write(to: bystander)
		defer { try? FileManager.default.removeItem(at: bystander) }

		let staged = try ImportedModelStaging.stage(
			sourceURL: source,
			configurationID: id,
			downloadURL: URL(string: "https://example.com/..%2Fescape.onnx"),
			origin: .directDownload
		)

		XCTAssertEqual(
			staged.deletingLastPathComponent().standardizedFileURL.path,
			configuration.standardizedFileURL.path,
			"the staged file must stay inside its own configuration directory"
		)
		XCTAssertEqual(
			try String(contentsOf: bystander, encoding: .utf8), "do not delete me",
			"the traversal target must be untouched"
		)
	}

	// MARK: - Helpers

	private func write(_ bytes: [UInt8], named name: String) throws -> URL {
		let url = incoming.appendingPathComponent(name)
		try Data(bytes).write(to: url)
		return url
	}

	private func removeConfiguration(_ id: UUID) {
		guard let directory = FileManager.deepConfigurationDirectory(id: id) else { return }
		try? FileManager.default.removeItem(at: directory)
	}

	/// A `torch.save` archive as far as the sniffer is concerned: a stored zip entry named
	/// `<root>/data.pkl`.
	private func torchZipBytes() -> [UInt8] {
		let name = [UInt8]("archive/data.pkl".utf8)
		var bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00]
		bytes += [0x00, 0x00, 0x00, 0x00] + [0x00, 0x00, 0x00, 0x00]
		bytes += [16, 0, 0, 0] + [16, 0, 0, 0]
		bytes += [UInt8(name.count & 0xFF), UInt8(name.count >> 8), 0x00, 0x00]
		bytes += name + [UInt8](repeating: 0x00, count: 16)
		return bytes
	}

	private func tarBytes() -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: 512)
		let name = [UInt8]("weights.bin".utf8)
		bytes.replaceSubrange(0..<name.count, with: name)
		let size = [UInt8]("00000000144\0".utf8)
		bytes.replaceSubrange(124..<(124 + size.count), with: size)
		let magic = [UInt8]("ustar\0".utf8) + [0x30, 0x30]
		bytes.replaceSubrange(257..<(257 + magic.count), with: magic)
		return bytes
	}
}
