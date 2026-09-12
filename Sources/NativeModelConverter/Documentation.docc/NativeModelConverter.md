# Native Model Converter

@Metadata {
    @DisplayName("Native Model Converter")
    @TechnologyRoot
}

Convert a validated native model graph package into a Core ML model without a Python runtime.

## Overview

`NativeModelConverter` is the on-device conversion boundary used by ML Browser for source models
that are not already Core ML. A Python or ONNX adapter creates a versioned `.aiagraph` directory;
the app validates its graph and constants, emits a Core ML neural-network `.mlmodel`, and then uses
the normal Core ML and Vision loading path.

The library is deliberately a converter, not an inference runtime. It does not execute PyTorch,
ONNX, or Python on iOS, and it never accepts an arbitrary path from the package manifest.

## Platform availability

The library product is declared for iOS 17 and later and macOS 14 and later. This covers ML
Browser's iPhone and iPad deployment plus its Mac, Designed for iPad distribution (the iOS runtime),
and it permits a native macOS app to depend on the same library. The converter does not currently
claim watchOS, tvOS, visionOS, or Mac Catalyst support because those platforms are neither declared
nor covered by the package tests. The command-line tools are development tools run on macOS.

## Import a package

Use the high-level converter for app imports. It enforces the fixed layout, rejects symbolic links,
applies byte limits, checks SHA-256 digests, validates the graph, checks every declared weight
range, and gives the client progress, diagnostics, and metrics.

```swift
import Foundation
import NativeModelConverter

let source = URL(fileURLWithPath: "/path/to/MobileNetV2.aiagraph")
let destination = URL(fileURLWithPath: "/path/to/converted.mlmodel")

let converter = NativeModelConverter()
let metrics = try await converter.convert(
    from: source,
    to: destination,
    sourceProvenance: NativeModelConversionSourceProvenance(
        originalModelFilename: "MobileNetV2.onnx",
        originalModelURL: "https://example.com/models/MobileNetV2.onnx"
    )
) { progress in
    Task { @MainActor in
        viewModel.conversionProgress = progress
    }
}
```

Run conversion away from the main actor. The app should retain the source package and its own
recovery journal until Core ML validation and model registration succeed, then load the generated
`.mlmodel` through its existing Core ML model-loading service.

`NativeModelConversionProgress` reports package stages and an exact completed/total operation count
while the model is emitted. A failed conversion throws `NativeModelConversionError`; its path-free
`diagnostic` has a stable code, phase, and message suitable for a support report.

After a job acquires exclusive access, every progress value also contains a sampled
`processMemoryUsage`. It is the physical footprint of the whole host process, not memory owned
solely by this package. The observed peak is sampled at progress boundaries and therefore is a
lower bound, not a continuous peak-memory measurement. Use the physical-device XCTest memory
benchmark to establish an enforceable device budget.

Cancellation is cooperative at package-stage and operation boundaries. It finishes with a stable
`cancelled` diagnostic and does not commit a partially serialized model. A host should regard any
output from a terminal cancelled or failed attempt as transient, delete it, and retain only its
source package and recovery report. One conversion serializes
operations in topological order; it is not an operation-parallel emitter. A process-global FIFO
actor queues all high-level `convert` calls and reports `waitingForExclusiveAccess` for jobs that
are waiting. Exactly one high-level job reads, emits, and writes at a time. Direct reader/emitter
APIs are low-level tooling APIs and do not enter that gate. Separate processes must coordinate
their own policy.

Normal conversion errors are typed. A same-process trap or app termination cannot be caught as a
Swift `Error`; the host app must persist a journal before conversion and mark an unfinished journal
as interrupted on a later launch, retaining only its last durable phase rather than guessing a
termination cause.

## Supported contract

Version 1 supports fixed positive tensor dimensions and Float32 or Float16 values. The current
emitter covers the MobileNetV2 classifier spine: grouped/depthwise convolution, batch
normalization, ReLU/ReLU6, residual add, global average pooling, flatten on axis 1, and linear.
The validator recognizes a wider future-facing operation set, but the emitter rejects every
operation that does not have compiler-backed coverage.

The package graph and weights are checksummed independently. Checksum failure, invalid graph
structure, unsupported operations, and invalid weight bounds are explicit errors; no fallback model
is emitted.

## Metadata preservation

An optional, checksummed `metadata.json` package artifact preserves source metadata. The converter
writes its exact bytes as `<model-name>.metadata.json` beside the generated `.mlmodel`, so arbitrary
nested source fields are never decoded and re-encoded away. Core ML's standard author, license,
version, and description fields are populated only with attribution that remains true for the
converted model. Source user-defined fields are namespaced, while target format, exact interface,
graph/weight checksums, and exporter provenance are derived by the converter itself.

Source claims such as image preprocessing, classifier labels, or task are not promoted to target
Core ML behavior unless the emitter has actually produced and tested the corresponding adapter.

The high-level API always records the input package filename in converted-model metadata. A host
can supply an original filename and an authoritative remote URL with
`NativeModelConversionSourceProvenance`; these are written as target provenance, while local
document-provider and sandbox paths must not be supplied because they are not portable provenance.

Every converted model records both source and native-converter identity in target provenance:
the graph producer name/version, graph format version, `NativeModelConverter` SemVer release, and
its artifact-affecting conversion revision. The source exporter controls its own version; increment
the native conversion revision whenever lowering, serialization, validation, or target metadata can
change output artifacts without changing the public Swift API.

## Conversion output

The current emitter writes one legacy neural-network `.mlmodel` file with its Float32 or Float16
weights embedded. It does not currently produce an `.mlpackage`; that is the future ML Program
output mode for external weight files. Core ML later compiles either authoring format into an
`.mlmodelc` runtime directory, which is not the portable artifact written by this package.

## Host export boundary

This package deliberately contains no UI or sharing code. ML Browser's host layer exports a
registered conversion as an explicit temporary ZIP containing the `.mlmodel`, its lossless metadata
sidecar when present, and its path-free conversion report. It does not automatically export the
retained original source package, because that is an independent user decision.

## Terminal tools

The package includes development executables, not app dependencies:

- `swift run -c release native-model-converter INPUT.aiagraph OUTPUT.mlmodel --report REPORT.json`
  converts one verified package and writes deterministic file-size and timing evidence.
- `swift run native-model-converter --version` prints the package release and conversion revision
  embedded into converted-model provenance.
- `swift run native-model-evaluator MODEL.mlmodel OUTPUT_DIRECTORY INPUT1.f32 [INPUT2.f32 ...]`
  compiles and loads a model once, evaluates one or more Float32 inputs through the macOS Core ML
runtime, and writes output files plus a manifest. It is used by terminal parity tests and does
not start a simulator.

## Observability and performance

The converter uses unified logging subsystem `com.aiarcheology.NativeModelConverter`, category
`Conversion`. Explicit `os_signpost(.begin/.end)` intervals cover the whole conversion, package
reading, and Core ML model emission; phase events make the work visible in Instruments without
logging a user path.

Release builds use safe Swift `-O` optimization (`swift run -c release` for the CLI). `-Ounchecked`
is not supported because the converter's validation checks are part of its safety contract.
Artifact size is not peak memory: use the opt-in `XCTClockMetric`/`XCTMemoryMetric` physical-device
benchmark in ML Browser before selecting a device-specific package budget or memory optimization.

## Verification

Use `swift test` for fast graph, package-integrity, serialization, compilation, and small numerical
fixtures. The source-model parity harness and its precision policy are maintained in the
repository's `NATIVE_MODEL_CONVERSION.md` guide.
