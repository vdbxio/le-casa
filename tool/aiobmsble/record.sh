#!/usr/bin/env bash
# Re-records the BMS test vectors in test/bms/vectors from an aiobmsble
# checkout: runs aiobmsble's own test suite with the bmsrec plugin, which
# logs every GATT write, read and notification plus the sample returned.
#
#   tool/aiobmsble/record.sh /path/to/aiobmsble   (venv with aiobmsble[dev] active)
set -euo pipefail
src="$(cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"
(cd "$src" && BMSREC_OUT="$tmp" PYTHONPATH="$here" \
  python -m pytest -q -p no:cacheprovider -p bmsrec -o addopts="" tests/bms) || true
python3 "$here/merge_vectors.py" "$tmp" "$repo/test/bms/vectors"
(cd "$src" && python "$here/advdump.py" "$repo/test/bms/vectors/_advertisements.json")
rm -rf "$tmp"
