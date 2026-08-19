//
//  ImportedCheckpointAnalyserTests.swift
//  MLBrowserUnitTests
//
//  AIA-0666.
//

import XCTest
@testable import ML_Browser

/// The seam AIA-0654 got wrong, tested from the outside.
///
/// M1's defect survived four reviews because its tests exercised the pieces and never the path: the
/// production call could be deleted and everything stayed green. So the tests here assert two things
/// the piece-level ones cannot — that the analyser runs **exactly once** on the one import that
/// qualifies and **never** on any other, and that real ADAF bytes driven through `stage` with no
/// injection at all come out as the model-specific rejection.
final class ImportedCheckpointAnalyserTests: XCTestCase {
	private var documents: URL!
	private var incoming: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		documents = try XCTUnwrap(FileManager.default.documentDirectory)
		incoming = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("analyser-in-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let incoming { try? FileManager.default.removeItem(at: incoming) }
		incoming = nil
		try super.tearDownWithError()
	}

	// MARK: - Real ADAF bytes, all the way through the production path

	/// No injected analyser, no stubbed verdict: the real committed bytes of `OD_ringfort.tar` go in
	/// and a message naming the model comes out. This is the test that would have caught M1.
	func test_realCheckpointBytes_reachTheModelSpecificRejection() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try ADAFTestCheckpoint.materialise("OD_ringfort", in: incoming)

