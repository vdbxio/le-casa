// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import '../ble/gatt_session.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'alpicool_driver.dart';
import 'bms_driver.dart';
import 'daly_driver.dart';
import 'ideal_led.dart';
import 'switchbot_driver.dart';
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

/// A driver whose device answers quickly enough to read every few
/// seconds over a link that stays open, on screens whose Bluetooth holds
/// links well.
abstract interface class LiveDriver implements GattDriver {
  /// How often to read while the link stays open.
  Duration get liveInterval;
}

/// A change asked of a device: which setting, and its new value.
class DeviceCommand {
  final String setting;
  final Object value;
  const DeviceCommand(this.setting, this.value);

  @override
  String toString() => '$setting = $value';
}

/// A driver that can also change settings on the device. [control] gets a
/// session of its own, like [read], and returns the state read back after
/// the change.
abstract interface class ControllableDriver implements GattDriver {
  Future<Decoded> control(
    GattSession session,
    RawAdvertisement adv,
    DeviceCommand command,
  );
}

/// All connection drivers, in priority order. Mirrors [DecoderRegistry]
/// for broadcasts.
class GattDriverRegistry {
  final List<GattDriver> drivers;

  const GattDriverRegistry(this.drivers);

  /// Daly modules with the usual "DL-" name keep their own driver, which
  /// has run on real batteries for a while; every other BMS, other Daly
  /// variants included, goes through the aiobmsble port.
  factory GattDriverRegistry.standard({SecretProvider secretFor = noSecrets}) =>
      GattDriverRegistry([
        const DalyDriver(),
        const XiaomiStockGattDriver(),
        const AlpicoolDriver(),
        const SwitchBotPlugDriver(),
        const IdealLedDriver(),
        BmsDriver(secretFor: secretFor),
      ]);

  GattDriver? forAdvertisement(RawAdvertisement adv) {
    for (final d in drivers) {
      if (d.matches(adv)) return d;
    }
    return null;
  }
}
