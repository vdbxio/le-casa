// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Govee broadcasts: thermo-hygrometers, the H5140 CO2 meter, the H5106 air
// quality monitor, BBQ probe thermometers and the H512x motion, door,
// vibration and button sensors. Nothing needs an account: the H512x
// packets are scrambled with a key that rides in the packet itself.
// Ported from Bluetooth-Devices/govee-ble (Apache-2.0),
// src/govee_ble/parser.py, which in turn came from Ernst79/bleparser (MIT).
//
// Govee picks the manufacturer data "company id" per model (0xEC88 for the
// classic thermometers, 0x0001 for the H5100 family, random-looking values
// for the probes), so a packet is told apart by its length plus the model
// number in its name. iOS keeps names, so this works there too.

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int goveeCompanyId = 0xEC88;
const int _appleCompanyId = 0x004C;

final _goveeName = RegExp(r'^(Govee_|GV|ihoment_|B5178|H5\d{3})');

class GoveeDecoder implements Decoder {
  /// Some models send one packet per sensor or probe pair (H5178 indoor
  /// then outdoor, H5184 probes 1-2 then 3-4); the latest of each reading,
  /// by device id.
  final Map<String, Map<String, Reading>> _last = {};

  GoveeDecoder();

  @override
  String get name => 'Govee';

  @override
  bool matches(RawAdvertisement adv) {
    if (adv.manufacturerData.isEmpty) return false;
    final n = adv.name ?? '';
    return _goveeName.hasMatch(n) ||
        adv.manufacturerData.containsKey(goveeCompanyId) ||
        adv.serviceUuids.contains(goveeCompanyId) ||
        adv.serviceUuids.any(_probeUuids.contains) ||
        adv.serviceUuids.contains(_h5055Uuid);
  }

  @override
  Decoded? decode(RawAdvertisement adv) {
    for (final e in adv.manufacturerData.entries) {
      if (e.key == _appleCompanyId) continue;
      final out = decodeGovee(adv, e.key, e.value);
      if (out == null) continue;
      final last = _last.putIfAbsent(adv.id, () => {});
      for (final r in out.readings) {
        last[r.label] = r;
      }
      return Decoded(
        protocol: out.protocol,
        kind: out.kind,
        model: out.model,
        readings: last.values.toList(),
        events: out.events,
        info: out.info,
      );
    }
    return null;
  }
}

// Service UUIDs the probe thermometers list (0000xx51-...).
const _probeUuids = {0x8151, 0x8251, 0x8351, 0x8451, 0x8551, 0x9151, 0x9851};
const _h5055Uuid = 0x5550;

class _Out {
  final String model;
  final DeviceKind kind;
  final List<Reading> readings;
  final List<DeviceEvent> events;
  final Map<String, String> info;
  _Out(
    this.model,
    this.kind,
    this.readings, [
    this.events = const [],
    this.info = const {},
  ]);
}

/// One manufacturer data entry, or null when it is not a Govee packet.
Decoded? decodeGovee(RawAdvertisement adv, int companyId, Uint8List data) {
  final out = _parse(adv, companyId, data);
  if (out == null) return null;
  return Decoded(
    protocol: 'Govee',
    kind: out.kind,
    model: 'Govee ${out.model}',
    readings: out.readings,
    events: out.events,
    info: out.info,
  );
}

const _minTemp = -40, _maxTemp = 100;

/// Temperature and humidity packed as one decimal number: 25.3 °C at
/// 45.6 % is 253456. The top bit marks a negative temperature.
(double, double) _packedTempHumidity(List<int> b) {
  final base = (b[0] << 16) | (b[1] << 8) | b[2];
  final value = base & 0x7FFFFF;
  var temp = (value ~/ 1000) / 10;
  if (base & 0x800000 != 0) temp = -temp;
  final humidity = (value % 1000) / 10;
  return (temp, humidity);
}

/// [b] is 3 bytes of packed temperature/humidity and a battery byte whose
/// top bit flags a sensor error.
List<Reading> _climate(List<int> b, {bool battery = true}) {
  final (t, h) = _packedTempHumidity(b);
  final err = b[3] & 0x80 != 0;
  final ok = !err && t >= _minTemp && t <= _maxTemp;
  return [
    Reading('temperature', ok ? t : null, '°C'),
    Reading('humidity', ok ? h : null, '%'),
    if (battery) Reading('battery', b[3] & 0x7F, '%'),
  ];
}

int _i16le(Uint8List d, int i) =>
    ByteData.sublistView(d).getInt16(i, Endian.little);
