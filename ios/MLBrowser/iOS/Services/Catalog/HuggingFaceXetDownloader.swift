//
//  HuggingFaceXetDownloader.swift
//  AI Archeology
//
//  AIA-0413: public Hugging Face Xet artifact reconstruction.
//

import Foundation

/// Reconstructs a public Hugging Face file that is stored in Xet rather than behind the
/// ordinary Hub resolver. Xet returns a short-lived public access token, followed by compressed
/// chunks that must be assembled locally.
enum HuggingFaceXetDownloader {
	private static let progressUpdateIntervalBytes: Int64 = 1_000_000

	static func download(
		file: CatalogFile,
		session: URLSession,
		onBytesWritten: @escaping @Sendable (Int64) -> Void = { _ in }
	) async throws -> URL {
		guard let xetFile = file.xetFile else { throw CatalogError.invalidResponse }
		let access = try await request(XetAccess.self, from: xetFile.tokenURL, session: session)
		guard let casURL = URL(string: access.casURL) else { throw CatalogError.invalidResponse }

		var reconstructionRequest = URLRequest(
			url: casURL
				.appendingPathComponent("v1", isDirectory: true)
				.appendingPathComponent("reconstructions", isDirectory: true)
				.appendingPathComponent(xetFile.fileID)
		)
		reconstructionRequest.setValue("Bearer \(access.accessToken)", forHTTPHeaderField: "Authorization")
		let reconstruction = try await request(XetReconstruction.self, with: reconstructionRequest, session: session)

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
			throw CatalogError.network
		}

		do {
			let handle = try FileHandle(forWritingTo: destination)
			defer { try? handle.close() }

			var offsetIntoFirstRange = reconstruction.offsetIntoFirstRange
			var totalBytesWritten: Int64 = 0
			var lastReportedByteCount: Int64 = 0
			for term in reconstruction.terms {
				guard let fetch = reconstruction.fetchInfo[term.hash]?.first(where: { fetch in
					fetch.range.start <= term.range.start && fetch.range.end >= term.range.end
				}) else {
					throw CatalogError.invalidResponse
				}

				var dataRequest = URLRequest(url: fetch.url)
				dataRequest.setValue(
					"bytes=\(fetch.urlRange.start)-\(fetch.urlRange.end)",
					forHTTPHeaderField: "Range"
				)
				let data = try await requestData(with: dataRequest, session: session)
				let chunks = try XetXorbDecoder.chunks(from: data)
				guard chunks.count == fetch.range.end - fetch.range.start else {
					throw CatalogError.invalidResponse
				}

				let firstChunk = term.range.start - fetch.range.start
				let lastChunk = term.range.end - fetch.range.start
				guard firstChunk >= 0, lastChunk <= chunks.count else {
					throw CatalogError.invalidResponse
				}

				let skippedByteCountAtStart = offsetIntoFirstRange
				var writtenByteCount = 0
				for chunk in chunks[firstChunk..<lastChunk] {
					var output = chunk
					if offsetIntoFirstRange > 0 {
						let skippedByteCount = min(offsetIntoFirstRange, output.count)
						offsetIntoFirstRange -= skippedByteCount
						output.removeFirst(skippedByteCount)
					}
					handle.write(output)
					writtenByteCount += output.count
					totalBytesWritten += Int64(output.count)
					if totalBytesWritten - lastReportedByteCount >= progressUpdateIntervalBytes {
						lastReportedByteCount = totalBytesWritten
						onBytesWritten(totalBytesWritten)
					}
				}
				guard writtenByteCount == max(0, term.unpackedLength - skippedByteCountAtStart) else {
					throw CatalogError.invalidResponse
				}
			}
			if totalBytesWritten != lastReportedByteCount {
				onBytesWritten(totalBytesWritten)
			}
			return destination
		} catch {
			try? FileManager.default.removeItem(at: destination)
			throw error
		}
	}
}

private extension HuggingFaceXetDownloader {
	struct XetAccess: Decodable {
		let casURL: String
		let accessToken: String

