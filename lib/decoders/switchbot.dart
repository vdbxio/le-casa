// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// SwitchBot broadcasts. Every SwitchBot sends its state in the clear, so
// sensors, plugs and covers read with no account and no key. Layouts are
// ported from sblibs/pySwitchbot (MIT), switchbot/adv_parser.py and
// switchbot/adv_parsers/.
//
// A packet has service data on 0xFD3D (older units 0x0D00) whose first
// byte names the model, and manufacturer data under company 0x0969 (2409)
// that starts with the device's MAC. The Bot and the old Remote use
// company 0x0059 instead. Newer models put a 4-byte model id at the end of
// the service data rather than in its first byte.

import 'dart:typed_data';

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int switchBotServiceUuid = 0xFD3D;
const int switchBotOldServiceUuid = 0x0D00;
const int switchBotCompanyId = 0x0969;
const int switchBotHumidifierCompanyId = 0x02E5;
const int switchBotBotCompanyId = 0x0059;

typedef _Parse = List<Reading> Function(Uint8List? data, Uint8List? mfr);

class _Model {
  final String name;
  final DeviceKind kind;
  final _Parse parse;
  const _Model(this.name, this.kind, this.parse);
}

class SwitchBotDecoder implements Decoder {
  /// The model each device last named, by device id. A passive scan can
  /// miss the service data (it rides in the scan response on some units),
  /// leaving only manufacturer data that does not say what it is.
  final Map<String, String> _modelOf = {};

  SwitchBotDecoder();

  @override
  String get name => 'SwitchBot';

  @override
  bool matches(RawAdvertisement adv) =>
      adv.serviceData.containsKey(switchBotServiceUuid) ||
      adv.serviceData.containsKey(switchBotOldServiceUuid) ||
      (adv.manufacturerData.containsKey(switchBotCompanyId) &&
          _modelOf.containsKey(adv.id));

  @override
  Decoded? decode(RawAdvertisement adv) {
    final data =
        adv.serviceData[switchBotServiceUuid] ??
        adv.serviceData[switchBotOldServiceUuid];
    Uint8List? mfr;
    for (final id in const [
      switchBotCompanyId,
      switchBotHumidifierCompanyId,
      switchBotBotCompanyId,
    ]) {
      mfr = adv.manufacturerData[id];
      if (mfr != null) break;
    }
    final key = (data == null ? null : _modelKey(data)) ?? _modelOf[adv.id];
    if (key == null) return null;
    _modelOf[adv.id] = key;
    final model = _models[key];
    if (model == null) return null;
    final encrypted = data != null && data.isNotEmpty && data[0] & 0x80 != 0;
    final info = <String, String>{
      // Manufacturer data starts with the MAC: the only way iOS learns it.
      if (mfr != null &&
          mfr.length >= 6 &&
          adv.manufacturerData.containsKey(switchBotCompanyId))
        'mac': hex(mfr.sublist(0, 6), sep: ':').toUpperCase(),
      if (encrypted) 'encrypted': 'yes',
    };
    final readings = model.parse(data, mfr);
    return Decoded(
      protocol: 'SwitchBot',
      kind: model.kind,
      model: 'SwitchBot ${model.name}',
      readings: readings,
      info: info,
    );
  }

