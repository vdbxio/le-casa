// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Xiaomi LYWSD03MMC helpers for the states a sensor is in before it speaks
// BTHome: stock MiBeacon firmware (encrypted, needs a cloud bindkey) and the
// pvvx / ATC1441 custom formats on service UUID 0x181A. Once the sensor is
// switched to BTHome, bthome.dart takes over.

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int miBeaconUuid = 0xFE95;
const int envSensingUuid = 0x181A;

class XiaomiStockDecoder implements Decoder {
  /// The bindkey for a device, when the person entered one.
  final KeyProvider keyFor;

  /// Stock firmware sends one value per broadcast (temperature, then
  /// humidity, then battery); the latest of each, by device id.
  final Map<String, Map<String, Reading>> _last = {};

  XiaomiStockDecoder({this.keyFor = noKeys});

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
    final key = keyFor(adv.id);
    final info = {
      'product id': '0x${productId.toRadixString(16)}',
      'frame': '0x${frame.toRadixString(16)}',
      // The frame carries the MAC, reversed: the only way iOS learns it.
      if (frame & 0x0010 != 0 && d.length >= 11)
        'mac': [
          for (var i = 10; i >= 5; i--)
            d[i].toRadixString(16).padLeft(2, '0').toUpperCase(),
        ].join(':'),
    };
    if (key != null && encrypted) {
      final objects = decryptMiBeacon(d, key, adv.macString);
      if (objects == null) {
        // Packets without values (pairing, keep-alive) do not decrypt to
        // anything; only say the key is wrong when there was something.
        final last = _last[adv.id];
        if (last == null) {
          return Decoded(
            protocol: 'Xiaomi MiBeacon',
            kind: DeviceKind.needsSetup,
            model: model,
            needs:
                'Waiting for a broadcast that decrypts with this '
                'bindkey. If none comes, the key is wrong.',
            info: info,
          );
        }
      } else {
        final last = _last.putIfAbsent(adv.id, () => {});
        for (final r in miBeaconReadings(objects)) {
          last[r.label] = r;
        }
      }
      final last = _last[adv.id]!;
      return Decoded(
        protocol: 'Xiaomi MiBeacon',
        kind: DeviceKind.climate,
        model: model,
        readings: [
          for (final l in const ['temperature', 'humidity', 'battery'])
            ?last[l],
        ],
        info: info,
      );
    }
    return Decoded(
      protocol: 'Xiaomi MiBeacon',
      kind: DeviceKind.needsSetup,
      model: model,
      needs: productId == 0x055B
          ? 'Stock firmware encrypts its broadcasts, so Le\'Casa connects to '
                'the sensor now and then to read it instead. Waiting for the '
                'first connection. Enter its bindkey below to read its '
                'broadcasts instead, or flash pvvx firmware and pick BTHome.'
          : encrypted
          ? 'Stock firmware is encrypted with a bindkey. Enter it below, or '
                'flash pvvx firmware and pick the BTHome format instead.'
          : 'Unencrypted MiBeacon is not decoded; flash pvvx and pick BTHome.',
      info: info,
    );
  }
}

/// Decrypts a MiBeacon v4/v5 frame (service data 0xFE95) with its
/// bindkey and returns the object bytes, or null when there are none or
/// the key does not fit. [mac] is needed only when the frame does not carry
/// it (iOS never knows it). Layout as in xiaomi-ble (MIT).
Uint8List? decryptMiBeacon(Uint8List d, Uint8List key, String? mac) {
  if (d.length < 5) return null;
  final frame = d[0] | (d[1] << 8);
  if (frame & 0x0008 == 0 || frame >> 12 < 4 || frame & 0x0040 == 0) {
    return null;
  }
  var i = 5;
  Uint8List? macReversed;
  if (frame & 0x0010 != 0) {
    if (d.length < i + 6) return null;
    macReversed = Uint8List.sublistView(d, i, i + 6);
    i += 6;
  }
  if (frame & 0x0020 != 0) {
    if (d.length < i + 1) return null;
    final cap = d[i];
    i += 1;
    if (cap & 0x20 != 0) i += 2;
  }
  if (macReversed == null) {
    if (mac == null) return null;
    final bytes = [for (final h in mac.split(':')) int.parse(h, radix: 16)];
    if (bytes.length != 6) return null;
    macReversed = Uint8List.fromList(bytes.reversed.toList());
  }
  // Payload, then a 3-byte extended counter and a 4-byte MIC.
  if (d.length < i + 1 + 7) return null;
  final cipher = Uint8List.sublistView(d, i, d.length - 7);
  final nonce = Uint8List.fromList([
    ...macReversed,
    ...d.sublist(2, 5),
    ...d.sublist(d.length - 7, d.length - 4),
  ]);
  try {
    final ccm = CCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          32,
          nonce,
          Uint8List.fromList([0x11]),
        ),
      );
    return ccm.process(
      Uint8List.fromList([...cipher, ...d.sublist(d.length - 4)]),
    );
  } catch (_) {
    return null;
  }
}

/// Readings from decrypted MiBeacon objects (2-byte type, 1-byte length,
/// value), for the climate sensors.
List<Reading> miBeaconReadings(Uint8List o) {
  final out = <Reading>[];
  final bd = ByteData.sublistView(o);
  var i = 0;
  while (i + 3 <= o.length) {
    final type = o[i] | (o[i + 1] << 8);
    final len = o[i + 2];
    final v = i + 3;
    if (v + len > o.length) break;
    switch (type) {
      case 0x1004 when len == 2:
        out.add(
          Reading('temperature', bd.getInt16(v, Endian.little) / 10, '°C'),
        );
      case 0x1006 when len == 2:
        out.add(Reading('humidity', bd.getUint16(v, Endian.little) / 10, '%'));
      case 0x100A when len >= 1:
        out.add(Reading('battery', o[v], '%'));
      case 0x100D when len == 4:
        out.add(
          Reading('temperature', bd.getInt16(v, Endian.little) / 10, '°C'),
        );
        out.add(
          Reading('humidity', bd.getUint16(v + 2, Endian.little) / 10, '%'),
        );
      case 0x4C01 when len == 4:
        out.add(Reading('temperature', bd.getFloat32(v, Endian.little), '°C'));
      case 0x4C02 when len == 1:
        out.add(Reading('humidity', o[v], '%'));
      case 0x4803 when len == 1:
        out.add(Reading('battery', o[v], '%'));
    }
    i = v + len;
  }
  return out;
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
