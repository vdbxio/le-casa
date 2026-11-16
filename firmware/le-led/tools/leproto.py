#!/usr/bin/env python3
"""Le'Proto v0 bench tool: build command frames, send them, read Le'LED state.

An independent Python implementation of PROTOCOL.md (it uses the
`cryptography` package's AES-CCM, not the firmware's code), so it doubles as a
cross-check of the C++ in le_proto.cpp.

  leproto.py frame   --key HEX --seq N  power on
  leproto.py send    --key HEX          brightness 128      # Linux: btmgmt
  leproto.py send    --key HEX --ios    color ff0000        # macOS: as a UUID
  leproto.py state   --key HEX --mac AA:BB:..  ADVERT_HEX
  leproto.py watch   --key HEX --mac AA:BB:..               # needs bleak

Commands (opcode arguments):
  power on|off [tt]      brightness 0-255 [tt]   color RRGGBB
  white 0-255            cct KELVIN              effect ID [speed]
  effect-args IX [C1]    palette ID              preset ID
  segment ID [on] [sel]  nightlight MIN [on]     wake [SECONDS]

The sequence number must climb for each screen slot. Without --seq the tool
keeps the last one it used in ~/.config/leproto/seq-<dst id>-<slot> and adds
one. The light keeps its replay windows in RAM, so after a light reboot any
seq works again.

pip install cryptography (and bleak for `watch`; pyobjc for `send --ios`).
SPDX-License-Identifier: EUPL-1.2
"""

import argparse
import struct
import subprocess
import sys
import time

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

MAGIC = 0x4C
TYPE_COMMAND = 0x01
MFR_ID = 0xFFFF
BTHOME_UUID = 0xFCD2

OPS = {
    "power": 0x01, "brightness": 0x02, "color": 0x03, "white": 0x04,
    "cct": 0x05, "effect": 0x06, "effect-args": 0x07, "palette": 0x08,
    "preset": 0x09, "segment": 0x0A, "nightlight": 0x0B, "wake": 0x0C,
}


def aes(key, block):
    e = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return e.update(block) + e.finalize()


def derive(key):
    down = aes(key, b"LeProto-down-v0\x00")
    dst = aes(key, b"LeProto-dstid-v0")[:3]
    return down, dst


def seal(key, slot, seq, opcode, a0, a1, flags=0):
    down, dst = derive(key)
    header = bytes([MAGIC, TYPE_COMMAND | (flags & 0x30)]) + dst + bytes(
        [slot & 3]) + struct.pack("<I", seq)[:3]
    nonce = dst + bytes([slot & 3]) + struct.pack("<I", seq)[:3] + bytes(
        [header[1], 0x01]) + b"LEPR"
    ct = AESCCM(down, tag_length=4).encrypt(nonce, bytes([opcode, a0, a1]),
                                            header)
    return header + ct  # 9 + 3 + 4 = 16


def args_for(cmd, rest):
    n = [int(x, 0) for x in rest if x not in ("on", "off", "sel")]
    if cmd == "power":
        return (1 if rest and rest[0] == "on" else 0), (n[0] if n else 0)
    if cmd == "brightness":
        return n[0], (n[1] if len(n) > 1 else 0)
    if cmd == "color":
        rgb = bytes.fromhex(rest[0].lstrip("#"))
        v = ((rgb[0] >> 3) << 11) | ((rgb[1] >> 2) << 5) | (rgb[2] >> 3)
        return v & 0xFF, v >> 8
    if cmd == "cct":
        return n[0] & 0xFF, n[0] >> 8
    if cmd == "segment":
        return n[0], (1 if "on" in rest else 0) | (2 if "sel" in rest else 0)
    if cmd == "nightlight":
        return n[0], 0x80 if "on" in rest else 0
    if cmd == "wake":
        return (n[0] if n else 3), 0
    return (n[0] if n else 0), (n[1] if len(n) > 1 else 0)


def next_seq(dst, slot):
    import pathlib
    f = pathlib.Path.home() / ".config" / "leproto" / f"seq-{dst.hex()}-{slot}"
    f.parent.mkdir(parents=True, exist_ok=True)
    seq = (int(f.read_text()) if f.exists() else 0) + 1
    f.write_text(str(seq))
    return seq


def build(a):
    key = bytes.fromhex(a.key.replace(":", "").replace(" ", ""))
    op = OPS[a.command]
    a0, a1 = args_for(a.command, a.args)
    seq = a.seq if a.seq is not None else next_seq(derive(key)[1], a.slot)
    return key, seal(key, a.slot, seq, op, a0, a1), seq


def cmd_frame(a):
    key, f, seq = build(a)
    _, dst = derive(key)
    print("dst id   ", dst.hex())
    print("seq      ", seq)
    print("frame    ", f.hex())
    print("mfr advert", ("020106" + "13ff" + "ffff" + f.hex()))
    # On air a 128-bit UUID is little-endian; CBUUID strings are big-endian.
    u = f[::-1].hex()
    print("iOS UUID ", f"{u[:8]}-{u[8:12]}-{u[12:16]}-{u[16:20]}-{u[20:]}".upper())


