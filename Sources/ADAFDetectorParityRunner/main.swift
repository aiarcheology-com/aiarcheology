import CoreGraphics
import CoreML
import Foundation
import ImageIO
import NativeModelConverter
import Vision

private struct Report: Encodable {
	let checkpoint: String
	let parityProvenance: String
	let images: [ImageReport]

	struct ImageReport: Encodable {
		let path: String
		let sourceSize: Size
		let resizedSize: Size
		let canvasSize: Size
		let detections: [Detection]
	}

	struct Size: Encodable {
		let width: Int
		let height: Int
	}

	struct Detection: Encodable {
		/// `[x0, y0, x1, y1]`, source-image pixels with a top-left origin, matching torchvision.
		let box: [Double]
		let score: Double
	}
}

@main
struct ADAFDetectorParityRunner {
	static func main() {
		var arguments = Array(CommandLine.arguments.dropFirst())
		var sourceRGBURL: URL?
		var canvasRGBURL: URL?
		var modelOutputURL: URL?
		var compiledModelOutputURL: URL?
		while let option = arguments.first, option.hasPrefix("--") {
			guard arguments.count >= 2 else {
				fail("usage: adaf-detector-parity-runner [--source-rgb SOURCE.ppm] [--canvas-rgb CANVAS.ppm] [--model-output DETECTOR.mlmodel] CHECKPOINT OUTPUT.json IMAGE [IMAGE ...]")
			}
			switch option {
			case "--source-rgb": sourceRGBURL = URL(fileURLWithPath: arguments[1])
			case "--canvas-rgb": canvasRGBURL = URL(fileURLWithPath: arguments[1])
			case "--model-output": modelOutputURL = URL(fileURLWithPath: arguments[1])
			case "--compiled-model-output": compiledModelOutputURL = URL(fileURLWithPath: arguments[1])
			default: fail("unknown option: \(option)")
			}
			arguments.removeFirst(2)
		}
		guard arguments.count >= 3, (sourceRGBURL == nil && canvasRGBURL == nil) || arguments.count == 3 else {
			fail("usage: adaf-detector-parity-runner [--source-rgb SOURCE.ppm] [--canvas-rgb CANVAS.ppm] CHECKPOINT OUTPUT.json IMAGE [IMAGE ...]")
		}

		do {
			let checkpointURL = URL(fileURLWithPath: arguments[0])
			let reportURL = URL(fileURLWithPath: arguments[1])
			let imageURLs = arguments.dropFirst(2).map(URL.init(fileURLWithPath:))
			let temporaryDirectory = FileManager.default.temporaryDirectory
				.appendingPathComponent("adaf-detector-parity-\(UUID().uuidString)", isDirectory: true)
			try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

			let weightsURL = temporaryDirectory.appendingPathComponent("weights.bin")
			let modelURL = temporaryDirectory.appendingPathComponent("detector.mlmodel")
			let checkpoint = try PyTorchCheckpointReader.read(contentsOf: checkpointURL)
			let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: checkpointURL, to: weightsURL)
			let conversion = try NativeModelFasterRCNNRegistry.conversion(
				checkpoint: checkpoint, extraction: extraction, weightData: try Data(contentsOf: weightsURL)
			)
			try NativeModelCoreMLEmitter().emit(
				graph: conversion.graph,
				weights: conversion.weights,
				to: modelURL,
				detection: conversion.interface,
				detectionTarget: conversion.targetInfo,
				imagePreprocessing: .imageNetRGB,
				targetSemanticsIntent: conversion.targetSemanticsIntent,
				parityEvidence: .structurallyMatched
			)
			if let modelOutputURL {
				try FileManager.default.copyItem(at: modelURL, to: modelOutputURL)
			}
			let compiledURL = try MLModel.compileModel(at: modelURL)
			if let compiledModelOutputURL {
				try FileManager.default.copyItem(at: compiledURL, to: compiledModelOutputURL)
			}
			defer { try? FileManager.default.removeItem(at: compiledURL) }
			let configuration = MLModelConfiguration()
			configuration.computeUnits = .cpuOnly
			let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
			let visionModel = try VNCoreMLModel(for: model)

			let images = try imageURLs.map {
				try evaluate($0, sourceRGBURL: sourceRGBURL, canvasRGBURL: canvasRGBURL, using: visionModel)
			}
			let report = Report(
				checkpoint: checkpointURL.lastPathComponent,
				parityProvenance: NativeModelParityEvidence.structurallyMatched.rawValue,
				images: images
			)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
			try encoder.encode(report).write(to: reportURL, options: .atomic)
		} catch {
			fail(error.localizedDescription)
		}
	}

	private static func evaluate(
		_ imageURL: URL,
		sourceRGBURL: URL?,
		canvasRGBURL: URL?,
		using model: VNCoreMLModel
	) throws -> Report.ImageReport {
		let source = try decodeRGB(imageURL)
		if let sourceRGBURL {
			try writePortablePixmap(source.rgb, width: source.width, height: source.height, to: sourceRGBURL)
		}
		let sourceSize = NativeModelImageSize(width: source.width, height: source.height)
		let canvasSize = NativeModelImageSize(width: 1_344, height: 1_344)
		guard let geometry = NativeModelImageSizing.geometry(
			source: sourceSize, minSize: 800, maxSize: 1_333, canvas: canvasSize
		), let canvas = NativeModelImageSizing.size(source.rgb, channels: 3, geometry: geometry),
			let pixels = NativeModelImageSizing.interleavedBGRA(from: canvas, size: canvasSize),
			let image = cgImage(fromBGRA: pixels, width: canvasSize.width, height: canvasSize.height)
		else {
			throw RunnerError.invalidImage(imageURL.path)
		}
		if let canvasRGBURL {
			try writePortablePixmap(canvas, width: canvasSize.width, height: canvasSize.height, to: canvasRGBURL)
		}

		let request = VNCoreMLRequest(model: model)
		request.imageCropAndScaleOption = .scaleFill
		let handler = VNImageRequestHandler(cgImage: image, options: [:])
		try handler.perform([request])
		let observations = (request.results ?? []).compactMap { $0 as? VNRecognizedObjectObservation }
		let detections = observations.compactMap { observation -> Report.Detection? in
			guard let sourceBox = geometry.sourceBox(fromCanvasBox: NativeModelNormalizedRect(
				x: Double(observation.boundingBox.origin.x), y: Double(observation.boundingBox.origin.y),
				width: Double(observation.boundingBox.width), height: Double(observation.boundingBox.height)
			)) else { return nil }
			let x0 = sourceBox.x * Double(sourceSize.width)
			let x1 = (sourceBox.x + sourceBox.width) * Double(sourceSize.width)
			let y0 = (1 - sourceBox.y - sourceBox.height) * Double(sourceSize.height)
			let y1 = (1 - sourceBox.y) * Double(sourceSize.height)
			return Report.Detection(box: [x0, y0, x1, y1], score: Double(observation.confidence))
		}
		return Report.ImageReport(
			path: imageURL.path,
			sourceSize: .init(width: sourceSize.width, height: sourceSize.height),
			resizedSize: .init(width: geometry.resizedSize.width, height: geometry.resizedSize.height),
			canvasSize: .init(width: geometry.canvasSize.width, height: geometry.canvasSize.height),
			detections: detections
		)
	}

	private static func decodeRGB(_ url: URL) throws -> (rgb: [Float], width: Int, height: Int) {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else { throw RunnerError.invalidImage(url.path) }
		let width = image.width
		let height = image.height
		guard width > 0, height > 0 else { throw RunnerError.invalidImage(url.path) }
		let bytesPerRow = width * 4
		var bgra = [UInt8](repeating: 0, count: height * bytesPerRow)
		guard let context = CGContext(
			data: &bgra, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
		) else { throw RunnerError.invalidImage(url.path) }
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		let pixels = width * height
		var rgb = [Float](repeating: 0, count: pixels * 3)
		for pixel in 0..<pixels {
			rgb[pixel] = Float(bgra[pixel * 4 + 2])
			rgb[pixels + pixel] = Float(bgra[pixel * 4 + 1])
			rgb[pixels * 2 + pixel] = Float(bgra[pixel * 4])
		}
		return (rgb, width, height)
	}

	private static func cgImage(fromBGRA pixels: [UInt8], width: Int, height: Int) -> CGImage? {
		let data = Data(pixels)
		guard let provider = CGDataProvider(data: data as CFData) else { return nil }
		return CGImage(
			width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
			provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
		)
	}

	/// Writes the post-ImageIO, pre-resize pixels used by the model. The oracle reads these bytes rather
	/// than decoding the JPEG independently, so a platform decoder's rounding cannot masquerade as a
	/// Core ML/Torchvision prediction difference. PPM is intentionally uncompressed and dependency-free.
	private static func writePortablePixmap(_ planar: [Float], width: Int, height: Int, to url: URL) throws {
		let pixels = width * height
		guard planar.count == pixels * 3 else { throw RunnerError.invalidImage(url.path) }
		var data = Data("P6\n\(width) \(height)\n255\n".utf8)
		data.reserveCapacity(data.count + pixels * 3)
		for pixel in 0..<pixels {
			for channel in 0..<3 {
				let value = planar[channel * pixels + pixel].rounded()
				data.append(UInt8(min(255, max(0, value))))
			}
		}
		try data.write(to: url, options: .atomic)
	}
}

private enum RunnerError: LocalizedError {
	case invalidImage(String)

	var errorDescription: String? {
		switch self {
		case .invalidImage(let path): "could not decode or prepare image \(path)"
		}
	}
}

private func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("adaf-detector-parity-runner: \(message)\n".utf8))
	exit(1)
}