		XCTAssertThrowsError(
			try ImportedModelStaging.stage(
				sourceURL: source,
				configurationID: id,
				downloadURL: URL(string: "https://zenodo.org/records/15848663/files/OD_ringfort.tar?download=1"),
				origin: .directDownload
			)
		) { error in
			XCTAssertEqual(
				error as? ModelContainerImportError,
				.adafDetectorNotConvertible(className: "Ringfort"),
				"the production analyser must name the model, not fall back to the generic message"
			)
		}
	}

	func test_realSegmentationBytes_reachThePermanentRefusal() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try ADAFTestCheckpoint.materialise("AO_HRNet", in: incoming)

		XCTAssertThrowsError(
			try ImportedModelStaging.stage(
				sourceURL: source, configurationID: id,
				downloadURL: URL(string: "https://example.com/AO_HRNet.tar"), origin: .directDownload
			)
		) { error in
			XCTAssertEqual(error as? ModelContainerImportError, .segmentationUnsupported)
		}
	}

	// MARK: - How often the analyser runs

	/// A direct download of a checkpoint is the one case that reads the file — once.
	func test_theAnalyserRunsExactlyOnceForADirectDownloadedCheckpoint() throws {
		let id = UUID()
		defer { removeConfiguration(id) }
		let source = try write(Self.torchZipBytes(), named: "CFNetworkDownload_ab12.tmp")
		var calls = 0

		XCTAssertThrowsError(try ImportedModelStaging.stage(
			sourceURL: source, configurationID: id,
			downloadURL: URL(string: "https://example.com/model.tar"), origin: .directDownload,
			analyser: { _ in calls += 1; return .segmentation }
		))
		XCTAssertEqual(calls, 1)
	}

	/// Every path the guard must not touch. A count of zero is the assertion: these imports must not
	/// even pay for opening the file, and an outcome-based test cannot tell "did not reject" from
	/// "read the file and decided not to reject".
	func test_theAnalyserNeverRunsForAnythingElse() throws {
		let cases: [(String, [UInt8], URL?, ModelAcquisitionSource)] = [
			("catalog install", Self.torchZipBytes(),
			 URL(string: "https://huggingface.co/x/resolve/main/m.mlmodel"), .catalog),
			("Files import", Self.torchZipBytes(), nil, .fileImport),
			("tar download", Self.tarBytes(), URL(string: "https://example.com/bundle.tar"), .directDownload),
			("onnx download", Self.onnxLikeBytes(),
			 URL(string: "https://example.com/MobileNetV2.onnx"), .directDownload)
		]

		for (label, bytes, downloadURL, origin) in cases {
			let id = UUID()
			defer { removeConfiguration(id) }
			let source = try write(bytes, named: "CFNetworkDownload_\(abs(label.hashValue % 9999)).tmp")
			var calls = 0
			_ = try? ImportedModelStaging.stage(
				sourceURL: source, configurationID: id, downloadURL: downloadURL, origin: origin,
				analyser: { _ in calls += 1; return .segmentation }
			)
			XCTAssertEqual(calls, 0, "\(label) must not read the file")
		}
	}

	// MARK: - Verdict to message

	func test_eachVerdictChoosesItsOwnRejection() {
		let mapping: [(ImportedCheckpointVerdict, ModelContainerImportError)] = [
			(.adafDetector(className: "Barrow"), .adafDetectorNotConvertible(className: "Barrow")),
			(.adafDetector(className: nil), .adafDetectorNotConvertible(className: nil)),
			(.segmentation, .segmentationUnsupported),
			(.unrecognisedModel(tensorCount: 12), .unrecognizedCheckpoint(tensorCount: 12)),
			// A checkpoint that could not be read keeps M1's honest generic message.
			(.unreadable, .unsupportedCheckpoint)
		]
		for (verdict, expected) in mapping {
			XCTAssertEqual(ImportedContainerRouting.refined(.unsupportedCheckpoint, by: verdict), expected)
		}
	}

	/// A tar rejection must not be refined into a checkpoint message, and must not read the file.
	func test_aNonCheckpointRejectionIsNeitherRefinedNorAnalysed() {
		var calls = 0
		let refined = ImportedContainerRouting.refined(.unsupportedArchive, by: {
			calls += 1
			return .segmentation
		}())
		XCTAssertEqual(refined, .unsupportedArchive)
		XCTAssertEqual(calls, 0, "the verdict is autoclosed so a tar never pays for a checkpoint read")
	}

	// MARK: - What the messages may and may not say

	/// Recognition is self-declaration: whoever writes the file writes its tensor table and its
	/// training `id`. The copy must describe what the file *claims*, never assert provenance, because
	/// M3 will attach a label to something a user then acts on.
	func test_noMessageClaimsProvenance() {
		let messages = [
			ModelContainerImportError.adafDetectorNotConvertible(className: "Ringfort").errorDescription,
			ModelContainerImportError.adafDetectorNotConvertible(className: nil).errorDescription,
			ModelContainerImportError.segmentationUnsupported.errorDescription,
			ModelContainerImportError.unrecognizedCheckpoint(tensorCount: 7).errorDescription
		]
		for message in messages {
			let text = try? XCTUnwrap(message)
			guard let text else { continue }
			XCTAssertTrue(
				text.contains("describes itself as") || text.contains("does not recognise"),
				"'\(text)' must say what the file claims, not what it is"
			)
			for claim in ["This is an ADAF", "This is a ", "verified", "authentic", "official"] {
				XCTAssertFalse(text.contains(claim), "'\(text)' asserts provenance via '\(claim)'")
			}
		}
	}

	/// Segmentation is refused permanently. "yet" would be wrong forever: the app has no
	/// representation for a per-pixel mask anywhere (AIA-0654 scope decision, 2026-08-19).
	func test_theSegmentationMessageNeverSaysYet() throws {
		let text = try XCTUnwrap(ModelContainerImportError.segmentationUnsupported.errorDescription)
		XCTAssertFalse(text.lowercased().contains("yet"), "'\(text)' implies segmentation is coming")
		XCTAssertTrue(text.contains("not supported"))
	}

	/// The detector message is the one that *should* say "yet" — conversion is M3.
	func test_theDetectorMessageSaysConversionIsNotSupportedYet() throws {
		let text = try XCTUnwrap(
			ModelContainerImportError.adafDetectorNotConvertible(className: "Ringfort").errorDescription
		)
		XCTAssertTrue(text.contains("Ringfort"))
		XCTAssertTrue(text.lowercased().contains("yet"))
	}

	/// The count is carried for diagnostics and logged, but never rendered: "%lld tensors" reads
	/// "1 tensors", and Czech, Polish, Russian, Ukrainian and Arabic need count-dependent forms that a
	/// single interpolated string cannot express. It is also a number no user can act on.
	func test_theUnrecognisedMessageDoesNotInterpolateACount() throws {
		let one = try XCTUnwrap(ModelContainerImportError.unrecognizedCheckpoint(tensorCount: 1).errorDescription)
		let many = try XCTUnwrap(ModelContainerImportError.unrecognizedCheckpoint(tensorCount: 12).errorDescription)
		XCTAssertEqual(one, many, "the message must not vary with a count it cannot pluralise")
		XCTAssertFalse(one.contains("1 tensors"), "'\(one)' is ungrammatical for a single tensor")
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

	/// A `torch.save` archive as far as the M1 sniffer is concerned — enough to be routed to the
	/// analyser, not enough to be read as a checkpoint.
	private static func torchZipBytes() -> [UInt8] {
		let name = [UInt8]("archive/data.pkl".utf8)
		var bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00]
		bytes += [0x00, 0x00, 0x00, 0x00] + [0x00, 0x00, 0x00, 0x00]
		bytes += [16, 0, 0, 0] + [16, 0, 0, 0]
		bytes += [UInt8(name.count & 0xFF), UInt8(name.count >> 8), 0x00, 0x00]
		bytes += name + [UInt8](repeating: 0x00, count: 16)
		return bytes
	}

	private static func tarBytes() -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: 512)
		let name = [UInt8]("weights.bin".utf8)
		bytes.replaceSubrange(0..<name.count, with: name)
		let size = [UInt8]("00000000144\0".utf8)
		bytes.replaceSubrange(124..<(124 + size.count), with: size)
		let magic = [UInt8]("ustar\0".utf8) + [0x30, 0x30]
		bytes.replaceSubrange(257..<(257 + magic.count), with: magic)
		return bytes
	}

	private static func onnxLikeBytes() -> [UInt8] {
		[0x08, 0x01, 0x12, 0x07] + [UInt8](repeating: 0x2A, count: 900)
	}
}

