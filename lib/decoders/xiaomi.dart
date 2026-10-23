// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Xiaomi LYWSD03MMC helpers for the states a sensor is in before it speaks
// BTHome: stock MiBeacon firmware (encrypted, needs a cloud bindkey) and the
// pvvx / ATC1441 custom formats on service UUID 0x181A. Once the sensor is
// switched to BTHome, bthome.dart takes over.

import 'dart:typed_data';

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int miBeaconUuid = 0xFE95;
const int envSensingUuid = 0x181A;

class XiaomiStockDecoder implements Decoder {
  const XiaomiStockDecoder();

  @override
  String get name => 'Xiaomi MiBeacon';

  @override
  bool matches(RawAdvertisement adv) =>
      adv.serviceData.containsKey(miBeaconUuid);

  @override
  Decoded? decode(RawAdvertisement adv) {
    final d = adv.serviceData[miBeaconUuid];
    if (d == null || d.length < 5) return null;
    final frame = d[0] | (d[1] << 8);
    final productId = d[2] | (d[3] << 8);
    final encrypted = frame & 0x0008 != 0;
    final model = switch (productId) {
      0x055B => 'Xiaomi LYWSD03MMC (stock firmware)',
      0x0576 => 'Xiaomi CGD1',
      0x0347 => 'Xiaomi CGG1',
      _ => 'Xiaomi device 0x${productId.toRadixString(16)}',
    };
    return Decoded(
      protocol: 'Xiaomi MiBeacon',
      kind: DeviceKind.needsSetup,
      model: model,
      needs: encrypted
          ? 'Stock firmware is encrypted with a cloud bindkey. '
                'Flash pvvx firmware and pick the BTHome format instead.'
          : 'Unencrypted MiBeacon is not decoded; flash pvvx and pick BTHome.',
      info: {
        'product id': '0x${productId.toRadixString(16)}',
        'frame': '0x${frame.toRadixString(16)}',
      },
    );
  }
}

/// pvvx "custom" (15 bytes) and ATC1441 (13 bytes) formats on 0x181A.
class PvvxCustomDecoder implements Decoder {
  const PvvxCustomDecoder();

  @override
  String get name => 'pvvx/ATC';

  @override
  bool matches(RawAdvertisement adv) {
    final d = adv.serviceData[envSensingUuid];
    return d != null && (d.length == 15 || d.length == 13);
  }

  @override
  Decoded? decode(RawAdvertisement adv) {
    final d = adv.serviceData[envSensingUuid];
    if (d == null) return null;
    final bd = ByteData.sublistView(d);
    if (d.length == 15) {
      // pvvx custom: MAC[6] LE, temp int16 0.01, hum uint16 0.01, batt mV
      // uint16, batt %, counter, flags
      final mac = Uint8List.fromList(d.sublist(0, 6).reversed.toList());
      return Decoded(
        protocol: 'pvvx custom',
        kind: DeviceKind.climate,
        model: 'Xiaomi LYWSD03MMC (pvvx, custom format)',
        readings: [
          Reading('temperature', bd.getInt16(6, Endian.little) / 100, '°C'),
          Reading('humidity', bd.getUint16(8, Endian.little) / 100, '%'),
          Reading('battery', d[12], '%'),
          Reading(
            'battery voltage',
            bd.getUint16(10, Endian.little) / 1000,
            'V',
          ),
        ],
        info: {
          'mac': hex(mac, sep: ':').toUpperCase(),
          'packet id': '${d[13]}',
          'hint':
              'Switch the advertising format to BTHome in the pvvx web tool',
        },
      );
    }
    // ATC1441: MAC[6] BE, temp int16 BE 0.1, hum uint8, batt uint8, batt mV
    // uint16 BE, counter
    return Decoded(
      protocol: 'ATC1441',
      kind: DeviceKind.climate,
      model: 'Xiaomi LYWSD03MMC (ATC1441 format)',
      readings: [
        Reading('temperature', bd.getInt16(6, Endian.big) / 10, '°C'),
        Reading('humidity', d[8], '%'),
        Reading('battery', d[9], '%'),
        Reading('battery voltage', bd.getUint16(10, Endian.big) / 1000, 'V'),
      ],
      info: {
        'mac': hex(d.sublist(0, 6), sep: ':').toUpperCase(),
        'packet id': '${d[12]}',
        'hint': 'Switch the advertising format to BTHome in the pvvx web tool',
      },
    );
  }
}