  static String? _modelKey(Uint8List data) {
    if (data.isEmpty) return null;
    // The first byte, as a letter ('T' Meter) or with the encryption bit
    // masked off (0x14 Meter Pro).
    final byte = String.fromCharCode(data[0]);
    if (_models.containsKey(byte)) return byte;
    final masked = String.fromCharCode(data[0] & 0x7F);
    if (_models.containsKey(masked)) return masked;
    // Newer models: a 4-byte id at the end (or one byte before the end).
    if (data.length > 5) {
      for (final end in [data.length, data.length - 1]) {
        final id = hex(data.sublist(end - 4, end), sep: '');
        if (_models.containsKey(id)) return id;
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------- parsers

int _battery(Uint8List? data) => data![2] & 0x7F;

/// Temperature (°C) and humidity from SwitchBot's 3-byte layout: decimal in
/// the low nibble of byte 0, sign and whole degrees in byte 1, humidity in
/// byte 2 (its top bit is the °F display flag).
List<Reading>? _tempHumidity(List<int> t) {
  final sign = t[1] & 0x80 != 0 ? 1 : -1;
  final c = sign * ((t[1] & 0x7F) + (t[0] & 0x0F) / 10);
  final h = t[2] & 0x7F;
  if (c == 0 && h == 0) return null;
  return [
    Reading('temperature', _round1(c), '°C'),
    Reading('humidity', h, '%'),
  ];
}

double _round1(num v) => (v * 10).round() / 10;

List<Reading> _meter(Uint8List? data, Uint8List? mfr) {
  List<int>? t;
  if (mfr != null && mfr.length >= 11) t = mfr.sublist(8, 11);
  if (t == null && data != null && data.length >= 6) t = data.sublist(3, 6);
  if (t == null) return const [];
  return [
    ...?_tempHumidity(t),
    if (data != null && data.length >= 3)
      Reading('battery', _battery(data), '%'),
  ];
}

List<Reading> _meterCo2(Uint8List? data, Uint8List? mfr) {
  final out = _meter(data, mfr);
  if (out.isNotEmpty && mfr != null && mfr.length >= 15) {
    final co2 = (mfr[13] << 8) | mfr[14];
    // The sensor's range ends at 9999 ppm; more is a parsing artefact.
    if (co2 <= 9999) return [...out, Reading('co2', co2, 'ppm')];
  }
  return out;
}

List<Reading> _weatherStation(Uint8List? data, Uint8List? mfr) {
  List<int>? t;
  int? battery;
  if (mfr != null && mfr.length >= 11) {
    t = mfr.sublist(8, 11);
    battery = mfr[7] & 0x7F;
  }
  if (data != null && data.length >= 6) {
    t ??= data.sublist(3, 6);
    battery ??= _battery(data);
  }
  if (t == null) return const [];
  return [
    ...?_tempHumidity(t),
    if (battery != null) Reading('battery', battery, '%'),
  ];
}

const _hub2Lux = [
  0, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 105, 205, 317, 416, 510, 610, //
  707, 801, 897, 1023, 1091,
];

List<Reading> _hub2(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 16) return const [];
  final level = mfr[12] & 0x1F;
  final th = _tempHumidity(mfr.sublist(13, 16));
  if (th == null) return const [];
  return [
    ...th,
    Reading('illuminance', level == 0 ? 0 : _hub2Lux[level.clamp(0, 21)], 'lx'),
  ];
}

const _hub3Lux = [0, 0, 50, 90, 205, 317, 510, 610, 707, 801, 1023];

List<Reading> _hub3(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 17) return const [];
  final d = mfr.sublist(6);
  final level = (d[6] & 0x0F).clamp(0, 10);
  return [
    ...?_tempHumidity(d.sublist(7, 10)),
    Reading('illuminance', _hub3Lux[level], 'lx'),
    Reading('motion', d[10] & 0x80 != 0),
  ];
}

List<Reading> _contact(Uint8List? data, Uint8List? mfr) {
  final fullMfr = mfr != null && mfr.length >= 13;
  final fullData = data != null && data.length >= 9;
  if (!fullMfr && !fullData) return const [];
  final bool motion, open, timeout, light;
  final int buttons;
  if (fullMfr) {
    motion = mfr[7] & 0x80 != 0;
    open = mfr[7] & 0x10 != 0;
    timeout = mfr[7] & 0x20 != 0;
    light = mfr[7] & 0x40 != 0;
    buttons = mfr[12] & 0x0F;
  } else {
    motion = data![1] & 0x40 != 0;
    open = data[3] & 0x02 != 0;
    timeout = data[3] & 0x04 != 0;
    light = data[3] & 0x01 != 0;
    buttons = data[8] & 0x0F;
  }
  return [
    // Left open past its timeout still means open.
    Reading('open', open || timeout),
    Reading('motion', motion),
    Reading('light', light),
    Reading('button presses', buttons),
    if (data != null && data.length >= 3)
      Reading('battery', _battery(data), '%'),
  ];
}

List<Reading> _motion(Uint8List? data, Uint8List? mfr) {
  bool? motion, light;
  int? battery;
  if (data != null && data.length >= 6) {
    motion = data[1] & 0x40 != 0;
    battery = _battery(data);
    light = data[5] & 0x02 != 0;
  }
  if (mfr != null && mfr.length >= 8) {
    motion = mfr[7] & 0x40 != 0;
    light = mfr[7] & 0x20 != 0;
  }
  return [
    if (motion != null) Reading('motion', motion),
    if (light != null) Reading('light', light),
    if (battery != null) Reading('battery', battery, '%'),
  ];
}

List<Reading> _presence(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 12) return const [];
  return [
    Reading('motion', mfr[7] & 0x40 != 0),
    Reading('light level', mfr[11] & 0x1F),
    if (data != null && data.length >= 3)
      Reading('battery', _battery(data), '%'),
  ];
}

List<Reading> _leak(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 9) return const [];
  return [
    Reading('leak', mfr[8] & 0x01 != 0),
    Reading('tampered', mfr[8] & 0x02 != 0),
    Reading('battery', mfr[7] & 0x7F, '%'),
  ];
}

