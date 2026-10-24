// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'apple.dart';
import 'bthome.dart';
import 'decoded.dart';
import 'decoder.dart';
import 'improv.dart';
import 'raw_advertisement.dart';
import 'victron.dart';
import 'xiaomi.dart';

/// All decoders Le'Casa knows, in priority order. The first one whose
/// [Decoder.matches] returns true gets to decode the packet. This is the
/// seed of the zero-setup "match a broadcast, pick a driver" flow.
class DecoderRegistry {
  final List<Decoder> decoders;

  DecoderRegistry(this.decoders);

  factory DecoderRegistry.standard({KeyProvider keyFor = noKeys}) =>
      DecoderRegistry([
        BtHomeDecoder(keyFor: keyFor),
        VictronDecoder(keyFor: keyFor),
        const XiaomiStockDecoder(),
        const PvvxCustomDecoder(),
        const ImprovDecoder(),
        const AppleDecoder(),
      ]);

  Decoded? decode(RawAdvertisement adv) {
    for (final d in decoders) {
      if (d.matches(adv)) {
        final out = d.decode(adv);
        if (out != null) return out;
      }
    }
    return null;
  }
}
