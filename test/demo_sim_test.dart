// The ESP32 demo simulator (firmware/demo-sim) builds its adverts in C.
// firmware/demo-sim/host/gen_vectors.sh runs that C code on a laptop
// through every scene and saves the raw adverts with the values they
// should show; this test decodes them with the real registry, so the
// simulator and the app can't drift apart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';

/// Parses raw AD structures the way the phone's Bluetooth stack does.
RawAdvertisement parseAd(String id, List<Uint8List> packets) {
  final mfr = <int, Uint8List>{};
  final sd = <int, Uint8List>{};
  String? name;
  for (final p in packets) {
    var i = 0;
    while (i < p.length) {
      final len = p[i];
      if (len == 0 || i + 1 + len > p.length) break;
      final type = p[i + 1];
      final body = p.sublist(i + 2, i + 1 + len);
      switch (type) {
        case 0xFF:
          mfr[body[0] | body[1] << 8] = body.sublist(2);
        case 0x16:
          sd[body[0] | body[1] << 8] = body.sublist(2);
        case 0x08 || 0x09:
          name = utf8.decode(body);
      }
      i += 1 + len;
    }
  }
  return RawAdvertisement(
    id: id,
    rssi: -50,
    seenAt: DateTime.utc(2026, 11, 11),
    name: name,
    serviceData: sd,
    manufacturerData: mfr,
  );
}

/// Wire resolution of each reading, so rounding on the way out passes.
const tolerance = {
  'battery voltage': 0.0051,
  'battery current': 0.051,
  'yield today': 5.01,
  'solar power': 0.51,
  'state of charge': 0.051,
  'voltage': 0.0051,
  'current': 0.0011,
  'consumed': 0.051,
  'temperature': 0.0051,
  'humidity': 0.0051,
  'ac power': 0.51,
  'ac voltage': 0.0051,
  'ac current': 0.051,
};

void main() {
  final vectors =
      jsonDecode(File('test/vectors/demo_sim.json').readAsStringSync()) as List;

  test('vectors cover every simulated device in every scene', () {
    final names = {for (final v in vectors) v['name']};
    final scenes = {for (final v in vectors) v['scene']};
    expect(names, containsAll(['Roof Solar', 'House Battery', 'MultiPlus']));
    expect(names, containsAll(['Inverter', 'Cabin', 'Fridge']));
    expect(scenes.length, 6);
  });

  for (final (i, v) in vectors.indexed) {
    final m = v as Map<String, Object?>;
    test('${m['scene']} / ${m['name']}', () {
      final id = 'demo-$i';
      final key = m['key'] as String?;
      final registry = DecoderRegistry.standard(
        keyFor: (q) => q == id && key != null ? _hex(key) : null,
      );
      final adv = _hex(m['adv'] as String);
      expect(adv.length, lessThanOrEqualTo(31));
      final raw = parseAd(id, [adv, _hex(m['rsp'] as String)]);
      expect(raw.name, m['name']);

      final out = registry.decode(raw)!;
      expect(out.isReadable, isTrue, reason: out.needs);
      if (key != null) expect(out.keyCheck, KeyCheck.works);
      final got = {for (final r in out.readings) r.label: r.value};
      final want = m['expect'] as Map<String, Object?>;
      for (final MapEntry(:key, :value) in want.entries) {
        expect(got.containsKey(key), isTrue, reason: 'no "$key" in $got');
        final g = got[key];
        if (value is num && g is num) {
          expect(
            g.toDouble(),
            closeTo(value.toDouble(), tolerance[key] ?? 0.51),
            reason: key,
          );
        } else {
          expect(g, value, reason: key);
        }
      }
    });
  }
}

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i + 1 < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
