# Third-party notices

Le'Casa is GPL-3.0-or-later with an App Store exception (see `LICENSE` and
`LICENSE-EXCEPTION`). It stands on the shoulders of these projects:

| What | Where it came from | License |
| --- | --- | --- |
| Victron Instant Readout record layouts, model id table (`lib/decoders/victron.dart`, `victron_models.dart`) and test vectors | [keshavdv/victron-ble](https://github.com/keshavdv/victron-ble) | MIT |
| BTHome v2 object table and test vectors (`lib/decoders/bthome_objects.dart`, `test/bthome_test.dart`) | [Bluetooth-Devices/bthome-ble](https://github.com/Bluetooth-Devices/bthome-ble) and the [BTHome format](https://bthome.io/format/) | MIT |
| pvvx custom / ATC1441 advertising formats | [pvvx/ATC_MiThermometer](https://github.com/pvvx/ATC_MiThermometer) | GPL-3.0 (format description only) |
| Improv BLE advertisement format (`lib/decoders/improv.dart`) | [Improv Wi-Fi](https://www.improv-wifi.com/ble/) | format description only, no code copied |
| Daly BMS BLE register layouts, alarm bit table and request bytes (`lib/drivers/daly_protocol.dart`) | [syssi/esphome-daly-bms](https://github.com/syssi/esphome-daly-bms) (daly_bms_ble) and [patman15/aiobmsble](https://github.com/patman15/aiobmsble) | protocol documentation only, re-implemented in Dart; no code copied (GPL-3.0 / Apache-2.0 upstream) |
| BMS drivers, matchers and test traces (`lib/bms/`, `test/bms/vectors/`), ported line by line to Dart | [patman15/aiobmsble](https://github.com/patman15/aiobmsble) | Apache-2.0 (`third_party/aiobmsble/LICENSE`); each ported file says so in its header |
| Alpicool / Brass Monkey fridge protocol (`lib/drivers/alpicool_protocol.dart`) | [jgalea/fridgekit](https://github.com/jgalea/fridgekit) PROTOCOL.md and [klightspeed/BrassMonkeyFridgeMonitor](https://github.com/klightspeed/BrassMonkeyFridgeMonitor) | protocol notes only, re-implemented in Dart; no code copied (MIT) |
| Xiaomi LYWSD03MMC stock GATT characteristics (`lib/drivers/xiaomi_driver.dart`) | [uduncanu/lywsd03mmc](https://github.com/uduncanu/lywsd03mmc) | UUIDs and value layout only, no code copied (MIT) |
| SwitchBot advertisement layouts and model table (`lib/decoders/switchbot.dart`), Plug Mini command frames (`lib/drivers/switchbot_driver.dart`) and test vectors | [sblibs/pySwitchbot](https://github.com/sblibs/pySwitchbot) | MIT |
| Govee advertisement layouts, H512x decryption and test vectors (`lib/decoders/govee.dart`, `test/switchbot_govee_test.dart`) | [Bluetooth-Devices/govee-ble](https://github.com/Bluetooth-Devices/govee-ble), itself from [Ernst79/bleparser](https://github.com/Ernst79/bleparser) | Apache-2.0 (govee-ble), MIT (bleparser) |
| `bluetooth_low_energy` Flutter plugin | [yanshouwang/bluetooth_low_energy](https://pub.dev/packages/bluetooth_low_energy) | MIT |
| `pointycastle` (AES-CTR, AES-CCM) | [bcgit/pc-dart](https://pub.dev/packages/pointycastle) | MIT |
| League Spartan typeface (`assets/fonts/`) | [The League of Moveable Type](https://github.com/theleagueof/league-spartan), via Google Fonts | SIL Open Font License 1.1 (`assets/fonts/OFL.txt`) |
| Weather forecasts and place search (`lib/weather/weather.dart`) | [Open-Meteo](https://open-meteo.com/) API, called at runtime when the tablet is online | data under CC BY 4.0, no code copied |
| Flutter | [flutter/flutter](https://flutter.dev) | BSD-3-Clause |

## Why not flutter_blue_plus

flutter_blue_plus 2.x (September 2025 onward) moved from BSD-3 to the
"FlutterBluePlus License", which requires a paid commercial licence for any
for-profit use, forbids relicensing, and phones home at build time. That is
not compatible with a GPL app that may be sold or used commercially, so
Le'Casa uses `bluetooth_low_energy` (MIT), which also supports the
peripheral role we need later for tablet-to-tablet sync and the phone relay.
