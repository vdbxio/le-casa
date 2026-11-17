# Le'Proto v0

Le'Proto is how Le'Casa screens and Le'devices talk over Bluetooth LE
without connecting. Devices broadcast their state, screens broadcast short
encrypted commands, and the state a device broadcasts next is the
acknowledgement. Le'LED (the WLED usermod in this folder) is the first
device to speak it.

This is version 0: the frame layout is settled enough to build on, but
expect changes before v1. The reference code is [`le_proto.cpp`](le_proto.cpp)
(C++, runs on the ESP32 and in the host tests) and
[`tools/leproto.py`](tools/leproto.py) (Python, written separately from the
C++; `tests/cross_check.py` checks the two agree byte for byte).

## Relationship to BTHome

Le'Proto is a companion to [BTHome](https://bthome.io), not an extension of it.

- **Uplink (device to everyone)** is plain, spec-conformant encrypted BTHome
  v2 on UUID 0xFCD2. Home Assistant and Le'Casa's existing BTHome decoder read
  it with the device key as the bindkey.
- **Downlink (screen to device)** is Le'Proto's own frame under its own
  identifier. BTHome says control is out of its scope, so commands never
  go out under 0xFCD2.
- Devices also accept plain encrypted BTHome from remotes they know: button
  events (0x3A) from Le'Fobs, and the BTHome `command` object (0x3B).

## Keys

Each device has one 16-byte key, made on the device from its RF random
generator at first boot.

| Name | Value | Used for |
| --- | --- | --- |
| device key `K` | 16 random bytes | the BTHome bindkey of the state advert |
| downlink key `Kd` | `AES-128(K, "LeProto-down-v0\0")` | AES-CCM of command frames |
| destination id | first 3 bytes of `AES-128(K, "LeProto-dstid-v0")` | addressing commands |

Both labels are exactly 16 ASCII bytes (the first ends in a zero byte).
Anyone holding `K` can control the device; anyone without it can see that
adverts exist but cannot read or forge them.

## Downlink: the compact command frame (16 bytes)

| Offset | Size | Field | Notes |
| --- | --- | --- | --- |
| 0 | 1 | magic | `0x4C` (`L`) |
| 1 | 1 | header | bits 7-6 version (0), bit 5 group (reserved), bit 4 ack wanted (reserved), bits 3-0 type: `1` = command |
| 2 | 3 | destination id | from the key, see above |
| 5 | 1 | source slot | 0-3, one per screen |
| 6 | 3 | sequence | little-endian, starts at 1, must climb per slot |
| 9 | 3 | payload | **encrypted**: opcode, arg 0, arg 1 |
| 12 | 4 | MIC | AES-CCM tag |

AES-CCM with `Kd`, a 4-byte MIC and a 2-byte length field. The 9 header bytes
(offsets 0-8) are the associated data, so the destination, slot and sequence
are authenticated but readable. The 13-byte nonce is:

```
destination id (3) | slot (1) | sequence (3) | header (1) | direction 0x01 (1) | "LEPR" (4)
```

### How a frame travels

- **Android and ESP32**: manufacturer-specific data, company id `0xFFFF`,
  followed by the 16 bytes. `0xFFFF` is the Bluetooth SIG's id for testing;
  a shipping product needs a real company id.
- **iOS and macOS**: apps can only advertise a name and service UUIDs, so
  the 16 bytes go out as one 128-bit service UUID. A UUID is little-endian
  on air, so the CBUUID string is the frame reversed
  (`leproto.py frame` prints it). Only one UUID, app in the foreground:
  UUIDs that don't fit go to Apple's best-effort "overflow area".

A device accepts either form.

### Sending and acknowledging

Commands set state ("brightness 128"), never toggle it, so sending one twice
is harmless. A screen repeats its frame about every 100 ms, with the same
sequence number, until the device's state advert shows the new state with
its slot and the low 6 bits of its sequence in the ack byte. Then it stops.
While the device keeps hearing the frame it already took, it keeps its fast
(30 ms) adverts going, so a screen that hears only some packets still
catches the ack. A repeat is not run again.
For a slider, send only the latest value, at most about 10 a second, each
with a new sequence number.