int _u16le(Uint8List d, int i) =>
    ByteData.sublistView(d).getUint16(i, Endian.little);
int _i16be(Uint8List d, int i) =>
    ByteData.sublistView(d).getInt16(i, Endian.big);
int _u16be(Uint8List d, int i) =>
    ByteData.sublistView(d).getUint16(i, Endian.big);

/// Probe temperatures are hundredths of a degree; a negative value means no
/// probe is plugged in.
double? _probe(int v) => v < 0 ? null : v / 100;

List<Reading> _probeReadings(int n, int temp, int alarm, [int? lowAlarm]) => [
  Reading('probe $n', _probe(temp), '°C'),
  Reading('probe $n alarm', _probe(alarm), '°C'),
  if (lowAlarm != null) Reading('probe $n low alarm', _probe(lowAlarm), '°C'),
];

const _fourProbes = {
  1: [1, 2], 65: [1, 2], 129: [1, 2], 193: [1, 2], //
  2: [3, 4], 66: [3, 4], 130: [3, 4], 194: [3, 4],
};

_Out? _parse(RawAdvertisement adv, int mgrId, Uint8List data) {
  final name = adv.name ?? '';
  bool has(String s) => name.contains(s);
  var d = data;
  // Govee's iBeacon tail sometimes ends up glued to the packet.
  if (d.length > 25 && _contains(d, 'INTELLI_ROCKS'.codeUnits)) {
    d = Uint8List.sublistView(d, 0, d.length - 25);
  }
  final len = d.length;

  if (len == 24) return _h512x(name, d);

  // H5127 presence sensor. 0x8803/0x8843 are not company ids: Govee puts
  // a flags byte straight after the 0xFF type byte.
  if (len == 6 &&
      d[0] == 0xEC &&
      d[1] == 0x00 &&
      (d[2] == 0x01 || d[2] == 0x02) &&
      d[3] == 0x01 &&
      (has('H5127') || mgrId == 0x8803 || mgrId == 0x8843)) {
    return _Out('H5127 Presence Sensor', DeviceKind.security, [
      Reading('occupied', d[4] == 1),
      Reading('motion', d[5] == 17),
    ]);
  }

  if (len == 6 &&
      (has('H5072') ||
          has('H5075') ||
          has('H5129') ||
          mgrId == goveeCompanyId)) {
    final model = has('H5072')
        ? 'H5072'
        : has('H5075')
        ? 'H5075'
        : has('H5129')
        ? 'H5129'
        : 'H5072/H5075';
    return _Out(model, DeviceKind.climate, _climate(d.sublist(1, 5)));
  }

  if (len == 8 && (has('GV5112') || has('H5112'))) {
    final probe = switch (d[7]) {
      0x41 => 1,
      0x82 => 2,
      _ => 0,
    };
    if (probe == 0) return null;
    final c = _climate(d.sublist(2, 6));
    return _Out('H5112', DeviceKind.climate, [
      Reading('temperature${probe == 1 ? '' : ' $probe'}', c[0].value, '°C'),
      if (probe == 1) c[1],
      c[2],
    ]);
  }

  if (len == 8 && has('5140')) {
    final (t, h) = _packedTempHumidity(d.sublist(2, 5));
    final co2 = _u16be(d, 5);
    final ok = d[7] == 0 && t >= _minTemp && t <= _maxTemp;
    return _Out('H5140 CO2 Monitor', DeviceKind.climate, [
      Reading('temperature', ok ? t : null, '°C'),
      Reading('humidity', ok ? h : null, '%'),
      Reading('co2', ok ? co2 : null, 'ppm'),
    ]);
  }

  const h510x = [
    'H5108', 'H5100', 'H5101', 'H5102', 'H5103', 'H5104', 'H5105', //
    'H5174', 'H5177', 'H5110', 'GV5179',
  ];
  final named510x = h510x.where(has).firstOrNull;
  if ((len == 6 || len == 8) &&
      (named510x != null || (mgrId == 0x0001 && len == 8))) {
    final model = named510x == 'H5108' || len == 8
        ? 'H5108'
        : named510x ?? 'H5101/H5102/H5104/H5108/H5174/H5177/GV5179';
    return _Out(model, DeviceKind.climate, _climate(d.sublist(2, 6)));
  }

  if (len == 7 && (has('H5074') || mgrId == goveeCompanyId)) {
    return _Out('H5074', DeviceKind.climate, _leClimate(d, 1));
  }

  if (len == 9 &&
      (mgrId == goveeCompanyId ||
          has('H5051') ||
          has('H5052') ||
          has('H5071'))) {
    final model = has('H5071')
        ? 'H5071'
        : has('H5052')
        ? 'H5052'
        : 'H5051';
    return _Out(model, DeviceKind.climate, _leClimate(d, 1));
  }

  if (len == 9 && (has('H5178') || has('B5178') || mgrId == 0x0001)) {
    // One packet per sensor: 0 the indoor unit, 1 the outdoor one.
    final remote = d[2] == 1;
    final c = _climate(d.sublist(3, 7));
    String l(String base) => remote ? 'outdoor $base' : base;
    return _Out('H5178', DeviceKind.climate, [
      Reading(l('temperature'), c[0].value, '°C'),
      Reading(l('humidity'), c[1].value, '%'),
      Reading(l('battery'), c[2].value, '%'),
    ]);
  }

  if (len == 9 && (has('H5179') || mgrId == 0x8801)) {
    return _Out('H5179', DeviceKind.climate, _leClimate(d, 4));
  }

  bool probeModel(String model, Set<int> ids, int uuid) =>
      has(model) || ids.contains(mgrId) || adv.serviceUuids.contains(uuid);
  const probes = DeviceKind.sensor;

  if (len == 14 &&
      probeModel('H5181', {0xF861, 0x388A, 0xEA42, 0xAAA2, 0xD14B}, 0x8151)) {
    return _Out(
      'H5181 Meat Thermometer',
      probes,
      _probeReadings(1, _i16be(d, 8), _i16be(d, 10)),
    );
  }
  if (len == 17 && probeModel('H5182', {0x2730}, 0x8251)) {
    return _Out('H5182 Meat Thermometer', probes, [
      ..._probeReadings(1, _i16be(d, 8), _i16be(d, 10)),
      ..._probeReadings(2, _i16be(d, 13), _i16be(d, 15)),
    ]);
  }
  if (len == 14 && probeModel('H5183', {0x67DD, 0xE02F, 0xF79F}, 0x8351)) {
    return _Out(
      'H5183 Meat Thermometer',
      probes,
      _probeReadings(1, _i16be(d, 8), _i16be(d, 10)),
    );
  }
  if (len == 17 && probeModel('H5184', {0x1B36}, 0x8451)) {
    final ids = _fourProbes[d[6]];
    if (ids == null) return null;
    return _Out('H5184 Meat Thermometer', probes, [
      ..._probeReadings(ids[0], _i16be(d, 8), _i16be(d, 10)),
      ..._probeReadings(ids[1], _i16be(d, 13), _i16be(d, 15)),
    ]);
  }
  if (len == 20 && probeModel('H5185', {0x4A32, 0x332, 0x4C32}, 0x8551)) {
    return _Out('H5185 Meat Thermometer', probes, [
      ..._probeReadings(1, _i16be(d, 8), _i16be(d, 10)),
      ..._probeReadings(2, _i16be(d, 14), _i16be(d, 16)),
    ]);
  }
  if (len == 20 && probeModel('H5191', {0xAC63}, 0x9151)) {
    return _Out('H5191 Meat Thermometer', probes, [
      ..._probeReadings(1, _i16be(d, 8), _i16be(d, 10)),
      Reading('temperature', _i16be(d, 14) / 100, '°C'),
    ]);
  }
  if (len == 20 && probeModel('H5198', {0x3022}, 0x9851)) {
    final ids = _fourProbes[d[6]];
    if (ids == null) return null;
    return _Out('H5198 Meat Thermometer', probes, [
      ..._probeReadings(ids[0], _i16be(d, 8), _i16be(d, 10), _i16be(d, 12)),
      ..._probeReadings(ids[1], _i16be(d, 14), _i16be(d, 16), _i16be(d, 18)),
    ]);
  }
  if (len == 20 && adv.serviceUuids.contains(_h5055Uuid)) {
    return _h5055(d);
  }

  if (len == 6 && has('H5106')) {
    final v = (d[2] << 24) | (d[3] << 16) | (d[4] << 8) | d[5];
    final m = v & 0x7FFFFFFF;
    var t = (m ~/ 1000000) / 10;
    if (v & 0x80000000 != 0) t = -t;
    return _Out('H5106 Air Quality Monitor', DeviceKind.climate, [
      Reading('temperature', t, '°C'),
      Reading('humidity', ((m % 1000000) ~/ 1000) / 10, '%'),
      Reading('pm2.5', m % 1000, 'µg/m³'),
    ]);
  }
  return null;
}

