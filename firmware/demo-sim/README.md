# Le'Casa demo simulator

Firmware for any ESP32 that pretends to be a small bus power system, so
Le'Casa has live, moving numbers to show on a shop counter or a
conference table with no real gear around.

One board broadcasts six devices, all in the exact formats the real ones
use, so the app runs its normal decoders on them (nothing in the app is
special-cased for the demo):

| Card name      | Pretends to be                          | Format                  |
|----------------|-----------------------------------------|-------------------------|
| Roof Solar     | SmartSolar MPPT 100/50, 800 W of panels | Victron Instant Readout |
| Portable Solar | SmartSolar MPPT 100/30, 400 W of panels | Victron Instant Readout |
| House Battery  | SmartShunt 500A, 300 Ah 24 V LiFePO4    | Victron Instant Readout |
| MultiPlus      | MultiPlus-II 24/3000/70 120V            | Victron Instant Readout (VE.Bus) |
| Cabin          | temperature and humidity sensor         | BTHome v2               |
| Fridge         | fridge thermometer                      | BTHome v2               |

The numbers come from one small model of the whole system, so they agree
with each other: the shunt's current is the chargers' output minus the
loads, the chargers see the battery's voltage, the MultiPlus draws what
the AC loads need, and the battery fills and drains accordingly. A demo
day lasts 24 minutes by default: the sun comes up, clouds pass, the
kettle goes on now and then, the lights come on in the evening, and if
the battery gets low it "plugs into shore power" so a demo left running
all day never goes flat.

## Build and flash

Any ESP32 with Bluetooth LE works: ESP32, C3, S3, C6, H2. No wiring.

With ESP-IDF 5.x:

```sh
cd firmware/demo-sim
idf.py set-target esp32c3     # or esp32, esp32s3, esp32c6
idf.py build flash monitor
```

Or with PlatformIO (it comes with ESPHome):

```sh
cd firmware/demo-sim
pio run -e esp32-c3 -t upload -t monitor   # or esp32, esp32-s3, esp32-c6
```

## Set up Le'Casa (once per screen)

The Victron devices are encrypted like the real thing, so each needs its
key once. Open the device in Le'Casa and paste its key under "Encryption
key". Screens that are synced share the keys, so this is a one-time job.

| Device         | Key                                |
|----------------|------------------------------------|
| Roof Solar     | `7ac23cbd9701a2606511a8c35ff71231` |
| Portable Solar | `15cd25858a293c2a4e22e4449932af58` |
| House Battery  | `d9db30a2d6c1b4d61894fd7f37d447b2` |
| MultiPlus      | `2e34b264039aa3565d7eee05550e3cef` |

Cabin and Fridge are plain BTHome and show up with no setup. The board
also prints the keys and each device's address on the serial console at
boot (`keys` prints them again).

These keys are public. They only exist to unlock the simulator.

## Running a demo

Press the **BOOT** button to step through scenes:

| Scene    | What happens                                                    |
|----------|-----------------------------------------------------------------|
| auto     | follows the demo clock, passing clouds, random kettle/microwave |
| sunny    | clear noon, light loads: the battery fills, chargers go to float |
| cloudy   | heavy cloud, solar comes and goes                               |
| night    | no sun, evening loads: the battery drains, time-to-go appears   |
| big-load | 1.8 kW induction hob on the MultiPlus                           |
| shore    | plugged in at a campground: the MultiPlus charges at 40 A       |

Or type on the serial console (115200 baud):

- `scene night` (any scene name above)
- `kettle`: 1.5 kW for 20 seconds
- `soc 30`: set the battery's state of charge
- `day 10`: make a demo day last 10 minutes
- `status`, `keys`

The board prints a one-line status every 10 seconds.

## Changing the line-up

`main/devices.c` holds the table. Rename a card, change a model id (names
are in `lib/decoders/victron_models.dart`), drop a device, or uncomment
the Phoenix inverter. Panel sizes, battery size and the length of a demo
day are in `sim_defaults()` in `main/sim.c`.

## How it works

The ESP32 has one radio, so the board takes turns: every 120 ms it
switches to the next device, with that device's own random static
address and advert. Each device is heard a little more than once a
second, and each keeps the same address across reboots (it is derived
from the board's MAC), so Le'Casa keeps its name, key and dashboard
place.

`main/frames.c` builds the adverts and `main/sim.c` is the model. Both
are plain C with no ESP-IDF in them, so they also build on a laptop:
`host/gen_vectors.sh` runs them through every scene and writes
`test/vectors/demo_sim.json`, and `test/demo_sim_test.dart` decodes
every frame with Le'Casa's real decoders and checks the values. Rerun the
script after changing anything in `main/` (needs a C compiler and the
OpenSSL headers).

## Not simulated yet

- Devices Le'Casa has to connect to (Daly and the other BMSs, the
  Alpicool fridge, the Hcalory heater). They need a GATT server and a
  connectable advert, so they would get their own mode, or a second
  board.
- Encrypted BTHome (a Le'Fob look-alike).
