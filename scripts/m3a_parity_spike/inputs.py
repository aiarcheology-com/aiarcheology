"""The spike's input corpus: what may be measured on, and what a number measured here can claim.

A parity figure is worth exactly as much as the image it was measured on, so this module's job is
half construction and half refusal. It builds the corpus, and it records the evidence that stops the
write-up from claiming more than the corpus supports.

**The ADAF figures may be contaminated.** The only real SLRM imagery published alongside the weights
is three JPEGs from ADAF's README. They are *figures*, which means they may carry the detector's own
output painted onto them — boxes, legends, scale bars, captions. Feeding a picture of a detection
back into the detector is not a measurement of anything, and it would corrupt every downstream
number in the spike rather than just one. So `inspect_for_contamination` runs first and reports cheap
statistics a human can act on. It deliberately does not claim to find boxes; it claims only what a
chroma histogram can support, because a statistic that overstates itself is worse than no statistic.

**Sparse imagery cannot answer criterion 2.** #670's second exit criterion asks what a fixed top-K
cut costs in recall. On an image holding four objects, every K above four recovers everything and the
recall curve is flat — the criterion would come back "no cost" for reasons that have nothing to do
with the cut. `mosaic` exists to build an input dense enough that K actually binds, so the answer is
about the cut rather than about the sparsity of the test image.

**The trained input domain is not known, and must not be assumed.** ADAF reads float GeoTIFF patches
through `ResizeV2`, which despite its name is a bare `ToTensorV2`: no resize, no normalisation, and
in particular no division by 255 (`aitlas/transforms/joint_transforms.py:163-170`, reproduced at
`oracle.py:166-176`). `GeneralizedRCNNTransform` then subtracts ImageNet mean/std regardless of what
arrives. Whether the trained domain is 0..1, 0..255, or something else is therefore an empirical
question, and `scaling_candidates` hands the runner all the plausible answers at once instead of
picking one and calling it the contract.

**Quantisation has to be isolated by pairing.** The tempting comparison — synthetic float terrain
against a real 8-bit JPEG — varies content, relief, rendering *and* bit depth simultaneously, then
attributes the whole difference to bit depth. `paired_quantization` returns one array rendered two
ways, which is the only construction in which the difference is the quantisation and nothing else.

**The synthetic SLRM is a control, not a stand-in.** No float SLRM raster is published with the
weights, so the unquantised regime is represented by a generated one. It is a real Simple Local
Relief Model by definition — a DEM minus a mean-filtered copy of that DEM, clipped to the +/-0.5 m
window and normalised to [0, 1] per #654's preprocessing contract — but its mounds are geometry, not
archaeology. Every manifest this module writes says so in `composition.not_exercised`, so a reader
can see the shape of the hole rather than having to infer it.
"""

from __future__ import annotations

import hashlib
import math
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image

from oracle import resize_v2

MODULE_PATH = Path(__file__).resolve()

# ADAF's README figures. Raw GitHub rather than the Zenodo record because the record publishes
# weights, not imagery; these three JPEGs are the only real SLRM pictures ADAF publish at all.
FIGURE_BASE_URL = "https://raw.githubusercontent.com/EarthObservation/adaf/main/adaf/media"
FIGURE_NAMES = ("barrows.jpg", "enclosure.jpg", "ringfort.jpg")

# The exact string every manifest entry carries. ADAF's weights and repository are CC-BY-SA-4.0, and
# an input pinned without its licence is an input someone will later republish by accident.
FIGURE_LICENCE = "CC-BY-SA-4.0 (ADAF, Zenodo record 15848663)"
FIGURE_ATTRIBUTION = (
    "ADAF - Automatic Detection of Archaeological Features, EarthObservation/adaf; "
    "weights: Kostovska, Kocev, Coz, Kokalj, Curran, Corns, Zenodo 10.5281/zenodo.15848663"
)

