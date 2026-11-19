#!/usr/bin/env python3
"""Check tools/leproto.py (Python, `cryptography`) against the vectors the C++
host test prints, so two independent implementations agree byte for byte."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import leproto  # noqa: E402

key = bytes.fromhex("00112233445566778899aabbccddeeff")
down, dst = leproto.derive(key)
assert down.hex() == "598fdc7555a68d2fa212ec83219361bb", down.hex()
assert dst.hex() == "358341", dst.hex()
f = leproto.seal(key, 1, 42, 0x02, 200, 3)
assert f.hex() == "4c01358341012a0000a8c6baa8679123", f.hex()
s = leproto.decode_state(key, bytes.fromhex("a0b1c2d3e4f5"), leproto.find_bthome(
    bytes.fromhex("0201061a16d2fc416483fc80612c1f0691b8e3ff4594e80300003cc6a4f0")))
assert s["on"] and s["bri"] == 128 and s["rev"] == 5 and s["preset"] == 7, s
print("cross check: Python and C++ agree")
