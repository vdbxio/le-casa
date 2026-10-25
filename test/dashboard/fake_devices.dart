import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/decoder.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';

import '../helpers.dart';

/// Returns a preset [Decoded] for each known device id.
class FakeDecoder implements Decoder {
  final Map<String, Decoded> byId;
  FakeDecoder(this.byId);

  @override
  String get name => 'fake';

  @override
  bool matches(RawAdvertisement adv) => byId.containsKey(adv.id);

  @override
  Decoded? decode(RawAdvertisement adv) => byId[adv.id];
}

Decoded mppt(double w, {double a = 15.4, int wh = 1840}) => Decoded(
  protocol: 'Victron',
  kind: DeviceKind.solar,
  model: 'SmartSolar Charger MPPT 100/50',
  readings: [
    const Reading('charge state', 'bulk'),
    const Reading('charger error', 'none'),
    const Reading('battery voltage', 26.62, 'V'),
    Reading('battery current', a, 'A'),
    Reading('yield today', wh, 'Wh'),
    Reading('solar power', w, 'W'),
  ],
);

const shunt = Decoded(
  protocol: 'Victron',
  kind: DeviceKind.battery,
  model: 'SmartShunt 500A/50mV',
  readings: [
    Reading('state of charge', 87.4, '%'),
    Reading('voltage', 26.58, 'V'),
    Reading('current', 18.2, 'A'),
    Reading('consumed', -38.1, 'Ah'),
    Reading('time to go', 1440, 'min'),
    Reading('alarm', 'none'),
  ],
);

const daly = Decoded(
  protocol: 'Daly BMS',
  kind: DeviceKind.battery,
  model: 'Daly smart BMS · 8S',
  readings: [
    Reading('state of charge', 88.0, '%'),
    Reading('voltage', 26.5, 'V'),
    Reading('current', 17.9, 'A'),
    Reading('state', 'charging'),
    Reading('remaining', 271.9, 'Ah'),
    Reading('temperature', 19, '°C'),
    Reading('cell spread', 7, 'mV'),
  ],
);

Decoded climate(double t, int h) => Decoded(
  protocol: 'Xiaomi (connected)',
  kind: DeviceKind.climate,
  model: 'Xiaomi LYWSD03MMC',
  readings: [
    Reading('temperature', t, '°C'),
    Reading('humidity', h, '%'),
    const Reading('battery', 82, '%'),
  ],
);

const heater = Decoded(
  protocol: 'Hcalory',
  kind: DeviceKind.appliance,
  model: 'Hcalory diesel heater',
  needs: 'Needs a connection to read or control.',
  info: {'module': 'BYD-DC32622B4821'},
);

const fob = Decoded(
  protocol: 'BTHome',
  kind: DeviceKind.leDevice,
  model: "Le'Fob",
  readings: [Reading('battery', 93, '%')],
);

/// A tracker that has heard Chloe's gear.
DeviceTracker chloesGear() {
  final byId = <String, Decoded>{
    'luna': mppt(412),
    'sol': mppt(236, a: 8.8, wh: 1020),
    'lilith': shunt,
    'D2:19:08:01:C5:61': daly,
    'A4:C1:38:50:6E:3A': climate(21.4, 46),
    'A4:C1:38:F9:A5:12': climate(18.9, 52),
    'A4:C1:38:DF:07:81': climate(9.6, 71),
    'heater': heater,
    'fob': fob,
  };
  final names = {
    'luna': 'Luna 50',
    'sol': 'Sol 30',
    'lilith': 'Lilith',
    'D2:19:08:01:C5:61': 'DL-694201312BA',
    'A4:C1:38:50:6E:3A': 'LYWSD03MMC',
    'A4:C1:38:F9:A5:12': 'LYWSD03MMC',
    'A4:C1:38:DF:07:81': 'LYWSD03MMC',
    'heater': 'BYD-DC32622B4821',
    'fob': 'le-fob',
  };
  final t = DeviceTracker(DecoderRegistry([FakeDecoder(byId)]));
  for (final id in byId.keys) {
    t.onAdvertisement(
      adv(id: id, mac: null, name: names[id], seenAt: DateTime.now()),
    );
  }
  return t;
}
