# M3a findings — Faster R-CNN to Core ML parity (AIA-0670)

**Verdict: GO, conditionally.** Every operation the ticket doubted is expressible in NN-spec and
reproduces torchvision to far below the threshold at which ADAF's own pipeline could notice. The
conditions are not caveats on that result; they are four specific design commitments M3b/M3c must
make, each forced by a number below, plus one genuinely unresolved item.

Measured on all four `OD_*` checkpoints against the vendored aitlas wheel, on ADAF's own SLRM
figures. 16 verdicts, 0 FAIL, 0 UNDERPOWERED (`results/verdicts.json`). Thresholds were fixed in
`decision_rule.py` with the reason for each value, and that file discloses that exploratory probes
preceded it.

---

## The four exit criteria

### 1. RoIAlign — PASS, with the construction named

The ticket expected this to be the likely "no". It is not, but only because the naive experiment is
wrong. `CropResize` takes **one** bilinear sample per output cell where torchvision's
`sampling_ratio=2` averages 2×2 per bin, so comparing a bare 7×7 crop against `roi_align` measures a
residual that the *construction* created. The layer's own docstring says RoI Align is this layer
**followed by a pooling layer**.

Rather than rank residuals, each operator's sampling grid was recovered exactly: with channel 0
carrying `f(h,w)=h` and channel 1 carrying `f(h,w)=w`, bilinear interpolation is exact for an affine
function and the average over symmetric sample positions equals the value at their centroid — so the
output *is* the effective sample position, whatever the sampling ratio.

| | |
|-|-|
| `ROI_ALIGN_MODE`, corner coordinates | grid matches torchvision to **1.91e-06 feature px** |
| Fitted affine `reference = scale·candidate + offset` | **scale 1.0, offset 0.0 — the identity** |
| `UPSAMPLE_MODE` | 2.70 px off — the number a naive sweep would have reported as "Core ML cannot do RoIAlign" |
| Harness sensitivity (mutation test) | packing width-first while declaring height-first moves the grid **6.46 px**, so the harness can tell a coordinate bug from an operator difference |

No ROI pre-compensation is needed. Substituted into the real pipeline, the detection set is unchanged
and boxes move **≤ 0.00005 px** across all four models.

### 2. Static shapes and fixed top-K — PASS, and it sets K

Retention is the wrong instrument: torchvision is already capped at 1000/1000/100, so on this imagery
every K in a plausible sweep retains everything and the curve is a flat line. The **rank margin** —
which proposal each surviving detection came from — is what a cut actually threatens.

| model | detections | worst contributing proposal rank |
|-|-|-|
| OD_ringfort | 2 | 45 of 997 |
| OD_barrow | 3 | 7 of 1000 |
| OD_enclosure | 8 | **102** of 1000 |
| OD_AO | 1 | 0 of 1000 |

Every detection across all four models originates in a proposal ranked ≤ 102. Sweeping the pre-NMS
cut alone (post-NMS held fixed), oracle-set agreement is 1.0 down to K=128 and falls to **0.875 at
K=64** on OD_enclosure. So **K=128** is the measured floor, and it is not an accuracy decision — it is
a memory one:

