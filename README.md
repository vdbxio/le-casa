# Le'Casa

Le'Casa is a Bluetooth-first home automation app for vans, boats and
off-grid homes. A cheap Android tablet (or an iPad) on the wall is the
whole system: it listens to your sensors, solar chargers and battery
monitor over Bluetooth, shows a dashboard, and later controls the fridge,
heater and lights. No router, no Raspberry Pi, no cloud, no login.

Built in Flutter. GPL-3.0-or-later with an [App Store exception](LICENSE-EXCEPTION).

## Status: Phase 0, the Bluetooth spike

This is the first milestone: prove that a tablet can hear and decode the
gear in Chloe's van. The app currently

- lists every BLE broadcast the radio hears, with raw bytes and packet rate;
- decodes **BTHome v2** (plain and AES-CCM encrypted): Xiaomi LYWSD03MMC on
  pvvx firmware, Le'Fob button events, any other BTHome broadcaster;
- decodes **Victron Instant Readout** (AES-CTR): SmartSolar/BlueSolar MPPT
  chargers, SmartShunt/BMV battery monitors, Orion DC/DC. Model names come
  straight from the unencrypted header, so an MPPT is recognised before
  you enter its key;
- recognises a Xiaomi sensor still on **stock firmware** and tells you to
  flash pvvx, and reads the pvvx "custom" and ATC1441 formats in the
  meantime;
- stores per-device encryption keys on the tablet.

Not yet: dashboard layout, two-way devices (Alpicool, Hcalory, Daly BMS),
tablet-to-tablet sync, phone relay, voice. See the roadmap below.

## Try it on the Android tablet

1. Install Flutter (3.47 or newer) and Android Studio's SDK, or grab the
   debug APK from the latest CI run under *Actions → CI → Artifacts*.
2. Enable developer mode and USB debugging on the tablet.
3. `flutter run` (or `adb install app-debug.apk`).
4. Allow the "Nearby devices" permission when asked (there is also an
   *Allow* button in the status bar). On Android 11 and older the prompt
   is for location instead, and location services must be on; Android
   requires that for any BLE scan on those versions.
5. Walk around the van. Recognised devices float to the top. Tap one for
   raw bytes, packet rate and the key field.

### Victron keys

VictronConnect → the device → ⚙ Settings → ⋮ → Product info → *Instant
readout via Bluetooth* must be **on** → *Show* the encryption key. Copy
the 32 hex characters into the device page in Le'Casa. The first byte of
the key is also sent in clear by the device, so a wrong key is spotted
immediately.

### Xiaomi LYWSD03MMC

Flash [pvvx firmware](https://pvvx.github.io/ATC_MiThermometer/TelinkMiFlasher.html)
from Chrome on a laptop or Android, then in the same page set
*Advertising type* to **BTHome**. Done; the sensor shows up as
"Xiaomi LYWSD03MMC (pvvx)".

### Le'Fob

Raw BTHome today. When the firmware gains encryption, paste its bindkey
on the device page. If the fob is to work on iPad too it must include its
MAC address in the BTHome payload (device-info bit 1), because iOS never
tells apps the sender's MAC and the MAC is part of the AES-CCM nonce.

## iPad

Builds and runs; iOS reports service data and manufacturer data for
broadcasts in the foreground. Known limits: no MAC addresses (see Le'Fob
note), and scanning stops when the app leaves the foreground. The plan is
for the tablet to be a foreground kiosk anyway.

## Project layout

```
lib/
  decoders/      pure Dart packet decoders + tests in test/
    bthome.dart  BTHome v2 (plain + encrypted)
    victron.dart Victron Instant Readout
    xiaomi.dart  stock MiBeacon detection, pvvx custom, ATC1441
    registry.dart "match a broadcast, pick a decoder"
  ble/           radio wrapper (bluetooth_low_energy) and device tracker
  keys/          per-device encryption keys (shared_preferences)
  ui/            scan list and device detail pages
```

Decoders are pure functions over `RawAdvertisement` and every one has a
test with a real packet, so adding a device means adding a decoder and a
packet. That is the seed of the zero-setup "device found, tap to add" flow.

## Roadmap

| Phase | What | Status |
| --- | --- | --- |
| 0 | Bluetooth spike: hear and decode Xiaomi, Victron, Le'Fob | **in progress** |
| 1 | Read-only dashboard with the entity model | |
| 2 | Two-way devices: Alpicool fridge, Hcalory heater, Daly BMS (auto-detected) | |
| 3 | Phone companion relaying weather and the internet over BLE | |
| 4 | Multiple tablets syncing over BLE; ESPHome over BLE | |
| 5 | Automations, Le'Configurator, offline voice ("Hey, Gary") | |

## Licence

GPL-3.0-or-later with the App Store exception in `LICENSE-EXCEPTION`.
Third-party code and formats are listed in `NOTICE.md`. Contributions are
accepted under the same terms, see `CONTRIBUTING.md`.
