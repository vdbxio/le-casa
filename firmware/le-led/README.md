# Le'LED

Le'LED is a [WLED](https://kno.wled.ge) usermod that lets Le'Casa run a WLED
light over Bluetooth LE, with Wi-Fi switched off and no connection held open.
It is the first device to speak [Le'Proto](PROTOCOL.md).

- **State out:** the light broadcasts its power, brightness, colour, effect,
  palette, speed, intensity and preset as an encrypted BTHome v2 advert,
  every second and every 30 ms for 2 s after a change. Every Le'Casa screen
  in range reads it at once, and Home Assistant can too. The scan response
  carries the MAC, so iPads and iPhones (which hide MACs) can decrypt it.
- **Commands in:** the light scans all the time for 16-byte encrypted
  Le'Proto frames. An Android screen sends them as manufacturer data, an iPad
  as a 128-bit service UUID. Each command is turned into WLED JSON and
  applied exactly as the WLED app would.
- **Le'Fob buttons:** give the light a Le'Fob's key and its four buttons
  control the light directly, no screen needed.

The first target is Chloe's **FLIP_C3** board (ESP32-C3-MINI-1, onboard
WS2812 on GPIO8 chained to the RGBOUT header, BOOT button on GPIO9, red LED
on GPIO10).

## Status

v0, built from WLED v16.0.1 (85% of the app slot, 23% RAM). **Bench-tested
on a FLIP_C3 (2026-11-15):** commands sent from a Mac as a service UUID (the
iPad path) were all applied and acked in the next state advert, within about
1 s, and replayed frames were refused. Android-style sending and Le'Fob are
not radio-tested yet.
The byte-level code (`le_proto.cpp`) is host-tested: BTHome's published
encryption example decrypts, frames round-trip, tampering and replays are
refused, and a separate Python implementation (`tools/leproto.py`) agrees
byte for byte.

## Build and flash

Needs PlatformIO (`brew install platformio`). PlatformIO's ESP32-C3 compiler
is Intel-only on macOS, so on an Apple Silicon Mac without Rosetta the script
fetches Espressif's native arm64 build of the same compiler into `.toolchain/`
the first time.

```sh
cd firmware/le-led
tools/build.sh            # checks out WLED v16.0.1 into .wled/ and builds
tools/build.sh upload     # flash the FLIP_C3 over USB
tools/build.sh monitor    # serial console
```

On first boot the light makes its key and prints it on the serial console:

```
Le'LED key 3f9a...c2, Le'Proto id 1b2c3d
```

Wi-Fi stays off. To reach WLED's web UI, hold BOOT for 6 s (not 10: that
factory-resets and makes a new key) and join the `WLED-AP` network
(password `wled1234`). The key, the remote keys and the button actions are
under Config > Usermods > LeLED.

## Use it from a computer (bench testing)

`tools/leproto.py` builds and sends frames, and reads the state advert back.
`pip install cryptography bleak` first (and `pyobjc` on a Mac).

```sh
# Mac: send as a service UUID, the way an iPad will
tools/leproto.py send --ios --key KEY power on
tools/leproto.py send --ios --key KEY color ff6000
tools/leproto.py send --ios --key KEY brightness 40

# Linux with BlueZ: send as manufacturer data, the way Android will
sudo tools/leproto.py send --key KEY effect 9 200

# Watch the light's state. The BLE MAC is the chip's base MAC + 2
# (esptool prints the base MAC when flashing).
tools/leproto.py watch --key KEY --mac AA:BB:CC:DD:EE:FF
```

## Le'Fob

Hold SW2 on the fob for 5 s while it is plugged in over USB, with the cursor
in a **Fob 1** field on the LeLED settings page. The fob types its key in.
Save, and the light learns the fob's address on its first press. The fob
stays encrypted, and replays are refused.

| Button | Press | Long press |
| --- | --- | --- |
| 1 | toggle | off |
| 2 | brighter | full brightness |
| 3 | dimmer | low |
| 4 | next preset (1-16) | preset 1 |

Each action is WLED JSON (`{"on":"t"}`, `{"bri":"~32"}`, ...), so any of them
can be changed on the settings page.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | on | |
| `btOnly` | on | keeps WLED's AP closed until BOOT is held 6 s. Leave the Wi-Fi network empty so Wi-Fi stays off |
| `key` | made at first boot | 32 hex. Clear it to make a new one |
| `statusPin` | 10 on FLIP_C3 | LED that blinks on each accepted command, -1 for none |
| `fob1`-`fob4` | empty | Le'Fob (or other encrypted BTHome remote) keys |
| `b1`-`b4`, `b1long`-`b4long` | see above | WLED JSON per button |

## Known limits (v0)

- The key is shown on the serial console and stored in WLED's `cfg.json`.
  Anyone with the board on USB, or on the WLED AP, can read it.
- Replay windows are kept in RAM, so a recorded command could be replayed
  once in the seconds after the light reboots.
- No pairing or setup over Bluetooth yet; that is the GATT step in the plan.
- ESP32 parts with Bluetooth LE only (C3, C5, C6, S3, classic ESP32). Not
  ESP8266, S2 or P4.

## Files

| File | What |
| --- | --- |
| `le_proto.h`, `le_proto.cpp` | everything byte-level: CCM, BTHome, Le'Proto frames, opcode to JSON |
| `le_led.cpp` | the WLED usermod: NimBLE scan and advertise, settings, Le'Fob |
| `PROTOCOL.md` | the Le'Proto v0 wire format |
| `platformio_override.ini.in` | the FLIP_C3 build |
| `tests/` | host tests (`make -C tests`) and the Python cross-check |
| `tools/build.sh`, `tools/leproto.py` | build/flash, and the bench tool |

Licence: EUPL-1.2, the same as WLED, so the usermod can go upstream. EUPL-1.2
lists GPL-3.0 as a compatible licence.
