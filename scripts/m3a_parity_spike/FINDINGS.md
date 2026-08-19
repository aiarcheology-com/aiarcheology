# M3a findings — Faster R-CNN to Core ML parity (AIA-0670)

**Verdict: GO, conditionally.** Every operation the ticket doubted is expressible in NN-spec and
reproduces torchvision to far below the threshold at which ADAF's own pipeline could notice. The
conditions are not caveats on that result; they are four specific design commitments M3b/M3c must
make, each forced by a number below, plus one genuinely unresolved item.

Measured on all four `OD_*` checkpoints against the vendored aitlas wheel, on ADAF's own SLRM
figures. **20 verdicts, 0 FAIL, 3 UNDERPOWERED** (`results/verdicts.json`) — the three being OD_AO's
composition results, which meet every threshold on a single detection and are labelled rather than
counted. Thresholds are fixed in `decision_rule.py` with the reason for each value, and that file
discloses that exploratory probes preceded it.

An adversarial review of this branch found that three of the numbers in an earlier draft were
unbacked: criterion 3 passed with no committed code measuring it, criterion 1's recorded winner was
chosen by a metric that cannot see the difference, and criterion 2's headline rank was computed from
the wrong ordering. All three are corrected below, and the corrections changed a condition — the
required K went from a claimed 128 to a measured 723, which is a memory problem rather than an
accuracy one. The wrong versions are described where they were wrong, because a spike whose job is
to be believed should show where it was not.

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
| Harness sensitivity (mutation test, now in the harness) | packing width-first while declaring height-first moves the grid **6.46 px**, so the harness can tell a coordinate bug from an operator difference |

**The grid metric cannot choose the construction, and an earlier version of this document let it
try.** The calibration input is an affine ramp, and the average of an affine function over a
symmetric sample set is its value at the centroid — which is why the grid is recoverable at all, and
why the metric is blind to `sampling_ratio`. `direct_7x7` and `crop14_pool2` therefore tie at
1.91e-06, and taking `min()` of a tie resolved by insertion order to `direct_7x7`. Measured on real
features, that is the wrong operator by an order of magnitude:

| construction | relative mean abs difference on real FPN features |
|-|-|
| bare 7×7 crop | **0.4026** |
| **crop at 14×14 + 2×2 average pool** | **0.0436** |

No ROI pre-compensation is needed. Substituted into the real pipeline with the winning construction,
the detection set is unchanged and boxes move **≤ 0.00005 px** across all four models.

Worth flagging against my own prediction: the module's docstring predicted the pooled construction's
residual would collapse to float noise (~1e-6). It did not — 0.0436 relative is far above that. The
likely cause is boundary semantics (`roi_align` zero-pads outside the feature map where CropResize
appears to clamp), which edge-touching proposals exercise and the interior calibration ROI cannot
see. The end-to-end detection sets are unaffected, but the prediction failed and the mechanism is
not nailed down — M3b should assume edge proposals are where this operator differs.

### 2. Static shapes and fixed top-K — PASS on expressibility, but **K is expensive**

Retention is the wrong instrument: torchvision is already capped at 1000/1000/100, so on this imagery
a retention curve is a flat line. The **rank margin** — the *position* of the proposal each surviving
detection came from, since a static K keeps the first K of a score-ordered list — is what a cut
actually threatens.

| model | detections | contributing proposal positions | smallest safe K |
|-|-|-|-|
| OD_ringfort | 2 | 5, 11 | 12 |
| OD_barrow | 3 | 0, 2, 4 | 5 |
| **OD_enclosure** | 8 | 0, 12, 13, 14, 15, 143, 598, **722** | **723** |
| OD_AO | 1 | 0 | 1 |

**The required K across the four models is 723**, driven entirely by OD_enclosure, whose eighth
detection comes from proposal 722 of 1000. That is the number the memory cost has to be paid at:

| K | crop (14×14) at all 4 levels | pooled (7×7) at all 4 levels |
|-|-|-|
| 1000 (torchvision default) | 765.6 MiB | 191.4 MiB |
| **723 (measured requirement)** | **553.5 MiB** | 138.4 MiB |
| 256 | 196.0 MiB | 49.0 MiB |
| 128 | 98.0 MiB | 24.5 MiB |

Per-ROI level assignment is data dependent and a data-dependent gather has no fixed output shape, so
a static graph must crop **every** ROI at **every** level and select afterwards — four times the
tensors. Whether the four 14×14 crops are live simultaneously depends on how Core ML schedules them;
553.5 MiB is the upper bound and 138.4 MiB the figure if each level is pooled before the next is
cropped. Neither is comfortable on iOS.

**An earlier version of this document claimed K=128 with zero loss. That was wrong**, and the way it
was wrong is worth recording: the rank was computed by re-sorting proposals on *box-head* score
rather than by their position in the RPN-ordered list, which flattered the worst rank from 722 down
to 102. The empirical sweep does still show agreement 1.0 at K=128 — but at K=128 OD_enclosure
returns **9** detections against a baseline of 8, so a one-directional retention metric called it a
clean pass while the output set had changed. Both directions are now reported.

Static shapes were also checked for what they *invent*. NMS pads with zero boxes, which reach the box
head and are assigned fresh scores. Measured with torchvision's `clip_boxes_to_image` /
`remove_small_boxes` cleanup bypassed — mandatory, since feeding padded proposals into torch hands
the zeros to code that deletes them and returns zero by construction: **0 padded boxes cleared the
0.05 threshold**, max padded score 7.6e-05.

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
function and differs exactly at a boundary).

| set | result |
|-|-|
| 997 areas from the model's **real** RPN proposals | **0 mismatches** |
| 40 adversarial areas — power-of-two boundaries stepped by `nextafter`, plus the degenerate ones padding produces (zero area, 1 px, 1e12) | **0 mismatches** |
| fp16 flip rate, box shapes resampled from real proposals | **0.022%** |

Zero area is not a hypothetical input: criterion 2 measured that padded NMS slots are zero boxes, so
`log2(sqrt(0)) = -inf` reaches this expression on every tile that is not full.

*(These numbers were previously produced by ad-hoc commands that were never committed — the probe
existed and nothing called it. They are now generated by `criterion_levels.py` from `run_spike.py`,
which is the difference between a measurement and a recollection.)*

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
| ROI stage at the measured K=723 | **553.5 MiB** of crops, 138.4 MiB pooled |

So a single-class detector wants roughly 165 MiB of fp32 weights plus a ROI stage in the hundreds of
megabytes, on a device with a jetsam limit. **This, not numerical parity, is the part of the ticket's
"worth shipping" question that is still open**, and it is arithmetic rather than measurement: device
latency, thermal behaviour and real peak memory under iOS are all unmeasured.

---

## Conditions on the GO

1. **Resize outside the graph.** No NN-spec mode reproduces torchvision's, and pinning `min_size` to
   the tile moves boxes 19.4 px. Hand Core ML an already-resized buffer.
2. **Budget for K ≈ 723, and treat ROI memory as the binding constraint.** That is the measured
   requirement across the four models, costing 553.5 MiB of 14×14 crops (138.4 MiB pooled) because a
   static graph crops at every level. This is the item most likely to force a design change — chunking
   the ROI stage into a fixed number of fixed-size batches is the obvious lever and **this spike did
   not measure it**.
3. **RoIAlign as `CropResize` at 2× followed by a 2×2 average pool**, `ROI_ALIGN_MODE`, corner
   coordinates, no pre-compensation. A bare 7×7 crop is a different operator — 0.4026 relative
   residual against 0.0436 — and it is what a sampling-ratio-blind metric will pick if allowed to.
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