def cmd_send(a):
    key, f, seq = build(a)
    if a.ios:
        return send_mac_uuid(f, a.seconds)
    adv = bytes([0x13, 0xFF, 0xFF, 0xFF]) + f  # flags are added by btmgmt
    print(f"seq {seq}: advertising {f.hex()} for {a.seconds} s (btmgmt)")
    subprocess.run(["btmgmt", "add-adv", "-d", adv.hex(), "-t",
                    str(a.seconds), "1"], check=True)


def send_mac_uuid(frame, seconds):
    import objc  # noqa: F401  (pyobjc)
    from CoreBluetooth import (CBAdvertisementDataServiceUUIDsKey,
                               CBPeripheralManager, CBUUID)
    from Foundation import NSDate, NSObject, NSRunLoop

    u = frame[::-1].hex()
    uuid = CBUUID.UUIDWithString_(
        f"{u[:8]}-{u[8:12]}-{u[12:16]}-{u[16:20]}-{u[20:]}")

    class Delegate(NSObject):
        def peripheralManagerDidUpdateState_(self, pm):
            if pm.state() == 5:  # powered on
                pm.startAdvertising_({CBAdvertisementDataServiceUUIDsKey: [uuid]})

    d = Delegate.alloc().init()
    pm = CBPeripheralManager.alloc().initWithDelegate_queue_(d, None)
    end = time.time() + seconds
    while time.time() < end:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.05))
    pm.stopAdvertising()
    print(f"advertised {uuid} for {seconds} s")


def decode_state(key, mac, body):
    """body = BTHome service data from the device info byte on."""
    info = body[0]
    ct, ctr, mic = body[1:-8], body[-8:-4], body[-4:]
    nonce = mac + struct.pack("<H", BTHOME_UUID) + bytes([info]) + ctr
    plain = AESCCM(key, tag_length=4).decrypt(nonce, ct + mic, None)
    assert plain[0] == 0x10 and plain[2] == 0x54, plain.hex()
    raw = plain[4:4 + plain[3]]
    c = raw[3] | raw[4] << 8
    r, g, b = (c >> 11) & 31, (c >> 5) & 63, c & 31
    return {
        "counter": struct.unpack("<I", ctr)[0], "on": bool(plain[1]),
        "rev": raw[0], "ack_slot": raw[1] >> 6, "ack_seq_low": raw[1] & 63,
        "bri": raw[2],
        "rgb": "%02x%02x%02x" % ((r << 3) | (r >> 2), (g << 2) | (g >> 4),
                                 (b << 3) | (b >> 2)),
        "fx": raw[5], "pal": raw[6], "sx": raw[7], "ix": raw[8],
        "preset": raw[9],
    }


def find_bthome(adv):
    i = 0
    while i < len(adv) and adv[i]:
        ln, t = adv[i], adv[i + 1]
        if t == 0x16 and adv[i + 2:i + 4] == b"\xd2\xfc":
            return adv[i + 4:i + 1 + ln]
        i += 1 + ln
    raise SystemExit("no BTHome service data in that advert")


def cmd_state(a):
    key = bytes.fromhex(a.key)
    mac = bytes.fromhex(a.mac.replace(":", ""))
    print(decode_state(key, mac, find_bthome(bytes.fromhex(a.advert))))


def cmd_watch(a):
    import asyncio
    from bleak import BleakScanner

    key = bytes.fromhex(a.key)
    mac = bytes.fromhex(a.mac.replace(":", ""))
    last = {}

    def cb(dev, data):
        body = data.service_data.get("0000fcd2-0000-1000-8000-00805f9b34fb")
        if not body:
            return
        try:
            s = decode_state(key, mac, body)
        except Exception:
            return
        if s != last.get("s"):
            last["s"] = s
            print(time.strftime("%H:%M:%S"), dev.address, s, flush=True)

    async def run():
        async with BleakScanner(cb):
            await asyncio.sleep(a.seconds)

    asyncio.run(run())


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="sub", required=True)
    for name in ("frame", "send"):
        s = sub.add_parser(name)
        s.add_argument("--key", required=True)
        s.add_argument("--slot", type=int, default=3)
        s.add_argument("--seq", type=int)
        s.add_argument("command", choices=sorted(OPS))
        s.add_argument("args", nargs="*")
        if name == "send":
            s.add_argument("--ios", action="store_true",
                           help="advertise as a 128-bit service UUID (macOS)")
            s.add_argument("--seconds", type=int, default=1)
    s = sub.add_parser("state")
    s.add_argument("--key", required=True)
    s.add_argument("--mac", required=True)
    s.add_argument("advert")
    s = sub.add_parser("watch")
    s.add_argument("--key", required=True)
    s.add_argument("--mac", required=True)
    s.add_argument("--seconds", type=int, default=60)
    a = p.parse_args()
    {"frame": cmd_frame, "send": cmd_send, "state": cmd_state,
     "watch": cmd_watch}[a.sub](a)


if __name__ == "__main__":
    sys.exit(main())
