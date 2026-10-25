// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Every advertisement in aiobmsble's test data must match exactly the BMS
// type upstream matches it to, and the "ignore" ones none at all.
// Regenerate the vectors with tool/aiobmsble/record.sh.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/bms/bytes.dart';
import 'package:lecasa/bms/registry.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';

const _base = '-0000-1000-8000-00805f9b34fb';

RawAdvertisement _adv(Map<String, dynamic> v, {required bool withMac}) {
  var uuids = (v['service_uuids'] as List).cast<String>();
  // one upstream entry is a string, split into characters
  if (uuids.isNotEmpty && uuids.every((u) => u.length == 1)) {
    uuids = [uuids.join()];
  }
  final short = <int>[], long = <String>[];
  for (final u in uuids) {
    final l = u.toLowerCase();
    if (l.length == 36 && l.startsWith('0000') && l.endsWith(_base)) {
      short.add(int.parse(l.substring(4, 8), radix: 16));
    } else {
      long.add(l);
    }
  }
  return RawAdvertisement(
    id: v['mac'] as String,
    rssi: -60,
    seenAt: DateTime(2026),
    mac: withMac ? parseMac(v['mac'] as String) : null,
    name: v['name'] as String?,
    serviceUuids: short,
    longServiceUuids: long,
    serviceData: {
      for (final e in (v['service_data'] as Map).entries)
        if ((e.key as String).endsWith(_base))
          int.parse((e.key as String).substring(4, 8), radix: 16):
              Uint8List.fromList(fromHexStr(e.value as String)),
    },
    manufacturerData: {
      for (final e in (v['manufacturer_data'] as Map).entries)
        int.parse(e.key as String): fromHexStr(e.value as String),
    },
  );
}

void main() {
  final vectors = (jsonDecode(
    File('test/bms/vectors/_advertisements.json').readAsStringSync(),
  ) as List).cast<Map<String, dynamic>>();

  test('every upstream BMS has a driver', () {
    final types = {
      for (final v in vectors)
        if (v['kind'] == 'bms') v['type'],
    };
    for (final t in types) {
      expect(bmsSpecByModule(t as String), isNotNull, reason: t);
    }
    expect(bmsSpecs.length, 50);
  });

  test('advertisements match like upstream (Android, with MAC)', () {
    for (final v in vectors) {
      final got = [
        for (final s in bmsSpecs)
          if (s.supports(_adv(v, withMac: true))) s.module,
      ];
      expect(
        got,
        (v['matches'] as List).cast<String>(),
        reason: '${v['type']} ${v['name']}',
      );
    }
  });

  test('without a MAC (iOS) nothing matches the wrong type', () {
    final ouiOnly = <String>{};
    for (final v in vectors) {
      final want = (v['matches'] as List).cast<String>();
      final got = [
        for (final s in bmsSpecs)
          if (s.supports(_adv(v, withMac: false))) s.module,
      ];
      if (got.isEmpty && want.isNotEmpty) {
        ouiOnly.add(want.single);
      } else {
        expect(got, want, reason: '${v['type']} ${v['name']}');
      }
    }
    // These are recognised by MAC prefix only in some upstream samples.
    expect(ouiOnly, containsAll(<String>['ws_nova_bms', 'greenway_bms']));
  });
}