# #654's preprocessing contract: SLRM normalised to float [0, 1] from a +/-0.5 m relief window, with
# NaN mapped to 0, 512 px patches, single band repeated three times.
RELIEF_WINDOW_M = 0.5
PATCH_PX = 512

# Contamination statistics. A greyscale relief visualisation is grey everywhere except where
# something was drawn on it, so chroma is the cheapest honest signal available.
CHROMA_THRESHOLD = 30  # |max(R,G,B) - min(R,G,B)| above which a pixel is called non-grey
NON_GREY_FRACTION_ALERT = 0.005  # 0.5 % of pixels non-grey trips `likely_annotated`
SATURATED_CHROMA = 90  # a drawn overlay is a strong colour, not a JPEG chroma wobble
SATURATED_VALUE = 110  # ... and a bright one; this excludes dark colour fringing
BLOCK_PX = 16  # coarse grid used to tell a drawn region from scattered speckle
BLOCK_COVERAGE = 0.5

_COLOUR_FAMILIES = {1: "red", 2: "green", 4: "blue", 3: "yellow", 5: "magenta", 6: "cyan"}


class CorpusError(RuntimeError):
    """Raised when an input cannot be produced or trusted. Reported, never downgraded to a warning."""


# --------------------------------------------------------------------------------------------
# The real figures
# --------------------------------------------------------------------------------------------


def _sha256_file(path: Path) -> str:
    accumulator = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            accumulator.update(chunk)
    return accumulator.hexdigest()


def _sha256_array(array: np.ndarray) -> str:
    """Digest an array together with its shape and dtype.

    Bytes alone are ambiguous: a 512x512x3 uint8 buffer and a 768x512x2 one can hash identically and
    mean entirely different pictures. Pinning the interpretation alongside the bytes costs nothing
    and closes that hole.
    """
    contiguous = np.ascontiguousarray(array)
    accumulator = hashlib.sha256()
    accumulator.update(f"{contiguous.dtype.str}|{contiguous.shape}|".encode())
    accumulator.update(contiguous.tobytes())
    return accumulator.hexdigest()


def fetch_figures(destination) -> dict:
    """Download ADAF's three README figures, cache them, and pin each one by digest.

    Cached copies are reused untouched. That is a deliberate reproducibility choice rather than a
    bandwidth one: `main` is a moving branch, so re-fetching on every run would silently swap the
    corpus out from under a series of measurements. The SHA-256 in the returned manifest is what
    makes the swap visible when it does happen, which is why every entry carries one whether the
    file was just downloaded or found on disk.

    Note that `pixels` is (width, height), because that is what PIL's `size` is, while every array
    in this module is height-first. Conflating the two on a non-square figure produces a transposed
    crop that still looks like an image, which is the worst kind of bug to inherit.
    """
    directory = Path(destination)
    directory.mkdir(parents=True, exist_ok=True)

    manifest = {}
    for name in FIGURE_NAMES:
        path = directory / name
        url = f"{FIGURE_BASE_URL}/{name}"
        if not path.exists() or path.stat().st_size == 0:
            request = urllib.request.Request(url, headers={"User-Agent": "aiarcheology-m3a-spike"})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = response.read()
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                raise CorpusError(f"{name}: could not fetch {url} - {type(exc).__name__}: {exc}") from exc
            if not payload:
                raise CorpusError(f"{name}: {url} returned an empty body")
            path.write_bytes(payload)

        try:
            with Image.open(path) as image:
                width, height = image.size
                mode = image.mode
        except Exception as exc:  # noqa: BLE001 - an undecodable cache entry is a corpus failure
            raise CorpusError(f"{name}: {path} does not decode as an image - {exc}") from exc

        manifest[name] = {
            "path": str(path),
            "source_url": url,
            "bytes": path.stat().st_size,
            "sha256": _sha256_file(path),
            "pixels": (width, height),
            "mode": mode,
            "licence": FIGURE_LICENCE,
            "attribution": FIGURE_ATTRIBUTION,
        }
    return manifest


