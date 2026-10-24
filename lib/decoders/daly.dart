// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Daly smart BMS Bluetooth modules. They advertise a "DL-<hex>" name and
// a short manufacturer record under company id 0x0402 (which contains the
// module's own address and nothing about the battery). Readings need a
// GATT connection; drivers/daly_driver.dart does that and the connection
// manager polls it. This decoder only recognises the module so it gets a
// Battery card straight away, before the first connection.

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int dalyCompanyId = 0x0402;

class DalyDecoder implements Decoder {
  const DalyDecoder();

  @override
  String get name => 'Daly';

  @override
  bool matches(RawAdvertisement adv) {
    final n = adv.name;
    return n != null &&
        n.startsWith('DL-') &&
        adv.manufacturerData.containsKey(dalyCompanyId);
  }

  @override
  Decoded? decode(RawAdvertisement adv) => Decoded(
    protocol: 'Daly BMS',
    kind: DeviceKind.battery,
    model: 'Daly smart BMS',
    needs:
        'Daly BMS broadcasts no readings; Le\'Casa connects to it to read '
        'cells and state of charge. Waiting for the first connection.',
    info: {'module': adv.name!},
  );
}
