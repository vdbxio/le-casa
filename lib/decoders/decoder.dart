// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:typed_data';

import 'decoded.dart';
import 'raw_advertisement.dart';

/// Looks up the encryption key the user stored for a device id, or null.
typedef KeyProvider = Uint8List? Function(String deviceId);

Uint8List? noKeys(String _) => null;

/// A protocol decoder. Each one answers "is this packet mine?" and, if so,
/// turns it into readings. Decoders are pure functions over
/// [RawAdvertisement] so they can be tested with captured packets.
abstract interface class Decoder {
  String get name;
  bool matches(RawAdvertisement adv);
  Decoded? decode(RawAdvertisement adv);
}