| K | ROI activations, all 4 levels, fp32 |
|-|-|
| 1000 (torchvision default) | **765.6 MiB** |
| 256 | 196.0 MiB |
| **128** | **98.0 MiB** |
| 64 | 49.0 MiB (loses 12.5% of OD_enclosure's set) |

Per-ROI level assignment is data dependent and a data-dependent gather has no fixed output shape, so
a static graph must crop **every** ROI at **every** level and select afterwards — four times the
tensors. That is why K=1000 costs three quarters of a gigabyte before a single weight loads.

Static shapes were also checked for what they *invent*, not only what they lose. NMS pads with zero
boxes, which reach the box head and are assigned fresh scores. Measured with torchvision's
`clip_boxes_to_image` / `remove_small_boxes` cleanup bypassed — mandatory, since feeding padded
proposals into torch hands the zeros to code that deletes them and returns zero by construction:
**0 padded boxes cleared the 0.05 threshold**, max padded score 7.6e-05. Real mechanism, negligible
magnitude.

### 3. FPN level assignment — PASS

`floor(k0 + log2(s/s0) + eps)` built from `sqrt`, `log`, `scale` and `floor`, with the epsilon
**outside** the logarithm as torchvision has it (`poolers.py:78`; putting it inside is a different
function and differs exactly at a boundary). The probe reproduces `LevelMapper` **exactly** across
areas spanning every level, including area 0.

fp16 is the residual risk and it is now a number: over 200,000 realistic proposals, **0.0205%**
(41) change level when box coordinates are rounded to fp16 — about 0.2 proposals per tile at K=1000.

### 4. Both NMS passes — PASS, and there are three

The ticket names two. Both are terminal, per-class semantics are vacuous for ADAF
(`cls_score.weight` is `[2, 1024]`), and this repo already emits a terminal standalone NMS stage. The
hard one is not in the ticket: the **RPN's mid-graph pass**, whose output is an input.

- Mid-graph NN-layer NMS returns **torchvision's kept indices, in torchvision's order**.
- Boxes are `CENTER_SIZE_WIDTH_FIRST` where torchvision's are corners — measured, not assumed.
- `per_class_suppression` works in both settings, so a future multi-class checkpoint is not blocked.
- **Non-composition is now measured, not constructed**: 200/200 trials differ, 73.89 boxes two-pass
  against 153.07 single-pass at 0.2. Caveat recorded: the top-100 cap *between* the passes does much
  of that work, so the supported claim is that a single NMS at 0.2 cannot replace the pair.

**One defect found.** With a score threshold above every input score, the NN-layer NMS reports
`valid_count = 1`, not 0 — it emits a box nothing qualified for. A graph built on the assumption that
an empty result is empty would surface a phantom detection on **every empty tile**, which for this
app means every page containing no archaeology.

---

## Criterion 0 — the transform, which the ticket does not list and does not survive

Every criterion above describes something happening *after* the image is resized. A 512 tile does not
run at 512: the short side goes to 800 by bilinear interpolation with `align_corners=False`, then
pads to a multiple of 32.

**No NN-spec resize mode reproduces it.** On the real figure the closest is 0.1296 absolute (on
[0,1] data); `add_upsample` does offer an `ALIGN_CORNERS_FALSE` mode matching PyTorch's half-pixel
rule, but it takes **integer** scale factors and 512→800 is 1.5625, so it cannot express this resize
at all.

**Pinning `min_size=512` is not a cheaper design — it is a different model.** Measured: detections
drop 2 → 1, surviving box moves **19.43 px**, score delta 0.0147. That fails the 1 px budget by 19×.

This is the one unresolved item, and the composed PASS above does **not** cover it: the substitution
harness held the transform constant (torch on both sides), so no number here says Core ML can resize.
The resolution is available and cheap — **do the resize outside the graph**. The app already renders
its own snapshots, so it can hand Core ML an 800×800 buffer produced by a host-side resample under
our control, and the NN-spec resize convention never enters the question. M3b must choose that
explicitly rather than inherit a resize layer.

---

## Composition, and the stages the ticket mandates elementwise

A real Core ML side exists for both mandated stages — the trunk and the RPN head are genuinely
converted (`convert_to="neuralnetwork"`, 134 layers) and genuinely run, so these are not the oracle
compared with itself.

| stage | max abs delta |
|-|-|
| backbone + FPN, all five levels | **5.98e-05** |
| RPN head objectness and deltas (pre-top-K) | **0.00e+00** (bit-identical) |

Downstream of any top-K the instrument is detection-level matching, never elementwise, because a
sub-tolerance score change reorders the output set.

| substitution | max box shift | max score delta | unmatched |
|-|-|-|-|
| Core ML pooling (4 models) | ≤ 0.00005 px | ≤ 0.000001 | 0 |
| + fp16 interfaces | ≤ 0.00580 px | ≤ 0.000014 | 0 |
| torch, fp16 only | ≤ 0.00586 px | ≤ 0.000012 | 0 |

Against budgets of 1.0 px and 0.01 that is ~170× and ~700× of margin. Note the last row: **fp16
accounts for essentially all of the movement and Core ML for almost none.**

---

## Input domain — answered, not assumed

The trained domain was not recoverable from source: `ResizeV2` is a bare `ToTensorV2` with no
division by 255 (`joint_transforms.py:163-170`), and `GeneralizedRCNNTransform` subtracts ImageNet
statistics whatever arrives — so a wrong scaling does not crash, it produces confident meaningless
boxes. Measured instead, on each model's own in-class figure:

| scaling | OD_ringfort | OD_barrow | OD_enclosure | OD_AO |
|-|-|-|-|-|
| **`/255`** | **0.9803** | **0.9796** | **0.8073** | **0.9891** |
| raw 0..255 | no detections | no detections | no detections | no detections |
| ×255 | no detections | no detections | no detections | no detections |

#654's `[0,1]` contract is confirmed by measurement. (`per_tile_minmax` ties with `/255` on these
figures because they already span the full range — a tie, reported as one.)