def read_figure(path) -> np.ndarray:
    """Load a cached figure as an HWC uint8 RGB array.

    The conversion to RGB is unconditional even though these figures are already grey, because a
    single-band array would silently change the channel count downstream and #654's contract is a
    band repeated three times, not one band.
    """
    with Image.open(Path(path)) as image:
        return np.asarray(image.convert("RGB"))


def inspect_for_contamination(path) -> dict:
    """Report how much of a figure is not grey, and how concentrated that colour is.

    The thing being guarded against is specific: ADAF's README figures illustrate detections, so a
    figure may carry drawn boxes, a legend, a scale bar or a caption. Running the detector on its own
    published output is circular, and the resulting scores would look excellent for the worst
    possible reason.

    What is measured is only chroma. A relief visualisation is grey by construction, so a pixel whose
    channels disagree by more than `CHROMA_THRESHOLD` (30/255) is something that was painted on.
    `non_grey_fraction` is the share of such pixels; `likely_annotated` is that fraction exceeding
    `NON_GREY_FRACTION_ALERT`, which is 0.5 % of the image. The threshold is set where it is because
    JPEG chroma subsampling on genuinely grey content produces deviations well under 30, while a
    handful of drawn rectangles plus a legend on a megapixel figure comfortably clears half a
    percent.

    `saturated_blocks_16px` separates a drawn *region* from scattered speckle without a connected
    components pass: the near-saturated mask is reduced over a 16x16 grid, and a block counts only if
    the majority of its pixels are strongly coloured. Ten thousand isolated colour-fringed pixels
    score zero blocks; one filled legend patch scores many.

    What this cannot say, and must not be reported as saying: it cannot see a box. A white outline,
    black caption text or a grey scale bar drawn on a grey image is invisible to every statistic
    here, so a low `non_grey_fraction` is weak evidence of cleanliness and a high one is strong
    evidence of drawing. The asymmetry is deliberate - it fails towards suspicion.
    """
    file_path = Path(path)
    with Image.open(file_path) as image:
        original_mode = image.mode
        width, height = image.size
        pixels = np.asarray(image.convert("RGB"), dtype=np.int16)

    high = pixels.max(axis=2)
    low = pixels.min(axis=2)
    chroma = high - low
    total = float(pixels.shape[0] * pixels.shape[1])

    non_grey_fraction = float((chroma > CHROMA_THRESHOLD).mean())
    saturated = (chroma >= SATURATED_CHROMA) & (high >= SATURATED_VALUE)

    # Which channels carry the colour: a channel counts as "high" if it sits in the top third of the
    # pixel's own range, so red is (R), yellow is (R, G), and so on.
    dominant = pixels >= (low + (2 * chroma) // 3)[:, :, None]
    signature = dominant[:, :, 0] * 1 + dominant[:, :, 1] * 2 + dominant[:, :, 2] * 4
    by_colour = {
        label: float(np.count_nonzero(saturated & (signature == code)) / total)
        for code, label in _COLOUR_FAMILIES.items()
    }

    rows = pixels.shape[0] // BLOCK_PX
    columns = pixels.shape[1] // BLOCK_PX
    if rows and columns:
        blocks = saturated[: rows * BLOCK_PX, : columns * BLOCK_PX]
        coverage = blocks.reshape(rows, BLOCK_PX, columns, BLOCK_PX).mean(axis=(1, 3))
        saturated_blocks = int(np.count_nonzero(coverage >= BLOCK_COVERAGE))
        max_block_coverage = float(coverage.max())
    else:
        saturated_blocks = 0
        max_block_coverage = 0.0

    likely_annotated = non_grey_fraction > NON_GREY_FRACTION_ALERT
    strongest = max(by_colour.items(), key=lambda item: item[1])
    summary = (
        f"{non_grey_fraction * 100:.2f}% of pixels are non-grey "
        f"(alert above {NON_GREY_FRACTION_ALERT * 100:.1f}%); "
        f"{saturated_blocks} of {rows * columns} 16px blocks are majority near-saturated colour, "
        f"strongest family {strongest[0]} at {strongest[1] * 100:.2f}%. "
        + (
            "Consistent with drawing painted onto the figure; treat as contaminated until a human "
            "has looked at it."
            if likely_annotated
            else "No colour drawing at this threshold; greyscale drawing would not show up here."
        )
    )

    return {
        "path": str(file_path),
        "pixels": (width, height),
        "mode": original_mode,
        "non_grey_fraction": non_grey_fraction,
        "non_grey_fraction_threshold": NON_GREY_FRACTION_ALERT,
        "likely_annotated": likely_annotated,
        "saturated_fraction": float(np.count_nonzero(saturated) / total),
        "saturated_by_colour": by_colour,
        "saturated_blocks_16px": saturated_blocks,
        "blocks_total": int(rows * columns),
        "max_block_saturation": max_block_coverage,
        "detects_boxes": False,
        "summary": summary,
    }


# --------------------------------------------------------------------------------------------
# Tiling and the density-stress mosaic
# --------------------------------------------------------------------------------------------


@dataclass
class Tile:
    """One crop, carrying where it came from so a detection can be mapped back to the figure."""

    row: int
    col: int
    y0: int
    x0: int
    array: np.ndarray
    edge_padded: bool


def _origins(extent: int, tile_px: int, stride: int) -> list:
    """Tile origins along one axis: regular stride, with the last tile snapped back to the edge.

    Snapping rather than padding or dropping is the choice that keeps coverage complete without
    inventing pixels. It costs a partial overlap between the last two tiles, which matters only if
    someone counts detections across tiles without deduplicating - so say it here rather than let it
    be discovered as a doubled box.
    """
    if extent <= tile_px:
        return [0]
    positions = list(range(0, extent - tile_px + 1, stride))
    if positions[-1] + tile_px < extent:
        positions.append(extent - tile_px)
    return positions


def tile(image_array: np.ndarray, tile_px: int = PATCH_PX, stride: int = None) -> list:
    """Cut an image into `tile_px` squares, deterministically.

    Deterministic is the whole requirement. A random crop makes two runs of the same criterion
    incomparable, and worse, it makes a criterion that fails look like one that is merely noisy.
    Every tile here is a pure function of the image and the two arguments.

    An image smaller than `tile_px` in either axis is edge-replicated up to it and the resulting
    tiles are marked `edge_padded`, because a replicated margin is content the detector can find
    boxes in and nobody should count those boxes as evidence.
    """
    array = np.asarray(image_array)
    if array.ndim not in (2, 3):
        raise CorpusError(f"expected HW or HWC, got shape {array.shape}")
    step = tile_px if stride is None else int(stride)
    if step < 1:
        raise CorpusError(f"stride must be positive, got {stride}")

    height, width = array.shape[0], array.shape[1]
    pad_y = max(0, tile_px - height)
    pad_x = max(0, tile_px - width)
    if pad_y or pad_x:
        padding = [(0, pad_y), (0, pad_x)] + [(0, 0)] * (array.ndim - 2)
        array = np.pad(array, padding, mode="edge")

    tiles = []
    for row, y0 in enumerate(_origins(array.shape[0], tile_px, step)):
        for col, x0 in enumerate(_origins(array.shape[1], tile_px, step)):
            tiles.append(
                Tile(
                    row=row,
                    col=col,
                    y0=y0,
                    x0=x0,
                    array=np.ascontiguousarray(array[y0 : y0 + tile_px, x0 : x0 + tile_px]),
                    edge_padded=bool(y0 + tile_px > height or x0 + tile_px > width),
                )
            )
    return tiles


def mosaic(images: list, tile_px: int = PATCH_PX, columns: int = None, limit_per_image: int = None) -> np.ndarray:
    """Lay tiles from several figures into one grid, to make a fixed top-K cut actually bind.

    Criterion 2 asks what the static-shape top-K costs in recall. Asked of a sparse image the
    question answers itself: with four objects present, every K above four recovers all of them and
    the curve is flat, which says nothing about the cut and everything about the picture. Packing
    many object-bearing tiles into one canvas raises the object count until K is the binding
    constraint, which is the only regime in which the criterion measures what it claims to.

    The grid is filled by cycling the tile list when the tiles do not divide evenly, so there are no
    blank cells wasting proposals. Duplicated cells are legitimate for a density stress and are not
    legitimate as independent evidence - two copies of one tile are one observation, and any recall
    statistic computed here must be read as "recall under crowding", never as generalisation.
    """
    collected = []
    for image in images:
        crops = tile(image, tile_px=tile_px)
        collected.extend(crops if limit_per_image is None else crops[:limit_per_image])
    if not collected:
        raise CorpusError("mosaic needs at least one tile")

    channels = collected[0].array.shape[2:] if collected[0].array.ndim == 3 else ()
    for crop in collected:
        if crop.array.shape[2:] != channels:
            raise CorpusError("mosaic inputs disagree on channel count")

    across = columns or int(math.ceil(math.sqrt(len(collected))))
    down = int(math.ceil(len(collected) / across))
    canvas = np.zeros((down * tile_px, across * tile_px) + channels, dtype=collected[0].array.dtype)
    for index in range(down * across):
        crop = collected[index % len(collected)].array
        row, col = divmod(index, across)
        canvas[row * tile_px : (row + 1) * tile_px, col * tile_px : (col + 1) * tile_px] = crop
    return canvas


# --------------------------------------------------------------------------------------------
# Input scaling: the unknown this spike has to measure rather than assume
# --------------------------------------------------------------------------------------------


def scaling_candidates(tile_uint8: np.ndarray) -> dict:
    """Every plausible input scaling for one tile, as float32 CHW tensors ready for the model.

    There is no way to look this up. ADAF's transform is `ResizeV2`, and `ResizeV2` is
    `A.Compose([ToTensorV2(p=1.0)])` - HWC to CHW and nothing else
    (`aitlas/transforms/joint_transforms.py:163-170`). It does not divide by 255, which is precisely
    where torchvision's identically-purposed `ToTensor` differs, and conflating the two is the
    easiest way to feed this detector a domain it never saw. Downstream,
    `GeneralizedRCNNTransform` subtracts ImageNet mean/std whatever arrives, so the wrong scaling
    does not crash and does not look wrong - it produces confident, meaningless boxes.

    Hence four candidates rather than a decision. `divide_255` and `raw` are the two readings of an
    8-bit rendering; `times_255` is the reading under which a float [0, 1] SLRM patch becomes the
    0..255 domain the ImageNet statistics were fitted for, and it is deliberately included even
    though on uint8 input it produces an absurd 0..65025, because the corpus contains both regimes
    and the caller should be able to see the absurd one fail. `per_tile_minmax` is the recoverable
    analogue of #654's fixed +/-0.5 m window for imagery whose physical relief range is no longer
    known, and it is the candidate that would win if the model turned out to care about contrast
    rather than absolute level.

    The CHW conversion goes through `oracle.resize_v2` rather than a local transpose so that the
    corpus and the oracle cannot drift apart on the one transform the wheel actually applies.
    """
    array = np.asarray(tile_uint8)
    if array.ndim == 2:
        array = np.repeat(array[:, :, None], 3, axis=2)
    if array.ndim != 3 or array.shape[2] != 3:
        raise CorpusError(f"expected a 3-band HWC tile, got shape {np.asarray(tile_uint8).shape}")

    base = np.ascontiguousarray(array, dtype=np.float32)
    low = float(base.min())
    span = float(base.max()) - low
    minmax = (base - low) / span if span > 0 else np.zeros_like(base)

    return {
        "divide_255": resize_v2(base / 255.0),
        "raw": resize_v2(base),
        "times_255": resize_v2(base * 255.0),
        "per_tile_minmax": resize_v2(minmax.astype(np.float32)),
    }


def paired_quantization(float_array: np.ndarray) -> tuple:
    """One array rendered twice: as float, and through an 8-bit round trip.

    This pairing is the only honest way to price quantisation. The intuitive alternative - measure on
    a synthetic float raster, measure on a real 8-bit JPEG, subtract - varies the content, the
    relief, the rendering pipeline and the bit depth all at once and then hands the entire difference
    to bit depth. The difference between the two arrays returned here is quantisation and nothing
    else, because everything else is literally the same array.

    Note what the pair does *not* cover: JPEG is lossy beyond quantisation, so a real figure carries
    block artefacts and chroma subsampling that this round trip does not reproduce. The pair prices
    the bit depth; it does not price the codec, and the write-up must not let one stand in for the
    other.
    """
    reference = np.ascontiguousarray(float_array, dtype=np.float32)
    if not np.isfinite(reference).all():
        raise CorpusError("paired_quantization needs a finite array; NaN must be resolved upstream")
    if reference.min() < -1e-6 or reference.max() > 1.0 + 1e-6:
        raise CorpusError(
            f"expected the [0, 1] domain of #654's preprocessing contract, got "
            f"[{float(reference.min()):.4f}, {float(reference.max()):.4f}]"
        )
    reference = np.clip(reference, 0.0, 1.0)
    codes = np.rint(reference * 255.0).astype(np.uint8)
    return reference, (codes.astype(np.float32) / 255.0)


# --------------------------------------------------------------------------------------------
# The synthetic float control
# --------------------------------------------------------------------------------------------


def _moving_average(field: np.ndarray, radius: int, axis: int) -> np.ndarray:
    """Exact box filter along one axis via a prefix sum, with edge replication at the borders."""
    length = field.shape[axis]
    padding = [(radius, radius) if index == axis else (0, 0) for index in range(field.ndim)]
    prefix = np.cumsum(np.pad(field, padding, mode="edge"), axis=axis)
    leading = list(prefix.shape)
    leading[axis] = 1
    prefix = np.concatenate([np.zeros(leading, dtype=prefix.dtype), prefix], axis=axis)
    window = 2 * radius + 1
    upper = np.take(prefix, np.arange(window, window + length), axis=axis)
    lower = np.take(prefix, np.arange(0, length), axis=axis)
    return (upper - lower) / window


def _mean_filter(field: np.ndarray, radius: int) -> np.ndarray:
    """Separable 2-D mean filter. A prefix sum keeps it exact and O(n) instead of O(n * radius**2).

    A mean filter, not a Gaussian, because that is what a Simple Local Relief Model is defined
    against: the "local relief" is the residual after subtracting a moving *average* surface. Using a
    Gaussian here would produce a plausible-looking picture of a slightly different quantity.
    """
    if radius < 1:
        return field.astype(np.float64, copy=True)
    return _moving_average(_moving_average(field.astype(np.float64), radius, 0), radius, 1)


def _circular_features(dem: np.ndarray, rng, pixel_size_m: float) -> None:
    """Add ringfort-like banks and barrow-like mounds to a DEM, in place, at archaeological scale.

    Scale is the part that matters. A ringfort bank is a metre-scale ring some 20-40 m across and a
    barrow a mound 10-20 m across; at ADAF's 0.5 m ground sampling those are 40-80 px and 20-40 px
    features, which is what makes them survive the local-relief subtraction and land in a size range
    the FPN's middle levels serve. Features drawn at the wrong scale would be removed by the mean
    filter along with the terrain, and the control would quietly contain nothing to detect.
    """
    size = dem.shape[0]
    rows, columns = np.mgrid[0:size, 0:size].astype(np.float64)
    area_factor = (size / float(PATCH_PX)) ** 2

    for _ in range(max(1, int(round(6 * area_factor)))):
        centre_y, centre_x = rng.uniform(0.1, 0.9, 2) * size
        radius_px = rng.uniform(12.0, 22.0) / pixel_size_m
        bank_px = rng.uniform(1.5, 3.0) / pixel_size_m
        height_m = rng.uniform(0.6, 1.1)
        distance = np.hypot(rows - centre_y, columns - centre_x)
        dem += height_m * np.exp(-(((distance - radius_px) / bank_px) ** 2))
        # The external ditch the bank material came out of - the pairing is what makes a ringfort
        # legible in relief rather than just a bright ring.
        dem -= 0.55 * height_m * np.exp(-(((distance - radius_px - 2.2 * bank_px) / bank_px) ** 2))

    for _ in range(max(1, int(round(10 * area_factor)))):
        centre_y, centre_x = rng.uniform(0.05, 0.95, 2) * size
        radius_px = rng.uniform(5.0, 11.0) / pixel_size_m
        height_m = rng.uniform(0.5, 0.9)
        distance = np.hypot(rows - centre_y, columns - centre_x)
        dem += height_m * np.exp(-((distance / radius_px) ** 2))


def synthetic_slrm(
    size: int = PATCH_PX,
    seed: int = 0,
    *,
    pixel_size_m: float = 0.5,
    smoothing_radius_m: float = 10.0,
    relief_window_m: float = RELIEF_WINDOW_M,
) -> np.ndarray:
    """A Simple Local Relief Model built from a synthetic DEM: DEM minus a smoothed DEM.

    This is a *control for the unquantised-float regime*, not a substitute for a real SLRM raster.
    ADAF publish weights, not training imagery, so nothing in the corpus is a genuine float GeoTIFF
    patch at the trained resolution. What this gives the spike is an input in the right domain,
    with the right statistics and the right feature scales, on which a float-versus-8-bit comparison
    can be run at all. Any parity claim resting on it is a claim about the domain, never about
    archaeology, and `corpus_manifest` records that in `composition.not_exercised`.

    The construction follows the definition rather than approximating a picture of it. A DEM is
    built with three superimposed scales - a regional slope and undulation of several metres,
    archaeology-scale circular relief of order a metre, and centimetre micro-relief - and then the
    SLRM is that DEM minus its mean-filtered self at `smoothing_radius_m`. The regional component
    exists precisely so that it can vanish: if the large-scale terrain did not cancel, the filter
    radius would be wrong and the output would not be a local relief model.

    The result is clipped to +/-`relief_window_m` and mapped to [0, 1] with NaN sent to 0, which is
    #654's preprocessing contract verbatim, and repeated across three bands as ADAF's single-band
    patch is. The clip is load-bearing rather than cosmetic: it saturates bank crests and ditch
    floors, which is exactly what the real preprocessing does to real features, so a detector trained
    on saturated features sees saturated features here.
    """
    if size < 8:
        raise CorpusError(f"size {size} is too small to carry an archaeological feature")
    rng = np.random.default_rng(seed)

    # Regional terrain: a gentle slope plus heavily smoothed noise, several metres of range. Its only
    # job is to be removed by the local-relief subtraction.
    columns = np.arange(size, dtype=np.float64)[None, :]
    dem = 0.02 * columns * np.ones((size, 1))
    dem = dem + 800.0 * _mean_filter(rng.normal(0.0, 1.0, (size, size)), max(1, size // 8))

    _circular_features(dem, rng, pixel_size_m)

    # Micro-relief: vegetation, ploughing, ALS noise. Lightly smoothed so it is textured rather than
    # white, which matters because white noise is removed by the mean filter almost completely and
    # would leave the control unrealistically clean.
    dem = dem + 3.0 * _mean_filter(rng.normal(0.0, 0.03, (size, size)), 1)

    smoothing_px = max(1, int(round(smoothing_radius_m / pixel_size_m)))
    relief = dem - _mean_filter(dem, smoothing_px)

    normalised = (np.clip(relief, -relief_window_m, relief_window_m) + relief_window_m) / (
        2.0 * relief_window_m
    )
    normalised = np.nan_to_num(normalised, nan=0.0)
    return np.repeat(normalised.astype(np.float32)[:, :, None], 3, axis=2)


# --------------------------------------------------------------------------------------------
# The manifest
# --------------------------------------------------------------------------------------------


def corpus_manifest(
    destination,
    *,
    synthetic_seeds: tuple = (0, 1, 2),
    synthetic_size: int = PATCH_PX,
    tile_px: int = PATCH_PX,
) -> dict:
    """Fetch and generate the whole corpus, pin every item by digest, and state what it misses.

    The composition block is the part that earns this function. A spike that reports parity numbers
    without saying what they were measured on invites the reading that they generalise, and here they
    do not: the corpus is three possibly-annotated JPEG figures and a synthetic float control. Naming
    the absences next to the digests means a later reader has to work to overclaim rather than
    having to work to notice.

    The generator itself is pinned by hashing this file, so a synthetic array can be traced to the
    code that produced it. Digesting the array alone would not distinguish "same seed, same code"
    from "same seed, code since edited".
    """
    figures = fetch_figures(destination)
    contamination = {name: inspect_for_contamination(entry["path"]) for name, entry in figures.items()}

    synthetic = {}
    for seed in synthetic_seeds:
        array = synthetic_slrm(synthetic_size, seed)
        reference, quantised = paired_quantization(array)
        synthetic[f"synthetic_slrm_{synthetic_size}px_seed{seed}"] = {
            "source": f"inputs.synthetic_slrm(size={synthetic_size}, seed={seed})",
            "generator_sha256": _sha256_file(MODULE_PATH),
            "licence": "generated by this repository; no third-party rights",
            "sha256": _sha256_array(array),
            "shape": list(array.shape),
            "dtype": str(array.dtype),
            "range": [float(array.min()), float(array.max())],
            "quantised_sha256": _sha256_array(quantised),
            "max_quantisation_error": float(np.abs(reference - quantised).max()),
        }

    stress = mosaic([read_figure(entry["path"]) for entry in figures.values()], tile_px=tile_px)

    return {
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "figures": {
            name: dict(entry, contamination=contamination[name]) for name, entry in figures.items()
        },
        "synthetic": synthetic,
        "density_stress_mosaic": {
            "source": f"inputs.mosaic(<the three figures>, tile_px={tile_px})",
            "generator_sha256": _sha256_file(MODULE_PATH),
            "licence": FIGURE_LICENCE,
            "sha256": _sha256_array(stress),
            "shape": list(stress.shape),
            "contains_duplicated_tiles": True,
        },
        "scaling_candidates": ["divide_255", "raw", "times_255", "per_tile_minmax"],
        "preprocessing_contract": {
            "source": "#654 - SLRM float [0, 1] from +/-0.5 m relief, NaN to 0, 512 px, band x3",
            "relief_window_m": RELIEF_WINDOW_M,
            "patch_px": PATCH_PX,
            "input_domain_is_measured_not_assumed": True,
        },
        "composition": {
            "real_8bit_jpeg_figures": len(figures),
            "synthetic_float_slrm": len(synthetic),
            "quantisation_pairs": len(synthetic),
            "density_stress_mosaics": 1,
            "any_figure_likely_annotated": any(item["likely_annotated"] for item in contamination.values()),
            "regimes_exercised": [
                "8-bit rendered relief, as the app's detection pipeline really sees an imported image",
                "unquantised float [0, 1] SLRM, represented only by a synthetic control",
            ],
            "not_exercised": [
                "real float GeoTIFF SLRM patches at ADAF's trained ground sampling - none is published",
                "real ALS terrain and real archaeological features; the synthetic mounds are geometry",
                "relief visualisations other than SLRM (hillshade, sky-view factor, openness)",
                "JPEG codec loss beyond bit depth - the quantisation pair prices depth, not the codec",
                "the HRNet segmentation inputs, permanently out of scope per #654",
            ],
        },
    }
