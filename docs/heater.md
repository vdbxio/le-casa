# Diesel heaters

Le'Casa reads and controls diesel air heaters over two kinds of Bluetooth
module:

- **Hcalory's own module** ("MVP2"): service `0xBD39`, usually no name.
  Chloe's Hcalory heater has this one; its status reads were checked from
  a Mac on 2026-10-31.
- **The BYD- module** of Vevor-style heaters (Vevor, BYD and other
  rebadges): advertises as `BYD-<address>` with service `0xFFE0`. Not yet
  tested on a real heater.

Le'Casa connects, reads the status, and closes the link again every 30
seconds; a change is sent and then read back, so the card shows what the
heater accepted. Both protocols are re-implemented from
[diesel-heater-ble](https://github.com/Spettacolo83/diesel-heater-ble) and
[homeassistant-diesel-heater](https://github.com/Spettacolo83/homeassistant-diesel-heater)
(both MIT), with button values cross-checked against
[hcalory-control](https://github.com/evanfoster/hcalory-control).

## Hcalory module (0xBD39)

Write `0xBDF7` without response; replies and a status every second or so
are notified on `0xBDF8`. Every frame is `00 0k 00 01 00 01 <dp hi> <dp lo>
00 00 <len> <payload> <sum of bytes 8 onwards>`, where `k` is 2 for a
command, 3 for a reply and 1 for pushed status.

Nothing is answered until the 4-digit PIN is sent (dp `0A0C`, payload
`01 d1 d2 d3 d4`); the reply has `01` at byte 17 when accepted, `02` when
refused. Le'Casa tries 0000, then 1234. Chloe's heater takes 0000.

| dp | what | payload |
| --- | --- | --- |
| `0E04` | button | eight `00`, then 00 status, 01 off, 02 on, 03 up, 04 down, 06 thermostat mode, 07 level mode |
| `0607` | level | level |
| `0706` | thermostat target | target, unit (0 °C, 1 °F) |

The status (dp `2303`, 43 bytes) has the state at byte 20 (high nibble:
0 off, 4 stopping, 8 heating, C fan only, F fault; low nibble the step),
the mode at 21, the level, target or fault code at 22, the supply voltage
in tenths at 24-25, and the exchanger and cabin temperatures in tenths at
27-28 and 30-31, all big-endian. Byte 37 is 1 for Fahrenheit. The parser is
`lib/drivers/hcalory_protocol.dart`.

## BYD- module (0xFFE0)

One characteristic, `0xFFE1`, takes commands (written without response)
and notifies status.

A command is eight bytes, always in the clear:
`AA 55 <passkey/100> <passkey%100> <cmd> <arg lo> <arg hi> <sum of bytes 2-6>`.
The passkey is 1234 unless it was changed on the heater's controller.

| cmd | what | argument |
| --- | --- | --- |
| 1 | status | 0 |
| 2 | mode | 1 level, 2 thermostat |
| 3 | power | 1 on, 0 off |
| 4 | level or target | level 1-10 in level mode, 8-36 °C in thermostat mode |

Status comes back in one of four layouts, told apart by header and length:
`AA 55` (18 or 20 bytes) or `AA 66` (20 bytes) in the clear, or either one
padded to 48 bytes and XORed with the ASCII key `password`. The parser is
`lib/drivers/heater_protocol.dart`; field offsets are in its comments.

## Not covered yet

- Hcalory's older "MVP1" module (service `0xFFF0`, the same framing as
  MVP2 but shared with other brands' modules, so not recognised yet).
- Fan-only ventilation, timers, altitude, the temperature offset and
  other settings the encrypted layouts carry.
- A BYD- passkey other than 1234, or a Hcalory PIN other than 0000 and
  1234.

To probe a heater from a Mac without changing anything, run
`tools/blescan/heater.py`: it dumps the GATT table and sends only the
status query; `tools/blescan/hmvp2.py` does the same for the Hcalory
module, PIN included.