/// Little-endian int16 hundredths of a degree, uint16 hundredths of a
/// percent, battery byte.
List<Reading> _leClimate(Uint8List d, int i) => [
  Reading('temperature', _i16le(d, i) / 100, '°C'),
  Reading('humidity', _u16le(d, i + 2) / 100, '%'),
  Reading('battery', d[i + 4], '%'),
];

_Out? _h5055(Uint8List d) {
  final ids = d[3];
  final pids = switch (ids & 0xC0) {
    0 => [(1, 0x01), (2, 0x02)],
    64 => [(3, 0x04), (4, 0x08)],
    128 => [(5, 0x10), (6, 0x20)],
    _ => null,
  };
  if (pids == null) return null;
  // Whole degrees; -1 (0xFFFF) means no alarm set.
  double? deg(int v) => v < 0 ? null : v.toDouble();
  final out = <Reading>[];
  for (final (n, (probe, bit)) in pids.indexed) {
    if (ids & bit == 0) continue;
    final at = 5 + n * 7;
    out
      ..add(Reading('probe $probe', _i16le(d, at).toDouble(), '°C'))
      ..add(Reading('probe $probe alarm', deg(_i16le(d, at + 4)), '°C'))
      ..add(Reading('probe $probe low alarm', deg(_i16le(d, at + 2)), '°C'));
  }
  out.add(Reading('battery', d[2] & 0x7F, '%'));
  return _Out('H5055 Meat Thermometer', DeviceKind.sensor, out);
}