int _u16be(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

List<Reading> _plugMini(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 12) return const [];
  return [
    Reading('on', mfr[7] == 0x80),
    Reading('power', (_u16be(mfr, 10) & 0x7FFF) / 10, 'W'),
    Reading('wifi signal', -mfr[9], 'dBm'),
  ];
}

List<Reading> _relay(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 8) return const [];
  return [Reading('on', mfr[7] & 0x80 != 0)];
}

List<Reading> _relayPm(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 12) return _relay(data, mfr);
  return [..._relay(data, mfr), Reading('power', _u16be(mfr, 10) / 1, 'W')];
}

List<Reading> _relay2pm(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 14) return const [];
  return [
    Reading('on', mfr[7] & 0x80 != 0),
    Reading('power', _u16be(mfr, 10) / 1, 'W'),
    Reading('on 2', mfr[7] & 0x40 != 0),
    Reading('power 2', _u16be(mfr, 12) / 1, 'W'),
  ];
}

List<Reading> _bot(Uint8List? data, Uint8List? mfr) {
  if (data == null || data.length < 3) return const [];
  final switchMode = data[1] & 0x80 != 0;
  return [
    Reading('mode', switchMode ? 'Switch' : 'Press'),
    if (switchMode) Reading('on', data[1] & 0x40 == 0),
    Reading('battery', _battery(data), '%'),
  ];
}

List<Reading> _batteryOnly(Uint8List? data, Uint8List? mfr) => [
  if (data != null && data.length >= 3) Reading('battery', _battery(data), '%'),
];

List<Reading> _universalRemote(Uint8List? data, Uint8List? mfr) => [
  if (mfr != null && mfr.length >= 8) ...[
    Reading('battery', mfr[7] & 0x7F, '%'),
    Reading('charging', mfr[7] & 0x80 != 0),
  ],
];

List<Reading> _cover(Uint8List? data, Uint8List? mfr, {bool reverse = true}) {
  List<int> d;
  int? battery;
  if (mfr != null && mfr.length >= 13) {
    d = mfr.sublist(8, 11);
    battery = mfr[12];
  } else if (mfr != null && mfr.length >= 11) {
    d = mfr.sublist(8, 11);
    battery = data != null && data.length >= 3 ? data[2] : null;
  } else if (data != null && data.length >= 6) {
    d = data.sublist(3, 6);
    battery = data[2];
  } else {
    return const [];
  }
  final pos = (d[0] & 0x7F).clamp(0, 100);
  return [
    // SwitchBot counts closed as 100; Le'Casa says how open it is.
    Reading('position', reverse ? 100 - pos : pos, '%'),
    Reading('moving', d[0] & 0x80 != 0),
    if (battery != null) Reading('battery', battery & 0x7F, '%'),
  ];
}

List<Reading> _curtain(Uint8List? data, Uint8List? mfr) => _cover(data, mfr);

List<Reading> _blindTilt(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 11) return const [];
  return [
    Reading('tilt', (mfr[8] & 0x7F).clamp(0, 100), '%'),
    Reading('moving', mfr[8] & 0x80 != 0),
    if (data != null && data.length >= 3)
      Reading('battery', _battery(data), '%'),
  ];
}

List<Reading> _lock(Uint8List? data, Uint8List? mfr) {
  if (mfr == null || mfr.length < 9) return _batteryOnly(data, mfr);
  final status = (mfr[7] >> 4) & 0x07;
  return [
    Reading('lock', switch (status) {
      0 => 'Locked',
      1 => 'Unlocked',
      2 => 'Locking',
      3 => 'Unlocking',
      4 => 'Locking blocked',
      5 => 'Unlocking blocked',
      6 => 'Not fully locked',
      7 => 'Half locked',
      _ => 'Unknown',
    }),
    Reading('door open', mfr[7] & 0x04 != 0),
    ..._batteryOnly(data, mfr),
  ];
}