---

## Cost

| | |
|-|-|
| Parameters | 43,315,482 — **165.2 MiB** fp32, 82.6 MiB fp16, per single-class model |
| Backbone stem activation | 39.1 MiB (64×400×400 fp32) |
| FPN P2 | 39.1 MiB (256×200×200 fp32) |
| ROI stage at the measured K=128 | 98.0 MiB |

Not measured: device latency, thermal behaviour, and real peak memory under iOS.

---

## Conditions on the GO

1. **Resize outside the graph.** No NN-spec mode reproduces torchvision's, and pinning `min_size` to
   the tile moves boxes 19.4 px. Hand Core ML an already-resized buffer.
2. **K = 128, not 1000.** Measured floor with zero loss across four models; drops ROI activations
   from 765.6 MiB to 98.0 MiB. K=64 loses 12.5% of OD_enclosure's set.
3. **RoIAlign as `CropResize` at 2× followed by a 2×2 average pool**, `ROI_ALIGN_MODE`, corner
   coordinates, no pre-compensation. A bare 7×7 crop is a different operator.
4. **Handle the empty-tile NMS defect.** `valid_count = 1` when nothing qualifies; the graph must not
   treat the first slot as a detection without checking the score.
5. **Emit both terminal passes.** They do not compose.

## Residual risks a GO accepts

- **Compute units change the answer — measured on a proxy, not on ADAF's detector.** Every number
  above is Mac, CPU-only, float32: a controlled semantic baseline, and not what the app does. The app
  leaves `MLModelConfiguration` at its default (`DeepDriver.swift:67`), so the shipping path may use
  GPU/ANE with fp16 and graph partitioning. `VisionReplay` was run on yolov8n through the real Vision
  path with both settings on one image, and the difference is visible:

  | | `--compute all` (the app's default) | `--compute cpu` |
  |-|-|-|
  | confidence | `0.8828125000` — exactly 226/256, an **fp16 grid value** | `0.8818327188` |
  | box x, width | `0.8269857`, `0.1728516` | `0.8271651`, `0.1732262` |

  Same five objects found, but confidences quantise to an fp16 grid and box edges move by up to
  **~0.3 px** on an 810 px image. That is within this spike's 1 px budget and it is a *different
  model's* number — the mechanism is demonstrated, the magnitude for a converted Faster R-CNN is not.
  **M3b must retire this on real hardware with the real detector.**
- **The Vision layer is now partly measured.** `VisionReplay/` drives a model exactly as the app does
  — `VNCoreMLModel` + `VNCoreMLRequest` with `.scaleFit` (`Detector.swift:76`) and an optional region
  of interest — and reproduces the ROI-relative-coordinate trap that `TileLayout.remap` corrects. It
  still needs an assembled detector to say anything about *this* model.
- **A converted model must present a Vision detector interface or the app silently sees nothing.**
  Measured while validating the harness: a non-detector model returns `VNClassificationObservation`s,
  and the app's `as? [VNRecognizedObjectObservation]` cast then yields zero detections with no error.
  M3c's emitted pipeline has to produce the `confidence`/`coordinates` output pair Vision recognises,
  which is what this repo's existing detector pipeline already does — but it is a silent failure mode
  if it regresses.
- **n is small and the imagery is ADAF's own.** Two to eight detections per model on 400×400 README
  figures — smaller than the 512 px training patch, so a 512 tile is ~22% replicated margin. These
  numbers describe ADAF's imagery, not arbitrary user rasters.
- **torchvision 0.23 is a chosen oracle, not recovered provenance.** The wheel pins only
  `torch>=1.10.0, torchvision>=0.11.1`, and ADAF's actual environment is not recorded anywhere
  reachable.
- **The whole detector was never assembled.** Every measured piece composes; that is not the same
  claim as "the model works", and M3c is where the difference gets settled.

## Bonus finding

**coremltools 9.0 ships no `roi_align` mapping at all** — zero matches in the installed package,
where `torchvision::nms` is registered. There was never an upstream conversion route to inherit from,
which is the strongest single piece of evidence that hand-emission is the only path.
