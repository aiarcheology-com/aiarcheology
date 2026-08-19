# VisionReplay

Throwaway measurement code for AIA-0670. It runs a Core ML detector through the exact layer the ML
Browser app runs it through — `VNCoreMLModel`, a `VNCoreMLRequest` with `.scaleFit` and an optional
region of interest, executed by a `VNImageRequestHandler` — and prints what came back, in Vision's
own coordinates and again in source-image pixels. Nothing else in this spike observes that layer.

## Why a parity number taken at `MLModel.predict` does not settle the question

The app never calls `predict`. `Detector.loadFile()` builds a `VNCoreMLModel` from the loaded
`MLModel` and wraps it in a `VNCoreMLRequest` whose `imageCropAndScaleOption` is `.scaleFit`
(`Detector.swift:68-76`); `Detector.detect(image:regions:)` then sets a `regionOfInterest` per tile
and calls `handler.perform` (`Detector.swift:120-149`). Between a Python tensor comparison and a box
the user sees there is therefore a whole stack of Apple behaviour that the tensor comparison never
touched, and each layer of it can move a box on its own.

Vision does its own resizing. `.scaleFit` letterboxes the source into the model's 640×640 input,
which is not the same resampling, and not the same padding, as `cv2.resize` or a torchvision
transform — so an input scaling that matched to the last significant digit in Python can still enter
the model differently here. Vision then hands back normalised coordinates whose origin is the
*bottom* left, while every pixel consumer downstream of it is top-left, and under a region of
interest those coordinates are relative to the region rather than to the image; the app corrects for
this with `TileLayout.remap` (`DetectionTiling.swift:113`), and this harness reports both the raw box
and the remapped one so a disagreement can be attributed to one or the other. After that the app
still runs `TileLayout.dedupAcrossRegions`, which can delete a correct box because a *different*
region produced an overlapping one — a stage that exists nowhere in a `predict`-level comparison.

There is one more failure the Python side cannot see at all. `Detector` reads its results as
`detectionRequest.results as? [VNRecognizedObjectObservation]` and treats a failed cast as zero
detections. A model whose tensors are numerically perfect but which does not present a Vision
detector interface — no NMS pipeline, no class-label annotation — produces
`VNCoreMLFeatureValueObservation`s instead, the cast yields nil, and the app displays nothing while
every parity metric stays green. That case is not an error here: the report names the observation
kind, dumps the feature shapes, and sets a `finding` string, because it is the most consequential
thing this harness can discover.

## The compute-unit trap, measured

`DeepDriver.loadModel(from:demo:)` passes a bare `MLModelConfiguration()` (`DeepDriver.swift:70`),
which means `.all`: the OS picks the Neural Engine or GPU as it sees fit. That is why `--compute`
defaults to `all` here rather than to the reproducible `.cpuOnly` a measurement harness would
otherwise prefer — the default has to be the app's default, and the report always states which was
used. The difference is not academic. On yolov8n against the standard bus image, `all` and `cpuOnly`
find the same five objects, but `all` returns confidences on the fp16 grid (0.8828125, and label
confidences saturated to exactly 1.0 and 0.0) where `cpuOnly` returns 0.8818327188 and 0.9998908043,
and the box edges disagree in the fourth decimal of normalised space, which is most of a pixel on a
1080-pixel image. Any tolerance chosen from CPU-side numbers is therefore too tight for what the app
actually executes.

EXIF orientation is recorded and deliberately not applied, for the same reason: `CIImage(contentsOf:)`
does not apply it and neither does the app's `CIImage(image:)`, so silently correcting it here would
hide a divergence rather than measure one. If the reported `exifOrientation` is anything but 1, treat
the run as suspect instead of trusting the boxes.

## Running it

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    swift build
    .build/debug/VisionReplay --model ~/yolov8n.mlpackage --image bus.jpg [--roi 0,0,0.5,1] [--compute cpu] [--json out.json]

`--model` takes `.mlmodel`, `.mlpackage`, or an already-compiled `.mlmodelc`; anything but the last
goes through `MLModel.compileModel(at:)` first, exactly as `DeepDriver` does. The report goes to
stdout always and to `--json` as well when asked. A usage mistake exits 64, a genuine failure — file
missing, model won't compile, Vision refuses it, `perform` throws — exits 1 with the reason on
stderr; an empty detection list is a result, not a failure, and exits 0.

The `boundingBoxNormalizedBottomLeft` field is verbatim Vision output.
`boundingBoxFullFrameNormalizedBottomLeft` appears only under `--roi` and is the app's remap applied
to it. `boundingBoxPixelsTopLeft` is derived from the full-frame box with the Y axis flipped, and is
the only field directly comparable to a Python detection expressed in image pixels.

One path is present but unexercised on this machine: no model available locally returns
`VNCoreMLFeatureValueObservation`, so that branch has been written but not observed firing. The
detector branch, the classifier branch, the region-of-interest remap and both compute settings have
all been run.
