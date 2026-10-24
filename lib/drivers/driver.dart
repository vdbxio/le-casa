// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import '../ble/gatt_session.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'daly_driver.dart';
import 'xiaomi_driver.dart';

/// A driver for a device that only gives up its readings over a GATT
/// connection. Like [Decoder] it answers "is this mine?" from the
/// advertisement; unlike a decoder it is then handed an open session,
/// reads what it needs, and returns. The connection manager owns
/// connecting, timing and disconnecting, so a driver is just the protocol.
abstract interface class GattDriver {
  String get name;

  /// How often the manager should reconnect and read. Connections cost
  /// battery on coin-cell sensors, so sensors poll slowly and a BMS fast.
  Duration get interval;

  /// How long one [read] may take before the manager gives up on it.
  Duration get timeout;

  bool matches(RawAdvertisement adv);

  Future<Decoded> read(GattSession session, RawAdvertisement adv);
}

/// All connection drivers, in priority order. Mirrors [DecoderRegistry]
/// for broadcasts.
class GattDriverRegistry {
  final List<GattDriver> drivers;

  const GattDriverRegistry(this.drivers);

  factory GattDriverRegistry.standard() =>
      const GattDriverRegistry([DalyDriver(), XiaomiStockGattDriver()]);

  GattDriver? forAdvertisement(RawAdvertisement adv) {
    for (final d in drivers) {
      if (d.matches(adv)) return d;
    }
    return null;
  }
}
