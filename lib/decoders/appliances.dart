// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Appliances that identify themselves only by their advertised name and a
// generic serial-over-BLE service (0xFFE0 / 0xFFF0). Nothing useful is in
// the advert itself; readings and control need a GATT connection, which
// is a later phase. For now they are recognised so they get a card.

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

/// Hcalory diesel heaters advertise as "BYD-<address>" with service 0xFFE0.
class HcaloryDecoder implements Decoder {
  const HcaloryDecoder();

  @override
  String get name => 'Hcalory';

  @override
  bool matches(RawAdvertisement adv) =>
      (adv.name?.startsWith('BYD-') ?? false) &&
      (adv.serviceUuids.contains(0xFFE0) ||
          adv.serviceData.containsKey(0xFFE0));

  @override
  Decoded? decode(RawAdvertisement adv) => Decoded(
    protocol: 'Hcalory',
    kind: DeviceKind.appliance,
    model: 'Hcalory diesel heater',
    needs: 'Needs a connection to read or control. Planned for a later phase.',
    info: {'module': adv.name!},
  );
}

/// Alpicool fridges advertise as "AK1-…", "A1-…" or similar.
class AlpicoolDecoder implements Decoder {
  const AlpicoolDecoder();

  static final _namePattern = RegExp(r'^A[A-Z]?\d-');

  @override
  String get name => 'Alpicool';

  @override
  bool matches(RawAdvertisement adv) {
    final n = adv.name;
    return n != null && _namePattern.hasMatch(n);
  }

  @override
  Decoded? decode(RawAdvertisement adv) => Decoded(
    protocol: 'Alpicool',
    kind: DeviceKind.appliance,
    model: 'Alpicool fridge',
    needs: 'Needs a connection to read or control. Planned for a later phase.',
    info: {'module': adv.name!},
  );
}