		enum CodingKeys: String, CodingKey {
			case casURL = "casUrl"
			case accessToken
		}
	}

	struct XetReconstruction: Decodable {
		let offsetIntoFirstRange: Int
		let terms: [XetReconstructionTerm]
		let fetchInfo: [String: [XetFetchInfo]]

		enum CodingKeys: String, CodingKey {
			case offsetIntoFirstRange = "offset_into_first_range"
			case terms
			case fetchInfo = "fetch_info"
		}

	}

	struct XetReconstructionTerm: Decodable {
		let hash: String
		let unpackedLength: Int
		let range: XetIndexRange

		enum CodingKeys: String, CodingKey {
			case hash
			case unpackedLength = "unpacked_length"
			case range
		}
	}

	struct XetFetchInfo: Decodable {
		let range: XetIndexRange
		let url: URL
		let urlRange: XetByteRange

		enum CodingKeys: String, CodingKey {
			case range
			case url
			case urlRange = "url_range"
		}
	}

	struct XetIndexRange: Decodable {
		let start: Int
		let end: Int
	}

	struct XetByteRange: Decodable {
		let start: Int
		let end: Int
	}

	static func request<Response: Decodable>(
		_ responseType: Response.Type,
		from url: URL,
		session: URLSession
	) async throws -> Response {
		try await request(responseType, with: URLRequest(url: url), session: session)
	}

	static func request<Response: Decodable>(
		_ responseType: Response.Type,
		with request: URLRequest,
		session: URLSession
	) async throws -> Response {
		let data = try await requestData(with: request, session: session)
		do {
			return try JSONDecoder().decode(responseType, from: data)
		} catch {
			throw CatalogError.decoding
		}
	}

	static func requestData(with request: URLRequest, session: URLSession) async throws -> Data {
		do {
			let (data, response) = try await session.data(for: request)
			guard let response = response as? HTTPURLResponse,
				  (200...299).contains(response.statusCode) else {
				throw CatalogError.network
			}
			return data
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as CatalogError {
			throw error
		} catch {
			throw CatalogError.network
		}
	}
}

enum XetXorbDecoder {
	private static let lz4FrameMagic: UInt32 = 0x184D2204

	static func chunks(from data: Data) throws -> [Data] {
		var offset = 0
		var chunks: [Data] = []

		while offset < data.count {
			guard try byte(at: offset, in: data) == 0 else { throw CatalogError.invalidResponse }
			let compressedSize = try unsigned24(at: offset + 1, in: data)
			let compressionType = try byte(at: offset + 4, in: data)
			let uncompressedSize = try unsigned24(at: offset + 5, in: data)
			offset += 8

			guard compressedSize >= 0, offset + compressedSize <= data.count else {
				throw CatalogError.invalidResponse
			}
			let compressed = data.subdata(in: offset..<(offset + compressedSize))
			offset += compressedSize

			let unpacked: Data
			switch compressionType {
			case 0:
				unpacked = compressed
			case 1:
				unpacked = try decodeLZ4Frame(compressed, expectedSize: uncompressedSize)
			case 2:
				unpacked = try undoByteGrouping(
					decodeLZ4Frame(compressed, expectedSize: uncompressedSize),
					expectedSize: uncompressedSize
				)
			default:
				throw CatalogError.invalidResponse
			}

			guard unpacked.count == uncompressedSize else { throw CatalogError.invalidResponse }
			chunks.append(unpacked)
		}

		return chunks
	}

