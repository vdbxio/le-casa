// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Recognises the battery management systems Le'Casa can read over a
// connection (lib/bms/) so they get a Battery card straight away, before
// the first connection. Most BMSs broadcast nothing useful.

import '../bms/registry.dart';
import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

class BmsDecoder implements Decoder {
  /// Module names another decoder handles (Daly has its own).
  final Set<String> exclude;

  const BmsDecoder({this.exclude = const {}});

  @override
  String get name => 'BMS';

  BmsSpec? _spec(RawAdvertisement adv) {
    final s = bmsSpecFor(adv);
    return s == null || exclude.contains(s.module) ? null : s;
  }

  @override
  bool matches(RawAdvertisement adv) => _spec(adv) != null;

  @override
  Decoded? decode(RawAdvertisement adv) {
    final s = _spec(adv);
    if (s == null) return null;
    return Decoded(
      protocol: '${s.info['manufacturer']} BMS',
      kind: DeviceKind.battery,
      model: s.title,
      needs: [
        '${s.title} broadcasts no readings; Le\'Casa connects to it to read '
            'them. Waiting for the first connection.',
        if (s.acceptSecret)
          'If you set a PIN or password in the battery\'s own app, enter it '
              'on this device\'s page.',
      ].join(' '),
      info: {if (adv.name != null) 'module': adv.name!, 'bms': s.module},
    );
  }
}
