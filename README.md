# Le'Casa

Le'Casa is a Bluetooth-first home automation app for vans, boats and
off-grid homes. A cheap Android tablet (or an iPad) on the wall is the
whole system: it listens to your sensors, solar chargers and battery
monitor over Bluetooth, shows a dashboard, and later controls the fridge,
heater and lights. No router, no Raspberry Pi, no cloud, no login.

Built in Flutter. GPL-3.0-or-later with an [App Store exception](LICENSE-EXCEPTION).

## Status: Phase 0 done, "connect and read" in progress

The first milestone proved that a tablet can hear and decode the gear in
Chloe's van. The next one adds devices that only talk over a connection.
The app currently

- lists every BLE broadcast the radio hears, with raw bytes and packet rate;
- decodes **BTHome v2** (plain and AES-CCM encrypted): Xiaomi LYWSD03MMC on
  pvvx firmware, Le'Fob button events, any other BTHome broadcaster;
- decodes **Victron Instant Readout** (AES-CTR): SmartSolar/BlueSolar MPPT
  chargers, SmartShunt/BMV battery monitors, Orion DC/DC. Model names come
  straight from the unencrypted header, so an MPPT is recognised before
  you enter its key;
- decodes **stock Xiaomi MiBeacon** broadcasts (AES-CCM) once you enter
  the sensor's bindkey (see below), and reads the pvvx "custom" and
  ATC1441 formats;
- recognises **Improv BLE** Wi-Fi setup broadcasts and parks them in
  their own group;
- stores per-device encryption keys on the tablet;
- **connects and reads** devices that do not broadcast their values, one
  at a time, then disconnects so the device stays free for its own app:
  - **Daly smart BMS** (`DL-…` modules): pack voltage, current, power,
    state of charge, remaining Ah, every cell voltage and spread,
    temperatures, MOSFET state, cycles and alarms. Both module
    generations are auto-detected (the newer `0xD2` dialect and the older
    `0x81` one). Polled every 30 s.
  - **Alpicool fridges** (and Brass Monkey, Vevor and other rebadges of
    the same controller): temperature, target, power, Eco, supply voltage
    and battery protection, read every minute. The device page has
    controls for power, target, Eco, the button lock and battery
    protection; every change is read back from the fridge. Close the
    Alpicool app first, since the fridge takes one connection at a time.
  - **Xiaomi LYWSD03MMC on stock firmware**: temperature, humidity and
    battery over the plain GATT characteristic, no bindkey needed. Polled
    every 5 minutes because connecting costs the coin cell far more than
    listening does; flashing pvvx + BTHome is still the better setup.
  - **Every BMS aiobmsble supports** (50 types: JBD, JiKong, ANT, Seplos, Renogy, Redodo,
    Pylontech, ECO-WORTHY, Dometic and more), through a Dart port of
    [aiobmsble](https://github.com/patman15/aiobmsble). Batteries that
    need a PIN get a *Battery PIN* field on their page. Full list, PIN
    notes and iPad limits in [docs/bms.md](docs/bms.md).
  - Le'Casa only connects to devices you turn on: each device has a
    "Connect to this device" switch (off until you turn it on, so a
    campground full of other people's batteries and fridges is left
    alone) and a "Read now" button on its page. Broadcasts are always read.
    The choice is shared with every screen in the home, and the link icon
    on the scan screen pauses all connections at once (handy when you want
    to use the vendor app).
  - Known issue: the PRITOM M10 test tablet loses every link to the Daly
    module about 4 s after the module's connection-parameter update.
    Asking Android for other link parameters or the 1M PHY changes
    nothing (tested 2026-10-25), and the same module reads fine on a Mac
    and on the iPad. When a device drops the link three polls in a row,
    its page now says so instead of retrying in silence.

Not yet: dashboard layout, controlling two-way devices (Alpicool, Hcalory),
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
5. Walk around the van. Recognised devices are grouped by type (Climate,
   Solar, Battery, Buttons, Le' devices, ...) in square tiles at the top;
   tap a tile for its devices and a device for raw bytes, packet rate and
   the key field. Everything unrecognised is listed below in the order it
   was first heard, so rows do not jump around. Devices waiting for Wi-Fi
   setup over Improv BLE (fresh ESPHome boards and similar) are tucked into
   a collapsed group at the very end.

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

### Xiaomi bindkey (stock firmware)

A sensor left on stock firmware encrypts its broadcasts with a bindkey.
Le'Casa reads it over a connection every 5 minutes without one, but with
the bindkey every screen reads its broadcasts as they come and nothing
needs to connect. Paste the 32 hex characters into *Encryption key* on
the sensor's page; the key reaches your other screens by itself.

Two ways to get a bindkey:

1. **Without a Xiaomi account (recommended).** Open the
   [TelinkMiFlasher page](https://pvvx.github.io/ATC_MiThermometer/TelinkMiFlasher.html)
   in Chrome on a laptop or an Android phone, tick *Get Advertising MAC*
   if offered, *Connect* to the sensor and press **Do Activation**. The
   page makes a new bindkey on your machine and shows it (*Mi Bind
   Key*). The sensor is then bound to that key and drops out of Mi Home,
   so use this for sensors you only read with Le'Casa.
2. **From your Xiaomi account,** for sensors you want to keep in Mi Home.
   Run [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)
   (`pip install` and run `token_extractor.py`, or the prebuilt
   Windows/macOS binary), sign in with your Xiaomi account, pick the
   server region your Mi Home app uses, and copy the *BLE KEY* shown
   for each sensor, matching it by MAC. The login goes to Xiaomi's
   servers; Le'Casa itself never needs it.

Flashing pvvx firmware with BTHome (above) avoids bindkeys altogether.

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
  drivers/       GATT drivers for devices that need a connection
    daly_protocol.dart  Daly frame building/parsing (pure, tested)
    daly_driver.dart    auto-detects the Daly dialect and reads a snapshot
    xiaomi_driver.dart  stock LYWSD03MMC live characteristic
    bms_driver.dart     runs the aiobmsble port and builds the card
  bms/           aiobmsble port: BaseBms, 50 drivers, registry (generated
                 by tool/aiobmsble/gen_registry.py)
  ble/           radio wrapper (bluetooth_low_energy), device tracker,
                 GattSession abstraction and the connection manager that
                 polls one device at a time
  keys/          per-device encryption keys (shared_preferences)
  ui/            scan list and device detail pages
```

Decoders are pure functions over `RawAdvertisement` and every one has a
test with a real packet, so adding a device means adding a decoder and a
packet. That is the seed of the zero-setup "device found, tap to add" flow.

## Roadmap

| Phase | What | Status |
| --- | --- | --- |
| 0 | Bluetooth spike: hear and decode Xiaomi, Victron, Le'Fob | done |
| 0.5 | Connect and read: Daly BMS, stock Xiaomi over GATT | **in progress** |
| 1 | Read-only dashboard with the entity model | |
| 2 | Two-way devices: Alpicool fridge, Hcalory heater, Daly BMS control | |
| 3 | Phone companion relaying weather and the internet over BLE | |
| 4 | Multiple tablets syncing over BLE; ESPHome over BLE | |
| 5 | Automations, Le'Configurator, offline voice ("Hey, Gary") | |

## Licence

GPL-3.0-or-later with the App Store exception in `LICENSE-EXCEPTION`.
Third-party code and formats are listed in `NOTICE.md`. Contributions are
accepted under the same terms, see `CONTRIBUTING.md`.
