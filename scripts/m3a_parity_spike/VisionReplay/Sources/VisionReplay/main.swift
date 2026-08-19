//
//  VisionReplay
//
//  Replays a Core ML detector the way the ML Browser iOS app runs it: wrapped in a
//  VNCoreMLModel, driven by a VNCoreMLRequest with .scaleFit and an optional region of
//  interest, executed by a VNImageRequestHandler. See README.md for why measuring
//  MLModel.predict instead would answer a different question.
//
//  Throwaway measurement code for AIA-0670.
//

import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

// --------------------------------------------------------------------------------------------
// Exit paths
// --------------------------------------------------------------------------------------------

let usage = """
usage: VisionReplay --model <path to .mlmodel|.mlpackage|.mlmodelc>
                    --image <path to png/jpg>
                    [--roi x,y,w,h] [--compute all|cpu] [--json <output path>]

  --model    Compiled with MLModel.compileModel(at:) unless it is already .mlmodelc.
  --image    Read with CIImage(contentsOf:); the handler is given the CIImage, no orientation,
             which is what Detector.swift does with CIImage(image:).
  --roi      Vision regionOfInterest, normalised, origin bottom-left, all four in 0...1.
  --compute  MLComputeUnits. Default is `all`, because the app leaves MLModelConfiguration()
             at its default; `cpu` selects .cpuOnly for a determinism comparison.
  --json     Also write the report here. It always goes to stdout.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("VisionReplay: \(message)\n".utf8))
    exit(code)
}

func failUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("VisionReplay: \(message)\n\n\(usage)\n".utf8))
    exit(64)
}

// --------------------------------------------------------------------------------------------
// Arguments
// --------------------------------------------------------------------------------------------

func parseROI(_ text: String) -> CGRect {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard parts.count == 4 else { failUsage("--roi wants exactly four comma-separated numbers, got \(parts.count)") }
    let numbers = parts.compactMap { Double($0) }
    guard numbers.count == parts.count, numbers.allSatisfy({ $0.isFinite }) else {
        failUsage("--roi values must all be finite numbers: \(text)")
    }
    let values = numbers
    let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    // Vision rejects a region outside the unit rect at perform() time with an opaque error;
    // catching it here keeps a typo from looking like a model failure.
    guard rect.width > 0, rect.height > 0 else { failUsage("--roi width and height must be positive: \(text)") }
    guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1.0000001, rect.maxY <= 1.0000001 else {
        failUsage("--roi must lie inside the normalised unit rect: \(text)")
    }
    // The tolerance above exists so that `0.5,0,0.5,1` typed as three decimals is not rejected for
    // arriving at 1.0000000001 — but accepting a value and then handing Vision the unclamped
    // version reintroduces the opaque perform()-time failure this check exists to prevent. So the
    // rectangle is clamped to the unit rect before it leaves.
    let maxX = min(rect.maxX, 1.0)
    let maxY = min(rect.maxY, 1.0)
    return CGRect(x: rect.minX, y: rect.minY, width: maxX - rect.minX, height: maxY - rect.minY)
}

var modelPath: String?
var imagePath: String?
var jsonPath: String?
var regionOfInterest: CGRect?
var computeUnits = MLComputeUnits.all
var computeUnitsLabel = "all"

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty { failUsage("no arguments given") }

var index = 0
while index < arguments.count {
    let flag = arguments[index]
    func value() -> String {
        guard index + 1 < arguments.count else { failUsage("\(flag) needs a value") }
        index += 1
        return arguments[index]
    }
    switch flag {
    case "--model": modelPath = value()
    case "--image": imagePath = value()
    case "--json": jsonPath = value()
    case "--roi": regionOfInterest = parseROI(value())
    case "--compute":
        let requested = value()
        switch requested {
        case "all":
            computeUnits = .all
            computeUnitsLabel = "all"
        case "cpu":
            computeUnits = .cpuOnly
            computeUnitsLabel = "cpuOnly"
        default:
            failUsage("--compute takes `all` or `cpu`, got `\(requested)`")
        }
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        failUsage("unknown argument `\(flag)`")
    }
    index += 1
}

guard let modelPath else { failUsage("--model is required") }
guard let imagePath else { failUsage("--image is required") }

let modelURL = URL(fileURLWithPath: (modelPath as NSString).expandingTildeInPath)
let imageURL = URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath)

// .mlpackage and .mlmodelc are directories, so existence has to be checked the directory-tolerant way.
guard FileManager.default.fileExists(atPath: modelURL.path) else {
    fail("model not found at \(modelURL.path)")
}
guard FileManager.default.fileExists(atPath: imageURL.path) else {
    fail("image not found at \(imageURL.path)")
}

// --------------------------------------------------------------------------------------------
// JSON helpers
// --------------------------------------------------------------------------------------------

/// JSONSerialization throws on a non-finite Double, and a NaN box is exactly the kind of model
/// output this harness exists to catch, so it is reported as null rather than crashing the run.
func number(_ value: Double) -> Any {
    value.isFinite ? value : NSNull()
}

func rectFields(_ rect: CGRect) -> [String: Any] {
    [
        "x": number(Double(rect.origin.x)),
        "y": number(Double(rect.origin.y)),
        "width": number(Double(rect.size.width)),
        "height": number(Double(rect.size.height))
    ]
}

func fourCharacterCode(_ value: OSType) -> String? {
    let bytes = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                 UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
    // The guard above already restricts these to printable ASCII, so the failable initialiser
    // cannot actually fail here — it is used because the function's contract is already optional
    // and because it keeps the byte-to-text conversion explicit about its encoding.
    return String(bytes: bytes, encoding: .ascii)
}

func featureTypeName(_ type: MLFeatureType) -> String {
    // An explicit switch, not a reflected type name: symbol names are not a stable contract.
    // A plain `default` (rather than `@unknown default`) keeps this warning-free against SDK
    // enum cases newer than the deployment target.
    switch type {
    case .invalid: return "invalid"
    case .int64: return "int64"
    case .double: return "double"
    case .string: return "string"
    case .image: return "image"
    case .multiArray: return "multiArray"
    case .dictionary: return "dictionary"
    case .sequence: return "sequence"
    default: return "other(\(type.rawValue))"
    }
}

func multiArrayDataTypeName(_ type: MLMultiArrayDataType) -> String {
    switch type {
    case .double: return "double"
    case .float64: return "float64"
    case .float32: return "float32"
    case .float16: return "float16"
    case .int32: return "int32"
    default: return "other(\(type.rawValue))"
    }
}

func describe(_ feature: MLFeatureDescription) -> [String: Any] {
    var report: [String: Any] = [
        "name": feature.name,
        "type": featureTypeName(feature.type),
        "optional": feature.isOptional
    ]
    if let constraint = feature.imageConstraint {
        var image: [String: Any] = [
            "pixelsWide": constraint.pixelsWide,
            "pixelsHigh": constraint.pixelsHigh,
            "pixelFormatType": Int(constraint.pixelFormatType)
        ]
        if let code = fourCharacterCode(constraint.pixelFormatType) { image["pixelFormatFourCC"] = code }
        report["imageConstraint"] = image
    }
    if let constraint = feature.multiArrayConstraint {
        report["multiArrayConstraint"] = [
            "shape": constraint.shape.map { $0.intValue },
            "dataType": multiArrayDataTypeName(constraint.dataType)
        ]
    }
    return report
}

func describe(_ value: MLFeatureValue) -> [String: Any] {
    var report: [String: Any] = ["type": featureTypeName(value.type)]
    if let array = value.multiArrayValue {
        report["shape"] = array.shape.map { $0.intValue }
        report["strides"] = array.strides.map { $0.intValue }
        report["dataType"] = multiArrayDataTypeName(array.dataType)
        report["count"] = array.count
    }
    if let dictionary = value.dictionaryValue as? [String: NSNumber] {
        report["dictionaryKeyCount"] = dictionary.count
    }
    if value.type == .string { report["stringValue"] = value.stringValue }
    if value.type == .int64 { report["int64Value"] = value.int64Value }
    if value.type == .double { report["doubleValue"] = number(value.doubleValue) }
    return report
}

// --------------------------------------------------------------------------------------------
// Model
// --------------------------------------------------------------------------------------------

let alreadyCompiled = modelURL.pathExtension.lowercased() == "mlmodelc"
let compiledURL: URL
if alreadyCompiled {
    compiledURL = modelURL
} else {
    do {
        // No `await`: the overload the compiler picks here is the synchronous one, and asking
        // for it explicitly keeps the build warning-free.
        compiledURL = try MLModel.compileModel(at: modelURL)
    } catch {
        fail("could not compile \(modelURL.lastPathComponent): \(error.localizedDescription)")
    }
}

let configuration = MLModelConfiguration()
configuration.computeUnits = computeUnits

let model: MLModel
do {
    model = try await MLModel.load(contentsOf: compiledURL, configuration: configuration)
} catch {
    fail("could not load \(compiledURL.lastPathComponent): \(error.localizedDescription)")
}

let visionModel: VNCoreMLModel
do {
    visionModel = try VNCoreMLModel(for: model)
} catch {
    // This is the first place a model that Core ML accepts can still be rejected by Vision.
    fail("VNCoreMLModel refused the model: \(error.localizedDescription)")
}

let request = VNCoreMLRequest(model: visionModel)
request.imageCropAndScaleOption = .scaleFit  // Detector.swift:76
if let regionOfInterest { request.regionOfInterest = regionOfInterest }

// --------------------------------------------------------------------------------------------
// Image
// --------------------------------------------------------------------------------------------

guard let ciImage = CIImage(contentsOf: imageURL) else {
    fail("could not read \(imageURL.lastPathComponent) as an image")
}
let pixelWidth = Double(ciImage.extent.width)
let pixelHeight = Double(ciImage.extent.height)
guard pixelWidth > 0, pixelHeight > 0 else {
    fail("\(imageURL.lastPathComponent) has an empty extent")
}

// Recorded, not applied: CIImage(contentsOf:) leaves EXIF orientation on the metadata, and so
// does the app's CIImage(image:). If a file carries anything but 1, that is a divergence source
// worth seeing in the report rather than silently correcting here.
var exifOrientation: Int?
if let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
   let orientation = properties[kCGImagePropertyOrientation] as? Int {
    exifOrientation = orientation
}

// --------------------------------------------------------------------------------------------
// Run
// --------------------------------------------------------------------------------------------

let handler = VNImageRequestHandler(ciImage: ciImage)
let started = DispatchTime.now()
do {
    try handler.perform([request])
} catch {
    fail("VNImageRequestHandler.perform failed: \(error.localizedDescription)")
}
let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

// --------------------------------------------------------------------------------------------
// Observations
// --------------------------------------------------------------------------------------------

/// TileLayout.remap, verbatim in behaviour (DetectionTiling.swift:113). Under a region of
/// interest Vision reports boxes relative to the region, so this is what the app applies before
/// anything downstream — including its cross-region dedup — ever sees them.
func remap(_ box: CGRect, into region: CGRect) -> CGRect? {
    let full = CGRect(
        x: region.minX + box.minX * region.width,
        y: region.minY + box.minY * region.height,
        width: box.width * region.width,
        height: box.height * region.height
    )
    guard full.minX.isFinite, full.minY.isFinite, full.width.isFinite, full.height.isFinite else { return nil }
    guard full.isEmpty == false else { return nil }
    guard CGRect(x: 0, y: 0, width: 1, height: 1).contains(full) == false else { return full }
    let clamped = full.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard clamped.isEmpty == false else { return nil }
    return clamped
}

/// Vision's origin is bottom-left; every pixel consumer in the app's UI layer is top-left.
func pixelRectTopLeft(_ box: CGRect) -> [String: Any] {
    [
        "x": number(Double(box.minX) * pixelWidth),
        "y": number((1.0 - Double(box.maxY)) * pixelHeight),
        "width": number(Double(box.width) * pixelWidth),
        "height": number(Double(box.height) * pixelHeight)
    ]
}

let results = request.results ?? []
var observationReports: [[String: Any]] = []
var kindCounts: [String: Int] = [:]

for observation in results {
    // Classified by `is`/`as?`, never by a reflected type name.
    if let recognized = observation as? VNRecognizedObjectObservation {
        kindCounts["VNRecognizedObjectObservation", default: 0] += 1
        var report: [String: Any] = [
            "kind": "VNRecognizedObjectObservation",
            "uuid": recognized.uuid.uuidString,
            "confidence": number(Double(recognized.confidence)),
            "boundingBoxNormalizedBottomLeft": rectFields(recognized.boundingBox),
            "labels": recognized.labels.map {
                ["identifier": $0.identifier, "confidence": number(Double($0.confidence))] as [String: Any]
            }
        ]
        let fullFrame: CGRect?
        if let regionOfInterest {
            fullFrame = remap(recognized.boundingBox, into: regionOfInterest)
            report["boundingBoxFullFrameNormalizedBottomLeft"] = fullFrame.map(rectFields) ?? NSNull()
        } else {
            fullFrame = recognized.boundingBox
        }
        report["boundingBoxPixelsTopLeft"] = fullFrame.map(pixelRectTopLeft) ?? NSNull()
        observationReports.append(report)
    } else if let classification = observation as? VNClassificationObservation {
        kindCounts["VNClassificationObservation", default: 0] += 1
        observationReports.append([
            "kind": "VNClassificationObservation",
            "uuid": classification.uuid.uuidString,
            "identifier": classification.identifier,
            "confidence": number(Double(classification.confidence))
        ])
    } else if let featureValue = observation as? VNCoreMLFeatureValueObservation {
        // Not a failure, and the most informative outcome there is: Vision found no detector
        // interface to present, so it handed back the raw tensors instead of boxes.
        kindCounts["VNCoreMLFeatureValueObservation", default: 0] += 1
        observationReports.append([
            "kind": "VNCoreMLFeatureValueObservation",
            "uuid": featureValue.uuid.uuidString,
            "confidence": number(Double(featureValue.confidence)),
            "featureName": featureValue.featureName,
            "featureValue": describe(featureValue.featureValue)
        ])
    } else {
        kindCounts["other", default: 0] += 1
        observationReports.append([
            "kind": "other",
            "uuid": observation.uuid.uuidString,
            "confidence": number(Double(observation.confidence))
        ])
    }
}

let presentsDetectorInterface = kindCounts["VNRecognizedObjectObservation", default: 0] > 0

var report: [String: Any] = [
    "model": [
        "path": modelURL.path,
        "compiledPath": compiledURL.path,
        "compiledHere": alreadyCompiled == false,
        "inputs": model.modelDescription.inputDescriptionsByName.keys.sorted().compactMap {
            model.modelDescription.inputDescriptionsByName[$0].map(describe)
        },
        "outputs": model.modelDescription.outputDescriptionsByName.keys.sorted().compactMap {
            model.modelDescription.outputDescriptionsByName[$0].map(describe)
        }
    ],
    "vision": [
        "computeUnitsRequested": computeUnitsLabel,
        "imageCropAndScaleOption": "scaleFit",
        "regionOfInterest": regionOfInterest.map(rectFields) ?? NSNull(),
        "presentsVisionDetectorInterface": presentsDetectorInterface
    ],
    "image": [
        "path": imageURL.path,
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
        "exifOrientation": (exifOrientation ?? NSNull()) as Any
    ],
    "elapsedMilliseconds": number(elapsedMilliseconds),
    "observationCount": results.count,
    "observationKindCounts": kindCounts,
    "observations": observationReports,
    "coordinateConvention": """
    boundingBoxNormalizedBottomLeft is exactly what Vision returned, and under a region of \
    interest it is relative to that region. boundingBoxFullFrameNormalizedBottomLeft applies \
    TileLayout.remap, which is what the app does next. boundingBoxPixelsTopLeft is derived from \
    the full-frame box with the Y axis flipped into source-image pixels.
    """
]
if presentsDetectorInterface == false && results.isEmpty == false {
    report["finding"] = """
    Vision returned no VNRecognizedObjectObservation. The model loads and runs, but it does not \
    present a Vision-compatible detector interface, so the app's Detector would cast the results \
    to [VNRecognizedObjectObservation], get nil, and report zero detections regardless of what \
    the tensors contain.
    """
}

let data: Data
do {
    data = try JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
} catch {
    fail("could not serialise the report: \(error.localizedDescription)")
}

FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))

if let jsonPath {
    let outputURL = URL(fileURLWithPath: (jsonPath as NSString).expandingTildeInPath)
    do {
        try data.write(to: outputURL)
    } catch {
        fail("could not write \(outputURL.path): \(error.localizedDescription)")
    }
}
