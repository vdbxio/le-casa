#!/usr/bin/env bash
# Build (and optionally flash) Le'LED for the FLIP_C3.
#
#   tools/build.sh            build
#   tools/build.sh upload     build and flash over USB
#   tools/build.sh monitor    open the serial console
#
# Needs PlatformIO (`brew install platformio` or `pip install platformio`).
# WLED is checked out at a pinned release into .wled/ next to this folder.
set -euo pipefail

WLED_TAG=v16.0.1
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WLED="$HERE/.wled"

if [ ! -d "$WLED/.git" ]; then
  git clone --depth 1 --branch "$WLED_TAG" https://github.com/wled/WLED.git "$WLED"
fi
sed "s#@LELED_DIR@#$HERE#" "$HERE/platformio_override.ini.in" > "$WLED/platformio_override.ini"

cd "$WLED"
case "${1:-build}" in
  build)   pio run -e flip_c3 ;;
  upload)  pio run -e flip_c3 -t upload ;;
  monitor) pio device monitor -e flip_c3 ;;
  *) echo "usage: $0 [build|upload|monitor]" >&2; exit 2 ;;
esac
