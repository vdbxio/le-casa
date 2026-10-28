#!/usr/bin/env bash
# Le'Casa - Bluetooth-first home automation.
# Copyright (C) 2026 Chloe Madison and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
#
# Fetches Cactus's voice engine and models (Apache-2.0) from Hugging Face at
# pinned revisions and checks each against its sha256 (third_party/needle/
# README.md), and the sherpa-onnx "Hey, Gary" keyword spotter model
# (Apache-2.0) from its GitHub release. Run once before building; the files
# are not committed.
#   tool/fetch_voice.sh            everything
#   tool/fetch_voice.sh android    models + Android engines only
set -euo pipefail
cd "$(dirname "$0")/.."

NEEDLE=Cactus-Compute/needle3@d6c7d6a2e9655505e0f8e23339356dd1705900eb
WHISTLE=Cactus-Compute/whistle@741118687e1f008f06d1351a402a731274789790

# repo@commit  path-in-repo  destination  sha256
FILES="
$NEEDLE needle3.cact assets/voice/needle3.cact c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38
$WHISTLE whistle.cact assets/voice/whistle.cact b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb
$NEEDLE android-armv7/libneedle.a third_party/needle/android-armv7/libneedle.a 9f559a287b201c213e5c753d3cd1076a1849c73f94b445c85d11e4969422a135
$NEEDLE android-arm64/libneedle.a third_party/needle/android-arm64/libneedle.a 7aa6de6132a22bf45f5e903425feb66f159ad46f47fa558921bc4fd02c3a2fa0
$NEEDLE ios-arm64/libneedle.a third_party/needle/ios-arm64/libneedle.a 3e931f1d52319c1396901f3a16244ea47776d18acbf28543b62da408de45158a
$NEEDLE ios-sim-arm64/libneedle.a third_party/needle/ios-sim-arm64/libneedle.a 75f836ada53fc55cd27a30e0edaea8bf5dcbcca6e30c9f0202fa192db20cea80
$NEEDLE macos-arm64/libneedle.a third_party/needle/macos-arm64/libneedle.a 7d1368a4a42a745aba055f310913c3ed6d929dee98a89dcb955b9032b2335700
"

only="${1:-}"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

echo "$FILES" | while read -r src path dest want; do
  [ -z "$src" ] && continue
  case "$only:$path" in
    :*|*:*.cact) ;;
    android:android-*|ios:ios-*|macos:macos-*) ;;
    *) continue ;;
  esac
  if [ -f "$dest" ] && [ "$(sha "$dest")" = "$want" ]; then
    echo "ok      $dest"
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  url="https://huggingface.co/${src%@*}/resolve/${src#*@}/$path"
  echo "fetch   $dest"
  curl -fL --retry 3 -o "$dest.part" "$url"
  got="$(sha "$dest.part")"
  if [ "$got" != "$want" ]; then
    rm -f "$dest.part"
    echo "sha256 mismatch for $dest: $got" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
done

# The keyword spotter: a 3.3M-parameter zipformer trained on GigaSpeech,
# int8. Only the four files the app loads are kept.
KWS_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2
KWS_SHA=f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
KWS=assets/voice/kws
if [ -f "$KWS/encoder.onnx" ] && [ -f "$KWS/decoder.onnx" ] && [ -f "$KWS/joiner.onnx" ] && [ -f "$KWS/tokens.txt" ]; then
  echo "ok      $KWS"
else
  tmp="$(mktemp -d)"
  echo "fetch   $KWS"
  curl -fL --retry 3 -o "$tmp/kws.tar.bz2" "$KWS_URL"
  got="$(sha "$tmp/kws.tar.bz2")"
  if [ "$got" != "$KWS_SHA" ]; then
    rm -rf "$tmp"
    echo "sha256 mismatch for the keyword spotter: $got" >&2
    exit 1
  fi
  tar -xjf "$tmp/kws.tar.bz2" -C "$tmp"
  src="$tmp/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
  mkdir -p "$KWS"
  cp "$src/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$KWS/encoder.onnx"
  cp "$src/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$KWS/decoder.onnx"
  cp "$src/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$KWS/joiner.onnx"
  cp "$src/tokens.txt" "$KWS/tokens.txt"
  rm -rf "$tmp"
fi
