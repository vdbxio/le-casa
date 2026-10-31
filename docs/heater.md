# Diesel heaters

Le'Casa reads and controls Chinese diesel air heaters (Hcalory, Vevor, BYD
and other rebadges) that use the **BYD-** Bluetooth module: the heater
advertises as `BYD-<address>` with service `0xFFE0`. It connects, reads the
status, and closes the link again every 30 seconds; a change is sent and
then read back, so the card shows what the heater accepted.

> **Not yet tested on a real heater.** The protocol is re-implemented from
> [diesel-heater-ble](https://github.com/Spettacolo83/diesel-heater-ble) and
> [homeassistant-diesel-heater](https://github.com/Spettacolo83/homeassistant-diesel-heater)
> (both MIT) and checked against their test frames, but no heater has been
> seen working with Le'Casa yet.

## Protocol

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

- Hcalory's own newer modules (service `0xFFF0` "MVP1" or `0xBD39` "MVP2",
  a different framing with a PIN handshake). They are recognised by
  neither the decoder nor the driver yet.
- Fan-only ventilation, timers, altitude, the temperature offset and
  other settings the encrypted layouts carry.
- A passkey other than 1234.

To probe a heater from a Mac without changing anything, run
`tools/blescan/heater.py`: it dumps the GATT table and sends only the
status query.