	private static func decodeLZ4Frame(_ data: Data, expectedSize: Int) throws -> Data {
		var offset = 0
		guard try unsigned32(at: offset, in: data) == lz4FrameMagic else {
			throw CatalogError.invalidResponse
		}
		offset += 4
		let flags = try byte(at: offset, in: data)
		offset += 1
		_ = try byte(at: offset, in: data) // Block descriptor
		offset += 1

		guard flags >> 6 == 1 else { throw CatalogError.invalidResponse }
		if flags & 0x08 != 0 { offset += 8 } // Content size
		if flags & 0x01 != 0 { offset += 4 } // Dictionary ID
		_ = try byte(at: offset, in: data) // Header checksum
		offset += 1

		var output = Data()
		output.reserveCapacity(expectedSize)
		while true {
			let blockHeader = try unsigned32(at: offset, in: data)
			offset += 4
			if blockHeader == 0 { break }
			let isUncompressed = blockHeader & 0x8000_0000 != 0
			let blockSize = Int(blockHeader & 0x7FFF_FFFF)
			guard blockSize > 0, offset + blockSize <= data.count else {
				throw CatalogError.invalidResponse
			}
			let block = data.subdata(in: offset..<(offset + blockSize))
			offset += blockSize

			if isUncompressed {
				output.append(block)
			} else {
				output.append(try decodeLZ4Block(block))
			}

			if flags & 0x10 != 0 { offset += 4 } // Block checksum
		}
		if flags & 0x04 != 0 { offset += 4 } // Content checksum

		guard offset == data.count, output.count == expectedSize else {
			throw CatalogError.invalidResponse
		}
		return output
	}

	private static func decodeLZ4Block(_ data: Data) throws -> Data {
		var sourceIndex = 0
		var output = [UInt8]()

		while sourceIndex < data.count {
			let token = Int(try byte(at: sourceIndex, in: data))
			sourceIndex += 1
			let literalLength = try extendedLength(token >> 4, data: data, sourceIndex: &sourceIndex)
			guard sourceIndex + literalLength <= data.count else { throw CatalogError.invalidResponse }
			output += data[sourceIndex..<(sourceIndex + literalLength)]
			sourceIndex += literalLength

			if sourceIndex == data.count { break }
			guard sourceIndex + 2 <= data.count else { throw CatalogError.invalidResponse }
			let matchOffset = Int(try byte(at: sourceIndex, in: data))
				| Int(try byte(at: sourceIndex + 1, in: data)) << 8
			sourceIndex += 2
			guard matchOffset > 0, matchOffset <= output.count else { throw CatalogError.invalidResponse }
			let matchLength = try extendedLength(token & 0x0F, data: data, sourceIndex: &sourceIndex) + 4
			for _ in 0..<matchLength {
				output.append(output[output.count - matchOffset])
			}
		}

		return Data(output)
	}

	private static func extendedLength(_ initial: Int, data: Data, sourceIndex: inout Int) throws -> Int {
		guard initial == 15 else { return initial }
		var length = initial
		while true {
			let value = Int(try byte(at: sourceIndex, in: data))
			sourceIndex += 1
			length += value
			if value != 255 { return length }
		}
	}

	private static func undoByteGrouping(_ data: Data, expectedSize: Int) throws -> Data {
		guard data.count == expectedSize else { throw CatalogError.invalidResponse }
		let baseSize = expectedSize / 4
		let remainder = expectedSize % 4
		var offsets = (0..<4).map { index in
			index * baseSize + min(index, remainder)
		}
		var result = Data(capacity: expectedSize)

		for index in 0..<expectedSize {
			let group = index % 4
			result.append(data[offsets[group]])
			offsets[group] += 1
		}
		return result
	}

	private static func byte(at index: Int, in data: Data) throws -> UInt8 {
		guard index >= 0, index < data.count else { throw CatalogError.invalidResponse }
		return data[index]
	}

	private static func unsigned24(at index: Int, in data: Data) throws -> Int {
		Int(try byte(at: index, in: data))
			| Int(try byte(at: index + 1, in: data)) << 8
			| Int(try byte(at: index + 2, in: data)) << 16
	}

	private static func unsigned32(at index: Int, in data: Data) throws -> UInt32 {
		UInt32(try byte(at: index, in: data))
			| UInt32(try byte(at: index + 1, in: data)) << 8
			| UInt32(try byte(at: index + 2, in: data)) << 16
			| UInt32(try byte(at: index + 3, in: data)) << 24
	}
}