/// Rebuilds a real ADAF checkpoint on disk from the committed head and tail regions.
///
/// The published files are 518 MB and 862 MB, and the checkpoint reader cross-checks every storage
/// against the archive's central directory — so a test file has to have the original's *length* and
/// its original byte offsets, even though the reader never touches the 517 MB in between. Writing it
/// as a sparse file gives exactly that for about a megabyte of disk.
///
/// The regions come from `Tests/NativeModelConverterTests/Fixtures/ADAF/`, located from `#filePath`
/// rather than bundled: the same bytes already ship in the converter package's test bundle, and
/// copying 1.3 MB into a second bundle to read them twice buys nothing. A missing file fails the
/// test rather than skipping it.
enum ADAFTestCheckpoint {
	static func materialise(_ id: String, in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
		let fixtures = repositoryRoot()
			.appendingPathComponent("Tests/NativeModelConverterTests/Fixtures/ADAF", isDirectory: true)
		let manifestURL = fixtures.appendingPathComponent("ADAFCheckpointFixtures.json")
		let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
		let models = try XCTUnwrap(manifest?["models"] as? [[String: Any]], file: file, line: line)
		let model = try XCTUnwrap(models.first { $0["id"] as? String == id }, "no fixture '\(id)'", file: file, line: line)

		let totalLength = try XCTUnwrap(model["totalLength"] as? Int, file: file, line: line)
		let head = try XCTUnwrap(model["head"] as? [String: Any], file: file, line: line)
		let tail = try XCTUnwrap(model["tail"] as? [String: Any], file: file, line: line)

		let destination = directory.appendingPathComponent("CFNetworkDownload_\(id).tmp")
		FileManager.default.createFile(atPath: destination.path, contents: nil)
		let handle = try FileHandle(forWritingTo: destination)
		defer { try? handle.close() }
		for region in [head, tail] {
			let name = try XCTUnwrap(region["file"] as? String, file: file, line: line)
			let offset = try XCTUnwrap(region["offset"] as? Int, file: file, line: line)
			let bytes = try Data(contentsOf: fixtures.appendingPathComponent(name))
			try handle.seek(toOffset: UInt64(offset))
			try handle.write(contentsOf: bytes)
		}
		try handle.truncate(atOffset: UInt64(totalLength))
		return destination
	}

	private static func repositoryRoot(file: StaticString = #filePath) -> URL {
		// <root>/ios/MLBrowserUnitTests/ImportedCheckpointAnalyserTests.swift
		URL(fileURLWithPath: "\(file)")
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}
}
