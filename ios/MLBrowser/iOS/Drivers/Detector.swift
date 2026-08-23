//
//  Detector.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 26.09.23.
//

import CoreML
import Vision
import UIKit
import SwiftUI
import OSLog
import NativeModelConverter

enum DetectorError: Error {
	case loadError
	case coreModelLoadError
}

/// Atomic detection API (AIA-0374) — the mirror of `Classifying`, so both driver
/// families expose one race-free entry point and the `DeepDrivers` loops dispatch
/// on protocols, not concrete types.
protocol Detecting: DeepDriver {
	func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject]
}

actor Detector: Detecting {
    let id: UUID
    var params: DeepDriverParams
    private var objectDetectionModel: VNCoreMLModel?
    private var detectionRequest: VNCoreMLRequest?
    internal var observations: [VNObservation] = []
    private var handler: VNImageRequestHandler?
    private var ciImage: CIImage?
    private var mlModel: MLModel?
    /// Models opt in by carrying a complete, versioned input-sizing contract. The canvas constraint
    /// alone is deliberately insufficient: it cannot say whether Vision should crop, letterbox, or
    /// receive a host-prepared image.
    private var imageSizingContract: NativeModelImageSizingContract?
    
    init(params: DeepDriverParams) {
        self.id = params.entityId
        self.params = params
        LoggingPolicy.debug("Detector initialized with ID \(id)", logger: .drivers)
    }
    
    func updateConfiguration(_ params: DeepDriverParams) async {
        self.params = params
        LoggingPolicy.debug("Detector updated with ID \(id)", logger: .drivers)
    }
    
    func metadata() -> [MLModelMetadataKey: Any]? {
        mlModel?.modelDescription.metadata
    }

    /// The converter-owned metadata is value-only, unlike Core ML's full heterogeneous metadata
    /// dictionary. Keeping this small accessor Sendable lets diagnostics record the loaded artifact
    /// without moving `Any` values across the detector actor boundary.
    func creatorDefinedMetadata() -> [String: String] {
        mlModel?.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
    }
    
    func loadFile() async throws {
        guard let path = self.params.file else {
            LoggingPolicy.error("Detector loadFile failed: file path is nil", logger: .drivers)
            throw DetectorError.loadError
        }

        // Log file name only: container paths can embed user data (see LOGGING_GUIDE.md).
        LoggingPolicy.debug("Loading detector model from \(path.lastPathComponent)", logger: .drivers)

        guard let model = try await Self.loadModel(from: path, demo: params.demo, computeUnit: params.computeUnit) else {
            LoggingPolicy.error("Failed to load ML model from \(path.lastPathComponent)", logger: .drivers)
            throw DetectorError.loadError
        }

        LoggingPolicy.debug("Model successfully loaded from \(path.lastPathComponent)", logger: .drivers)

        let sizingContract = Self.imageSizingContract(for: model)
        mlModel = model
        imageSizingContract = sizingContract
        objectDetectionModel = try VNCoreMLModel(for: model)

        guard let detecionModel = objectDetectionModel else {
            LoggingPolicy.error("Failed to create VNCoreMLModel from loaded model", logger: .drivers)
            throw DetectorError.coreModelLoadError
        }

        detectionRequest = VNCoreMLRequest(model: detecionModel)
        detectionRequest?.imageCropAndScaleOption = sizingContract == nil ? .scaleFit : .scaleFill
    }

    func unload() async {
        ciImage = nil
        handler = nil
        detectionRequest = nil
        objectDetectionModel = nil
        mlModel = nil
        imageSizingContract = nil
        observations = []
        LoggingPolicy.debug("Detector unloaded", logger: .drivers)
    }

    /// The detect path's only entry point: image conversion, the region loop, coordinate
    /// remap, and cross-region dedup happen inside one actor-isolated call, so a concurrent
    /// frame can never swap the handler between processing and detection (the old
    /// `process`/`detect` pair raced exactly that way — magnified 6× by tiling).
    func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject] {
        guard let detectionRequest else {
            LoggingPolicy.debug("Detection skipped: detection request not initialized", logger: .drivers)
            return []
        }
        if let imageSizingContract {
            return detectPreSized(
                image: image,
                regions: regions,
                contract: imageSizingContract,
                using: detectionRequest
            )
        }
        return detectUsingVisionROI(image: image, regions: regions, using: detectionRequest)
    }

    /// The established path for normal detectors. Its `.scaleFit` request and Vision ROI behaviour
    /// stay intact; a model only takes the alternative path after declaring the contract above.
    private func detectUsingVisionROI(
        image: UIImage,
        regions: [CGRect],
        using detectionRequest: VNCoreMLRequest
    ) -> [DetectedObject] {
        guard let ciImage = CIImage(image: image) else {
            LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
            return []
        }
        // A thrown perform must not leak a region's ROI into the next frame.
        defer { detectionRequest.regionOfInterest = TileLayout.fullFrame }

        let handler = VNImageRequestHandler(ciImage: ciImage)
        let start = Date.now
        var collected: [DetectedObject] = []
        // Aggregated rather than logged per region (AIA-0602). With both tiling schemes on, a pass
        // covers 15 regions and this loop used to emit one line each, plus the summary — 16 lines
        // per pass, every three seconds, per detector. Since debug entries are now retained in
        // release builds, that one call site would have been the overwhelming majority of the
        // five-MiB budget and would have rolled the incident being investigated off the front of
        // the log. The slowest region is what the timing was ever read for.
        // Optional, not zero-defaulted: if every region throws, a default of index 0 at 0s would put
        // "slowest region 0 at 0.0s" in the log — a confident, wrong number, which in a diagnostic
        // record is worse than an absent one.
        var slowestRegion: (index: Int, seconds: TimeInterval)?
        var emptyRegionCount = 0
        var failedRegionCount = 0
        for (index, region) in regions.enumerated() {
            detectionRequest.regionOfInterest = region
            let regionStart = Date.now
            do {
                try handler.perform([detectionRequest])
            } catch {
                // One failed region must not abort the frame — and its results must not
                // be consumed: VNRequest retains the previous run's results on failure.
                LoggingPolicy.error("Failed to perform detection for region \(index)", error: error, logger: .drivers)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection", "region": "\(index)"])
                failedRegionCount += 1
                continue
            }
            let regionObservations = (detectionRequest.results as? [VNRecognizedObjectObservation]) ?? []
            for observation in regionObservations {
                guard let box = TileLayout.remap(observation.boundingBox, into: region) else { continue }
                collected.append(DetectedObject(
                    uuid: observation.uuid,
                    labels: observation.labels.map { DetectedObject.Label(identifier: $0.identifier, confidence: $0.confidence) },
                    confidence: observation.confidence,
                    boundingBox: box,
                    regionIndex: index
                ))
            }
            let regionSeconds = Date.now.timeIntervalSince(regionStart)
            if regionSeconds > (slowestRegion?.seconds ?? -1) {
                slowestRegion = (index, regionSeconds)
            }
            if regionObservations.isEmpty { emptyRegionCount += 1 }
        }
        let results = TileLayout.dedupAcrossRegions(collected)
        let slowest = slowestRegion.map { "slowest region \($0.index) at \($0.seconds)s" }
            ?? "no region completed"
        LoggingPolicy.debug(
            """
            Detection over \(regions.count) regions completed with \(results.count) objects \
            (\(collected.count) raw) in \(Date.now.timeIntervalSince(start))s; \
            \(slowest), \(emptyRegionCount) empty, \(failedRegionCount) failed
            """,
            logger: .drivers
        )
        return results
    }

    /// Runs a detector that declares the torchvision pre-sizing contract. Every tile is cropped from
    /// the original pixel image, resized and padded to the model's *exact* canvas, then handed to
    /// Vision as a full-frame `.scaleFill` image. Giving Vision an ROI or a non-matching input here
    /// would introduce a second resize and invalidate the device parity evidence.
    private func detectPreSized(
        image: UIImage,
        regions: [CGRect],
        contract: NativeModelImageSizingContract,
        using detectionRequest: VNCoreMLRequest
    ) -> [DetectedObject] {
        guard let source = Self.sourceImage(from: image) else {
            LoggingPolicy.warning("Failed to prepare detector source image", logger: .drivers)
            return []
        }

        detectionRequest.imageCropAndScaleOption = .scaleFill
        detectionRequest.regionOfInterest = TileLayout.fullFrame
        defer { detectionRequest.regionOfInterest = TileLayout.fullFrame }

        let start = Date.now
        var collected: [DetectedObject] = []
        var slowestRegion: (index: Int, seconds: TimeInterval)?
        var emptyRegionCount = 0
        var failedRegionCount = 0

        for (index, region) in regions.enumerated() {
            let regionStart = Date.now
            guard let prepared = Self.preparedRegion(
                source: source,
                region: region,
                contract: contract
            ) else {
                LoggingPolicy.error("Failed to prepare pre-sized detection region \(index)", logger: .drivers)
                failedRegionCount += 1
                continue
            }

            let handler = VNImageRequestHandler(cgImage: prepared.image, options: [:])
            do {
                try handler.perform([detectionRequest])
            } catch {
                // VNRequest keeps earlier results after a failed perform; never reuse them.
                LoggingPolicy.error("Failed to perform pre-sized detection for region \(index)", error: error, logger: .drivers)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "performPreSizedDetection", "region": "\(index)"])
                failedRegionCount += 1
                continue
            }

            let regionObservations = (detectionRequest.results as? [VNRecognizedObjectObservation]) ?? []
            for observation in regionObservations {
                guard let sourceBox = prepared.geometry.sourceBox(fromCanvasBox: Self.nativeRect(observation.boundingBox)),
                      let box = TileLayout.remap(Self.cgRect(sourceBox), into: prepared.effectiveRegion)
                else { continue }
                collected.append(Self.detectedObject(observation, box: box, regionIndex: index))
            }
            let regionSeconds = Date.now.timeIntervalSince(regionStart)
            if regionSeconds > (slowestRegion?.seconds ?? -1) {
                slowestRegion = (index, regionSeconds)
            }
            if regionObservations.isEmpty { emptyRegionCount += 1 }
        }

        let results = TileLayout.dedupAcrossRegions(collected)
        let slowest = slowestRegion.map { "slowest region \($0.index) at \($0.seconds)s" }
            ?? "no region completed"
        LoggingPolicy.debug(
            """
            Pre-sized detection over \(regions.count) regions completed with \(results.count) objects \
            (\(collected.count) raw) in \(Date.now.timeIntervalSince(start))s; \
            \(slowest), \(emptyRegionCount) empty, \(failedRegionCount) failed
            """,
            logger: .drivers
        )
        return results
    }

    /// The contract is only usable when the declared canvas is also one of this concrete model's
    /// image inputs. A stale or hand-edited metadata value therefore falls back to the generic path
    /// instead of silently asking Vision to rescale into an unrelated shape.
    private static func imageSizingContract(for model: MLModel) -> NativeModelImageSizingContract? {
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let contract = NativeModelImageSizingContract(userDefined: metadata) else { return nil }
        let hasMatchingCanvas = model.modelDescription.inputDescriptionsByName.values.contains {
            $0.imageConstraint?.pixelsWide == contract.canvasWidth &&
                $0.imageConstraint?.pixelsHigh == contract.canvasHeight
        }
        guard hasMatchingCanvas else {
            LoggingPolicy.warning("Ignoring detector image-sizing contract whose canvas does not match the model input", logger: .drivers)
            return nil
        }
        return contract
    }

    private struct SourceImage {
        let image: CGImage
        let size: NativeModelImageSize
    }

    private struct PreparedRegion {
        let image: CGImage
        let geometry: NativeModelImageSizing.Geometry
        let effectiveRegion: CGRect
    }

    private static func sourceImage(from image: UIImage) -> SourceImage? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        return SourceImage(image: cgImage, size: NativeModelImageSize(width: cgImage.width, height: cgImage.height))
    }

    /// Rasterises only the current tile. Holding a page-wide BGRA buffer plus a page-wide planar
    /// Float buffer would add 16 bytes per source pixel for the full pass; this keeps the temporary
    /// source allocation bounded to one region and lets NativeModelImageSizing sample BGRA directly.
    private static func bgraPixels(from image: CGImage) -> [UInt8]? {
        guard image.width > 0, image.height > 0,
              let bytesPerRow = checkedProduct(image.width, 4),
              let byteCount = checkedProduct(bytesPerRow, image.height)
        else { return nil }

        var bgra = [UInt8](repeating: 0, count: byteCount)
        guard let context = CGContext(
            data: &bgra,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // This is intentionally the same ImageIO-to-BGRA conversion as ADAFDetectorParityRunner.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bgra
    }

    private static func preparedRegion(
        source: SourceImage,
        region: CGRect,
        contract: NativeModelImageSizingContract
    ) -> PreparedRegion? {
        guard let cropPlan = NativeModelImageSizing.cropPlan(frame: source.size, region: nativeRect(region)),
              // CGImage's origin is the first raster row, matching CropPlan's top-left pixel rect.
              let croppedImage = source.image.cropping(to: CGRect(
                x: cropPlan.pixelRect.x,
                y: cropPlan.pixelRect.y,
                width: cropPlan.pixelRect.width,
                height: cropPlan.pixelRect.height
              )),
              let croppedBGRA = bgraPixels(from: croppedImage),
              let geometry = NativeModelImageSizing.geometry(
                source: NativeModelImageSize(width: cropPlan.pixelRect.width, height: cropPlan.pixelRect.height),
                minSize: contract.minSize,
                maxSize: contract.maxSize,
                canvas: contract.canvas
              ),
              let canvas = NativeModelImageSizing.size(interleavedBGRA: croppedBGRA, geometry: geometry),
              let pixels = NativeModelImageSizing.interleavedBGRA(from: canvas, size: contract.canvas),
              let image = cgImage(fromBGRA: pixels, size: contract.canvas)
        else { return nil }
        return PreparedRegion(image: image, geometry: geometry, effectiveRegion: cgRect(cropPlan.effectiveRegion))
    }

    private static func cgImage(fromBGRA pixels: [UInt8], size: NativeModelImageSize) -> CGImage? {
        guard let bytesPerRow = checkedProduct(size.width, 4),
              pixels.count == checkedProduct(bytesPerRow, size.height),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : product
    }

    private static func nativeRect(_ rect: CGRect) -> NativeModelNormalizedRect {
        NativeModelNormalizedRect(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            width: Double(rect.width), height: Double(rect.height)
        )
    }

    private static func cgRect(_ rect: NativeModelNormalizedRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func detectedObject(
        _ observation: VNRecognizedObjectObservation,
        box: CGRect,
        regionIndex: Int
    ) -> DetectedObject {
        DetectedObject(
            uuid: observation.uuid,
            labels: observation.labels.map {
                DetectedObject.Label(identifier: $0.identifier, confidence: $0.confidence)
            },
            confidence: observation.confidence,
            boundingBox: box,
            regionIndex: regionIndex
        )
    }

    func process(image: UIImage) async {
        // Clear stale state: a new frame must never report the previous frame's
        // detections, and a failed conversion must not leave the old handler around
        // (detect() would silently re-run the previous frame).
        observations = []
        handler = nil
        ciImage = CIImage(image: image)
        guard let ciImage else {
            LoggingPolicy.warning("Failed to create CIImage from UIImage", logger: .drivers)
            return
        }
        handler = VNImageRequestHandler(ciImage: ciImage)
    }

    func detect() async {
        guard let detectionRequest else {
            LoggingPolicy.debug("Detection skipped: detection request not initialized", logger: .drivers)
            return
        }

        // Without a handler there is no frame to process. Bail out before reading
        // detectionRequest.results — VNRequest retains the previous run's results,
        // so an optional-chained no-op perform would re-report the prior frame.
        guard let handler else {
            LoggingPolicy.debug("Detection skipped: no frame to process", logger: .drivers)
            observations = []
            return
        }

        do {
            try handler.perform([detectionRequest])
            // perform() completes synchronously, so results can be read directly here.
            // The previous Task-based completion proxy raced with readers and could
            // deliver the prior frame's observations.
            observations = (detectionRequest.results as? [VNRecognizedObjectObservation]) ?? []
            LoggingPolicy.debug("Detection completed with \(observations.count) observations", logger: .drivers)
        } catch {
            LoggingPolicy.error("Failed to perform detection", error: error, logger: .drivers)
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "performDetection"])
            observations = []
        }
        ciImage = nil
    }
    
    func run() async {
        await detect()
    }
}
