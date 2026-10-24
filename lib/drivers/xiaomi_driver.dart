// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Xiaomi LYWSD03MMC on stock firmware. Its broadcasts are encrypted with a
// cloud bindkey, but over a plain GATT connection it hands out the current
// reading with no key at all: subscribe to the EBE0CCC1 characteristic and
// it notifies 5 bytes (temperature, humidity, battery voltage) every few
// seconds. The same service also has a plain battery percentage. This is
// what the Xiaomi app and the pvvx web flasher do to show live values.
//
// Connecting costs the sensor far more battery than advertising, so the
// poll interval is long. Flashing pvvx firmware with BTHome is still the
// better long-term setup; this is for sensors left as-is.

import 'dart:async';
import 'dart:typed_data';

import '../ble/gatt_session.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import '../decoders/xiaomi.dart';
import 'driver.dart';

const xiaomiDataUuid = 'ebe0ccc1-7a0a-4b0c-8a1a-6ff2997da3a6';
const xiaomiBatteryUuid = 'ebe0ccc4-7a0a-4b0c-8a1a-6ff2997da3a6';

/// Parsed EBE0CCC1 notification.
class XiaomiLiveReading {
  final double temperature; // °C
  final int humidity; // %
  final double batteryVoltage; // V

  const XiaomiLiveReading(this.temperature, this.humidity, this.batteryVoltage);

  /// Same estimate the sensor's own firmware uses: 2.1 V empty, 3.1 V full.
  int get estimatedBattery =>
      (((batteryVoltage - 2.1) * 100).round()).clamp(0, 100);
}

/// Decodes the 5-byte value: int16 LE temperature in 0.01 °C, uint8
/// humidity in %, uint16 LE battery in mV.
XiaomiLiveReading? parseXiaomiLive(Uint8List d) {
  if (d.length < 5) return null;
  final bd = ByteData.sublistView(d);
  return XiaomiLiveReading(
    bd.getInt16(0, Endian.little) / 100,
    d[2],
    bd.getUint16(3, Endian.little) / 1000,
  );
}

Decoded xiaomiLiveToDecoded(
  XiaomiLiveReading r, {
  int? batteryPercent,
  String model = 'Xiaomi LYWSD03MMC (stock firmware)',
}) => Decoded(
  protocol: 'Xiaomi (connected)',
  kind: DeviceKind.climate,
  model: model,
  readings: [
    Reading('temperature', r.temperature, '°C'),
    Reading('humidity', r.humidity, '%'),
    Reading('battery', batteryPercent ?? r.estimatedBattery, '%'),
    Reading('battery voltage', r.batteryVoltage, 'V'),
  ],
  info: {
    'source': 'connection',
    'hint':
        'Flash pvvx firmware with BTHome to get readings from broadcasts '
        'instead, which is kinder to the battery.',
  },
);

class XiaomiStockGattDriver implements GattDriver {
  const XiaomiStockGattDriver();

  @override
  String get name => 'Xiaomi LYWSD03MMC';

  @override
  Duration get interval => const Duration(minutes: 5);

  @override
  Duration get timeout => const Duration(seconds: 40);

  @override
  bool matches(RawAdvertisement adv) {
    final d = adv.serviceData[miBeaconUuid];
    if (d == null || d.length < 4) return false;
    final productId = d[2] | (d[3] << 8);
    return productId == 0x055B; // LYWSD03MMC
  }

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async {
    final data = s.require(xiaomiDataUuid, 'Xiaomi live data');
    final stream = await s.subscribe(data);
    // Stock firmware sends the first notification within a second or two
    // of the subscription, then every ~6 s.
    final first = await stream
        .map(parseXiaomiLive)
        .where((r) => r != null)
        .first
        .timeout(const Duration(seconds: 20));
    int? percent;
    final batt = s.find(xiaomiBatteryUuid);
    if (batt != null && batt.canRead) {
      try {
        final v = await s.read(batt).timeout(const Duration(seconds: 5));
        if (v.isNotEmpty) percent = v[0];
      } catch (_) {
        // Fall back to the voltage estimate.
      }
    }
    return xiaomiLiveToDecoded(first!, batteryPercent: percent);
  }
}
