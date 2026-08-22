#!/usr/bin/env bash
#
# Strict local gate for AIA-0688's converted-detector parity evidence.
#
# The pytest-style script itself exits non-zero when a set differs; this wrapper additionally refuses
# the two ways a nominally green local command could be non-evidence: a sparse checkpoint and an
# interpreter without the pinned torchvision oracle dependencies.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINT_DIR="${ADAF_CHECKPOINT_DIRECTORY:-$REPO_ROOT/.adaf-checkpoints}"
PYTHON="${ADAF_PARITY_PYTHON:-$REPO_ROOT/.venv-m3a/bin/python}"
REPORT="${ADAF_PARITY_REPORT:-$REPO_ROOT/.adaf-checkpoints/aia-0688-parity.json}"

if [ ! -x "$PYTHON" ]; then
  echo "✗ parity interpreter missing: $PYTHON" >&2
  echo "  Create .venv-m3a as documented in scripts/m3a_parity_spike/README.md." >&2
  exit 1
fi
if [ ! -f "$CHECKPOINT_DIR/OD_ringfort.tar" ]; then
  echo "✗ missing $CHECKPOINT_DIR/OD_ringfort.tar; run scripts/fetch_adaf_checkpoints.sh --full." >&2
  exit 1
fi
if [ -f "$CHECKPOINT_DIR/.OD_ringfort.tar.sparse" ]; then
  echo "✗ OD_ringfort.tar is sparse; fetch a dense copy with --full before claiming parity." >&2
  exit 1
fi

cd "$REPO_ROOT"
PYTHONPATH=scripts/m3a_parity_spike "$PYTHON" -u scripts/test_adaf_fasterrcnn_parity.py --empty-tile --report "$REPORT"
echo "✓ converted Ringfort detector matched the torchvision oracle and empty-tile case; report: $REPORT"
