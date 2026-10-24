// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Apple Continuity adverts (manufacturer id 0x004C). Phones, AirPods,
// AirTags, Apple TVs and HomePods broadcast these constantly, with rotating
// addresses, and there is nothing Le'Casa can read from them. They are
// recognised so they can be parked in a collapsed group instead of
// filling the unknown list. Layouts from the public Continuity write-ups
// (furiousMAC/continuity and hexway's apple_bleee).

import 'dart:typed_data';

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int appleCompanyId = 0x004C;

const Map<int, String> appleMessageTypes = {
  0x02: 'iBeacon',
  0x03: 'AirPrint',
  0x05: 'AirDrop',
  0x06: 'HomeKit',
  0x07: 'Proximity pairing (AirPods)',
  0x08: 'Hey Siri',
  0x09: 'AirPlay target',
  0x0A: 'AirPlay source',
  0x0B: 'Magic Switch (Watch)',
  0x0C: 'Handoff',
  0x0D: 'Tethering target',
  0x0E: 'Tethering source',
  0x0F: 'Nearby action',
  0x10: 'Nearby info',
  0x12: 'Find My',
  0x13: 'Nearby info',
  0x1C: 'Nearby info',
};

class AppleDecoder implements Decoder {
  const AppleDecoder();

  @override
  String get name => 'Apple';

  @override
  bool matches(RawAdvertisement adv) {
    final d = adv.manufacturerData[appleCompanyId];
    return d != null && d.length >= 2;
  }

  @override
  Decoded? decode(RawAdvertisement adv) {
    final d = adv.manufacturerData[appleCompanyId]!;
    final types = <String>[];
    final info = <String, String>{};
    // TLV: type, length, payload, repeated.
    var i = 0;
    while (i + 1 < d.length) {
      final type = d[i];
      final len = d[i + 1];
      final end = (i + 2 + len).clamp(0, d.length);
      final payload = d.sublist(i + 2, end);
      final label = appleMessageTypes[type] ?? 'type 0x${_hex2(type)}';
      if (!types.contains(label)) types.add(label);
      switch (type) {
        case 0x09 when payload.length >= 6:
          // flags, config seed, IPv4 of the receiver.
          final ip = payload.sublist(payload.length - 4);
          info['IPv4'] = ip.join('.');
        case 0x02 when payload.length >= 20:
          info['beacon uuid'] = _uuid(payload.sublist(0, 16));
          final bd = ByteData.sublistView(payload);
          info['major'] = '${bd.getUint16(16)}';
          info['minor'] = '${bd.getUint16(18)}';
      }
      if (len == 0) break;
      i = end;
    }
    final model = switch (types) {
      [] => 'Apple device',
      [final one] => one,
      _ => types.first,
    };
    return Decoded(
      protocol: 'Apple Continuity',
      kind: DeviceKind.background,
      model: adv.name ?? model,
      readings: [for (final t in types) Reading('message', t)],
      info: info,
    );
  }

  static String _hex2(int v) => v.toRadixString(16).padLeft(2, '0');

  static String _uuid(Uint8List b) {
    final h = [for (final x in b) _hex2(x)].join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}