### Replay protection

The device keeps the highest sequence it accepted for each of the 4 slots and
refuses anything at or below it. In v0 these windows live in RAM, so for a few
seconds after a device reboots, a recorded frame could be replayed once.
Persisting them is planned.

## Opcodes

| Opcode | Name | Arg 0 | Arg 1 | WLED JSON it becomes |
| --- | --- | --- | --- | --- |
| `0x01` | power | 0 off, 1 on | transition, 100 ms steps | `{"on":…,"tt":…}` |
| `0x02` | brightness | 0-255 | transition | `{"bri":…,"tt":…}` |
| `0x03` | colour | RGB565, low byte | RGB565, high byte | `seg.col[0]`, white kept |
| `0x04` | white | 0-255 | unused | `seg.col[0]` white, colour kept |
| `0x05` | colour temperature | Kelvin, low byte | Kelvin, high byte | `seg.cct` |
| `0x06` | effect | effect id | speed | `seg.fx`, `seg.sx` |
| `0x07` | effect arguments | intensity | custom 1 | `seg.ix`, `seg.c1` |
| `0x08` | palette | palette id | unused | `seg.pal` |
| `0x09` | preset | 1-250 | unused | `{"ps":…}` |
| `0x0A` | segment | segment id | bit 0 on, bit 1 selected | `seg[id].on`, `.sel` |
| `0x0B` | nightlight | minutes | bit 7 on, bits 0-1 mode | `nl` |
| `0x0C` | wake | seconds | unused | advertise fast so a new screen catches up |

`seg` without an id applies to the selected segments, as WLED's own UI does.
RGB565 gives 32-64 levels per channel, fine for a colour wheel; exact colours
go through presets.

## Uplink: the state advert

An encrypted BTHome v2 advert, device info byte `0x41` (v2, encrypted,
regular updates). BTHome's nonce is the device's MAC (most significant byte
first), `D2 FC`, the info byte and the 4-byte counter.

| Object | Bytes | Content |
| --- | --- | --- |
| `0x10` power | 1 | 1 = on |
| `0x54` raw | 1 + 10 | the Le'LED state below |

Raw state (10 bytes):

| Offset | Field |
| --- | --- |
| 0 | revision, +1 on every change |
| 1 | ack: slot in bits 7-6, sequence low 6 bits in bits 5-0 |
| 2 | brightness (the last brightness when off) |
| 3-4 | colour, RGB565 little-endian |
| 5 | effect id |
| 6 | palette id |
| 7 | speed |
| 8 | intensity |
| 9 | current preset (0 = none) |

With flags, the whole advert is 30 bytes. The scan response holds the
device name (`LeLED-xxxx`) and the MAC, because iOS and macOS never show an
app the address of what it hears and BTHome's nonce needs it: manufacturer
data with company id `0xFFFF`, then `0x4D` (`M`) and the 6-byte MAC, most
significant byte first. Apple's scanners scan actively and keep the scan
response with the device, so a screen there has the MAC from the first
sighting. The advert repeats every 1 s, and every 30 ms for 2 s
after a change or a command.

The BTHome counter is reserved 4096 at a time in NVS, so it never repeats
across reboots.

## Remotes (BTHome in, no screen needed)

A device can be given up to 4 remote keys. An encrypted BTHome advert that
decrypts with one of them is a remote press. The first one that decrypts
ties that key to the sender's address.

- Button events (`0x3A`, one per button, Le'Fob style): press and long press
  run the action set for that button. Le'LED's actions are WLED JSON, by
  default: 1 toggle / all off, 2 brighter / full, 3 dimmer / low,
  4 next preset / preset 1.
- The BTHome `command` object (`0x3B`): off, on, toggle, step up, step down.

The BTHome counter must climb (replays are dropped), and rounds of one press
sharing a packet id (`0x00`) run once.

## Not in v0

- Pairing and key delivery over Bluetooth. For now the key is read from the
  serial console or the WLED settings page and typed into Le'Casa.
- The GATT channel for setup and long lists (effect names, presets).
- Group addressing and the long (extended advert) frame.
- Persisted replay windows.
