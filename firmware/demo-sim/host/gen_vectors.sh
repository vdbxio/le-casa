#!/bin/sh
# Builds the simulator's frame code for this computer and writes
# test/vectors/demo_sim.json, which test/demo_sim_test.dart decodes with
# Le'Casa's real decoders. Rerun after changing anything in main/.
# Needs a C compiler and OpenSSL headers (apt install libssl-dev, or
# brew install openssl and set CFLAGS/LDFLAGS).
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=$(mktemp -d)
cc -std=c11 -O1 -Wall -Wextra $CFLAGS -o "$out/vectors" \
  "$here/vectors.c" "$here/aes_host.c" \
  "$here/../main/frames.c" "$here/../main/sim.c" "$here/../main/devices.c" \
  $LDFLAGS -lcrypto -lm
mkdir -p "$repo/test/vectors"
"$out/vectors" > "$repo/test/vectors/demo_sim.json"
rm -rf "$out"
echo "wrote test/vectors/demo_sim.json"
