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
TC=
# PlatformIO's ESP32-C3 compiler is x86_64 only on macOS. On Apple Silicon
# without Rosetta, fetch Espressif's native arm64 build of the same GCC
# (crosstool-NG esp-2021r2-patch5) into .toolchain/ and point the build at it.
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] &&
   ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  TC="$HERE/.toolchain/riscv32-esp-elf-arm64"
  if [ ! -x "$TC/bin/riscv32-esp-elf-gcc" ]; then
    echo "Fetching the arm64 ESP32-C3 compiler (~200 MB, once)"
    mkdir -p "$TC"
    curl -fL --retry 3 https://github.com/espressif/crosstool-NG/releases/download/esp-2021r2-patch5/riscv32-esp-elf-gcc8_4_0-esp-2021r2-patch5-macos-arm64.tar.gz |
      tar xz -C "$TC" --strip-components 1
    echo '{"name":"toolchain-riscv32-esp","version":"8.4.0+2021r2-patch5","system":["darwin_arm64"]}' > "$TC/package.json"
  fi
fi

# Write the override; with an arm64 compiler, add it as a continuation of
# [env:flip_c3]'s platform_packages (PlatformIO refuses a second key).
awk -v dir="$HERE" -v tc="$TC" '
  { gsub(/@LELED_DIR@/, dir); print }
  tc != "" && /^platform_packages = / { print "  toolchain-riscv32-esp @ symlink://" tc }
' "$HERE/platformio_override.ini.in" > "$WLED/platformio_override.ini"

cd "$WLED"
case "${1:-build}" in
  build)   pio run -e flip_c3 ;;
  upload)  pio run -e flip_c3 -t upload ;;
  monitor) pio device monitor -e flip_c3 ;;
  *) echo "usage: $0 [build|upload|monitor]" >&2; exit 2 ;;
esac
