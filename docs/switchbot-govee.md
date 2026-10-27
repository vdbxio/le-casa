# SwitchBot and Govee

Both brands broadcast their readings in the clear, so Le'Casa reads them
with **no account, no app and no key**. Turn the device on near the
tablet and it shows up under its group (Climate, Plugs & switches,
Blinds & curtains, Doors & alarms, Buttons) with a ready-made dashboard
card.

The decoders are ported from
[pySwitchbot](https://github.com/sblibs/pySwitchbot) (MIT) and
[govee-ble](https://github.com/Bluetooth-Devices/govee-ble) (Apache-2.0),
the libraries behind Home Assistant's SwitchBot and Govee integrations,
and are tested against those projects' sample packets.

## Tested on real hardware

| Device | Where | Result |
| --- | --- | --- |
| SwitchBot Indoor/Outdoor Thermo-Hygrometer (W3400010) | MacBook (bleak), 2026-10-27 | temperature, humidity, battery |

Everything else below is decoded from upstream sample packets only. If
you own one, open a GitHub issue titled "SwitchBot report:" or "Govee
report:" with what the card shows next to what the device's own screen
or app shows.

## SwitchBot

| Model | Readings |
| --- | --- |
| Meter, Meter Plus, Indoor/Outdoor Meter, Meter Pro, Weather Station | temperature, humidity, battery |
| Meter Pro CO2 | + CO2 |
| Hub 2 | temperature, humidity, light |
| Hub 3 | temperature, humidity, light, motion |
| Contact Sensor | open, motion, light, button presses, battery |
| Motion Sensor, Presence Sensor | motion, light, battery |
| Water Leak Detector | leak, tamper, battery |
| Plug Mini (US/JP) | on, watts, Wi-Fi signal |
| Plug Mini (EU), Relay Switch 1PM / 2PM | on, watts (per channel) |
| Relay Switch 1 | on |
| Bot | press/switch mode, on, battery |
| Curtain, Curtain 3, Roller Shade | how open (0 closed, 100 open), moving, battery |
| Blind Tilt | tilt, moving, battery |
| Remote, Universal Remote | battery (and charging) |
| Lock | lock state, door, battery |

Notes:

- Some SwitchBots only name their model in the *scan response*. The
  tablet scans actively, so it gets it; a device is recognised from its
  first full packet and remembered after that.
- Reading is all this release does. Switching a Plug Mini or pressing a
  Bot needs a connection and is planned next. Locks and the Relay Switch
  family encrypt their *commands* with a key from the SwitchBot account;
  reading their state needs nothing.
- Readings are always in °C. A meter set to show °F on its screen still
  broadcasts °C.

## Govee

| Model | Readings |
| --- | --- |
| H5072, H5075, H5129, H5074, H5051, H5052, H5071 | temperature, humidity, battery |
| H5100-H5105, H5108, H5110, H5174, H5177, H5179, GV5179 | temperature, humidity, battery |
| H5178 | indoor and outdoor temperature, humidity, battery |
| H5112 | two probes, humidity, battery |
| H5140 | temperature, humidity, CO2 |
| H5106 | temperature, humidity, PM2.5 |
| H5055, H5181, H5182, H5183, H5184, H5185, H5191, H5198 | probe temperatures and alarm set points |
| H5121 motion, H5124 vibration | events, battery |
| H5122, H5125, H5126 buttons | button presses, battery |
| H5123 door | open, battery |
| H5127 presence | occupied, motion |
| H5130 pressure pad | pressed, button, battery |

Notes:

- Govee uses a different manufacturer id per model, so most models are
  recognised by the model number in their Bluetooth name (`GVH5075_2762`).
  Le'Casa names the sensor from the last four characters of that name,
  which are the end of its MAC, so every screen shows the same name.
- A probe socket with nothing plugged in shows no temperature.
- The H512x sensors scramble their packets, but the key travels in the
  packet itself, so no setup is needed.
