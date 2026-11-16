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

# PlatformIO's ESP32-C3 compiler is x86_64 only on macOS, so Apple Silicon
# needs Rosetta ("Bad CPU type in executable" otherwise).
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] &&
   ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Apple Silicon without Rosetta: run 'softwareupdate --install-rosetta' first" >&2
  exit 1
fi

cd "$WLED"
case "${1:-build}" in
  build)   pio run -e flip_c3 ;;
  upload)  pio run -e flip_c3 -t upload ;;
  monitor) pio device monitor -e flip_c3 ;;
  *) echo "usage: $0 [build|upload|monitor]" >&2; exit 2 ;;
esac