/// The H512x sensors: 16 bytes AES-ECB, keyed with the 4 bytes before them
/// plus 12 zeros, checked with a CRC-16/CCITT.
_Out? _h512x(String name, Uint8List d) {
  final enc = d.sublist(6, 22);
  if (goveeCrc(enc) != _u16be(d, 22)) return null;
  final key = Uint8List(16)..setRange(0, 4, d.sublist(2, 6));
  final p = goveeDecrypt(key, enc);
  final id = p[2];
  bool is_(String n, int code) => name.contains(n) || id == code;
  final battery = Reading('battery', p[4], '%');
  final state = p[5];
  // The key bytes change with each new event; repeats of one event share
  // them.
  final info = {'packet id': hex(d.sublist(2, 6), sep: '')};
  _Out out(
    String model,
    DeviceKind kind,
    List<Reading> readings, [
    List<DeviceEvent> events = const [],
  ]) => _Out(model, kind, readings, events, info);
  if (is_('GV5121', 3)) {
    return out(
      'H5121 Motion Sensor',
      DeviceKind.security,
      [battery],
      [if (state == 1) const DeviceEvent('motion', 'motion')],
    );
  }
  _Out button(String model) => out(
    model,
    DeviceKind.buttons,
    [battery],
    [DeviceEvent('button $state', 'press')],
  );
  if (is_('GV5122', 8)) return button('H5122 Button');
  if (is_('GV5123', 2)) {
    return out('H5123 Door Sensor', DeviceKind.security, [
      Reading('open', state == 2),
      battery,
    ]);
  }
  if (is_('GV5124', 9)) {
    return out(
      'H5124 Vibration Sensor',
      DeviceKind.security,
      [battery],
      [if (state == 1) const DeviceEvent('vibration', 'vibration')],
    );
  }
  if (is_('GV5125', 10)) return button('H5125 Six-Button Remote');
  if (is_('GV5126', 11)) return button('H5126 Two-Button Remote');
  if (is_('GV5130', 13)) {
    // A bitfield: 0x01 pressure on the pad, 0x10 its button pressed.
    return out(
      'H5130 Pressure Sensor',
      DeviceKind.security,
      [if (state != 0x10) Reading('pressed', state & 0x01 != 0), battery],
      [if (state & 0x10 != 0) const DeviceEvent('button 0', 'press')],
    );
  }
  return null;
}

/// CRC-16/CCITT-FALSE as the H512x sensors use it.
int goveeCrc(List<int> data) {
  var crc = 0x1D0F;
  for (final b in data) {
    for (var s = 7; s >= 0; s--) {
      final mask = ((crc >> 15) ^ ((b >> s) & 1)) != 0 ? 0x1021 : 0;
      crc = ((crc << 1) ^ mask) & 0xFFFF;
    }
  }
  return crc;
}

/// AES-ECB with key and block both byte-reversed, as Govee does it.
Uint8List goveeDecrypt(Uint8List key, Uint8List block) {
  final aes = AESEngine()
    ..init(false, KeyParameter(Uint8List.fromList(key.reversed.toList())));
  final out = Uint8List(16);
  aes.processBlock(Uint8List.fromList(block.reversed.toList()), 0, out, 0);
  return Uint8List.fromList(out.reversed.toList());
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
