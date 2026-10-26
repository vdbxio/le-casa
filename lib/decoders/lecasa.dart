// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Other Le'Casa screens acting as a sync hub. Nothing to read from the
// advert itself, so they are parked with the phones and beacons; sync
// finds them on its own.

import '../sync/radio.dart';
import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

class LeCasaScreenDecoder implements Decoder {
  const LeCasaScreenDecoder();

  @override
  String get name => "Le'Casa";

  @override
  bool matches(RawAdvertisement adv) =>
      adv.longServiceUuids.contains(syncServiceUuid);

  @override
  Decoded? decode(RawAdvertisement adv) => const Decoded(
    protocol: "Le'Casa",
    model: "Le'Casa hub screen",
    kind: DeviceKind.background,
  );
}