const _meterKind = DeviceKind.climate;

const _models = <String, _Model>{
  // Thermo-hygrometers.
  'T': _Model('Meter', _meterKind, _meter),
  't': _Model('Meter', _meterKind, _meter),
  'i': _Model('Meter Plus', _meterKind, _meter),
  'I': _Model('Meter Plus', _meterKind, _meter),
  'w': _Model('Indoor/Outdoor Meter', _meterKind, _meter),
  'W': _Model('Indoor/Outdoor Meter', _meterKind, _meter),
  '4': _Model('Meter Pro', _meterKind, _meter),
  '\x14': _Model('Meter Pro', _meterKind, _meter),
  '5': _Model('Meter Pro CO2', _meterKind, _meterCo2),
  '\x15': _Model('Meter Pro CO2', _meterKind, _meterCo2),
  '001053b0': _Model('Weather Station', _meterKind, _weatherStation),
  '011053b0': _Model('Weather Station', _meterKind, _weatherStation),
  'v': _Model('Hub 2', _meterKind, _hub2),
  'V': _Model('Hub 2', _meterKind, _hub2),
  '0010b940': _Model('Hub 3', _meterKind, _hub3),
  '0110b940': _Model('Hub 3', _meterKind, _hub3),
  // Doors, motion, water.
  'd': _Model('Contact Sensor', DeviceKind.security, _contact),
  'D': _Model('Contact Sensor', DeviceKind.security, _contact),
  's': _Model('Motion Sensor', DeviceKind.security, _motion),
  'S': _Model('Motion Sensor', DeviceKind.security, _motion),
  '0010ccc8': _Model('Presence Sensor', DeviceKind.security, _presence),
  '0110ccc8': _Model('Presence Sensor', DeviceKind.security, _presence),
  '&': _Model('Water Leak Detector', DeviceKind.security, _leak),
  '\x06': _Model('Water Leak Detector', DeviceKind.security, _leak),
  // Plugs and relays.
  'g': _Model('Plug Mini (US)', DeviceKind.switches, _plugMini),
  'G': _Model('Plug Mini (US)', DeviceKind.switches, _plugMini),
  'j': _Model('Plug Mini (JP)', DeviceKind.switches, _plugMini),
  'J': _Model('Plug Mini (JP)', DeviceKind.switches, _plugMini),
  '?': _Model('Plug Mini (EU)', DeviceKind.switches, _relayPm),
  '\x1f': _Model('Plug Mini (EU)', DeviceKind.switches, _relayPm),
  ';': _Model('Relay Switch 1', DeviceKind.switches, _relay),
  '\x1b': _Model('Relay Switch 1', DeviceKind.switches, _relay),
  '<': _Model('Relay Switch 1PM', DeviceKind.switches, _relayPm),
  '\x1c': _Model('Relay Switch 1PM', DeviceKind.switches, _relayPm),
  '=': _Model('Relay Switch 2PM', DeviceKind.switches, _relay2pm),
  '\x1d': _Model('Relay Switch 2PM', DeviceKind.switches, _relay2pm),
  'H': _Model('Bot', DeviceKind.switches, _bot),
  // Covers.
  'c': _Model('Curtain', DeviceKind.covers, _curtain),
  'C': _Model('Curtain', DeviceKind.covers, _curtain),
  '{': _Model('Curtain 3', DeviceKind.covers, _curtain),
  '[': _Model('Curtain 3', DeviceKind.covers, _curtain),
  ',': _Model('Roller Shade', DeviceKind.covers, _curtain),
  '\x0c': _Model('Roller Shade', DeviceKind.covers, _curtain),
  'x': _Model('Blind Tilt', DeviceKind.covers, _blindTilt),
  'X': _Model('Blind Tilt', DeviceKind.covers, _blindTilt),
  // Remotes and locks.
  'b': _Model('Remote', DeviceKind.buttons, _batteryOnly),
  'B': _Model('Remote', DeviceKind.buttons, _batteryOnly),
  '\x07': _Model('Universal Remote', DeviceKind.buttons, _universalRemote),
  "'": _Model('Universal Remote', DeviceKind.buttons, _universalRemote),
  'o': _Model('Lock', DeviceKind.security, _lock),
  'O': _Model('Lock', DeviceKind.security, _lock),
};
