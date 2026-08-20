# ADAF checkpoint test fixtures — attribution

The `*.head.bin` and `*.tail.bin` files in this directory are **verbatim byte ranges** of published
ADAF machine-learning checkpoints, committed so that the PyTorch checkpoint reader is tested against
the real container format rather than against fixtures this repository invented. AIA-0654's first
milestone shipped a sniffer that could not recognise the file it was written for, because the test
fixture and the code shared the same wrong belief about the format; these ranges exist so that
cannot recur silently.

## Source

> **ADAF machine learning model weights**
> Kostovska, Ana; Kocev, Dragi (Jožef Stefan Institute);
> Čož, Nejc; Kokalj, Žiga (Research Centre of the Slovenian Academy of Sciences and Arts);
> Curran, Susan; Corns, Anthony (Discovery Programme).
> Version 1.0.0, published 2025-07-09. Zenodo.
> DOI: [10.5281/zenodo.15848663](https://doi.org/10.5281/zenodo.15848663)
> Record: <https://zenodo.org/records/15848663>

ADAF — Automatic Detection of Archaeological Features: <https://github.com/EarthObservation/adaf>.
The models were trained with aitlas: <https://github.com/biasvariancelabs/aitlas>.

## Licence

**CC-BY-SA-4.0** — <https://creativecommons.org/licenses/by-sa/4.0/>. The excerpts below are
distributed under that licence; this notice is the required attribution.

## What these files contain, and what they do not

Each pair is the head and tail of one published `.tar` file (which is in fact a `torch.save`
zip-serialization archive, not a tar). Exact ranges and SHA-256 digests are recorded in
`ADAFCheckpointFixtures.json` and can be reproduced with `scripts/fetch_adaf_checkpoints.sh`.

| File | Range of the original | Bytes |
|-|-|-|
| `OD_ringfort.head.bin` | 0 – 163,839 of `OD_ringfort.tar` (517,823,445 bytes) | 163,840 |
| `OD_ringfort.tail.bin` | 517,741,000 – end | 82,445 |
| `AO_HRNet.head.bin` | 0 – 655,359 of `AO_HRNet_SLRM_512px_pretrained_train_12_val_124_with_Transformation.tar` (861,530,273 bytes) | 655,360 |
| `AO_HRNet.tail.bin` | 861,110,000 – end | 420,273 |

**They contain 38,664 bytes of trained parameters, and nothing more** (AIA-0675 widened
`OD_ringfort.head.bin` from 131,072 bytes; before that they contained none). The head holds the
archive's first local file header and its `data.pkl` — the checkpoint's object graph: tensor names,
shapes, dtypes, storage keys, and the training scalars (`epoch`, `loss`, `start`, `id`) — followed
by the first five storages: `data/0` (`backbone.body.conv1.weight`, 37,632 bytes), `data/1`,
`data/10`, `data/100` and the int64 counter `data/101`. Weight extraction cannot be tested against
real bytes without at least one complete storage, and this is the smallest cut that reaches one of
each kind the extractor treats differently. The tail holds the `version` entry, the central
directory, and the ZIP64 and classic end-of-central-directory records.

The remaining 173.2 MB of trained parameters — 99.98% of them — lie in the region between the two
ranges, which is **not** included. Together the committed ranges are ~0.05% of the original file.

They are sufficient because the reader deliberately touches nothing else — its entire read set is
the end-of-central-directory records, the central directory, `data.pkl`, and `version`. A decode of
these ranges is byte-for-byte identical to a decode of the complete 517,823,445-byte download.
