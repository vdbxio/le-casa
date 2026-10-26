// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// BTHome v2 decoder (https://bthome.io). Covers plain and AES-CCM encrypted
// payloads. Used for Xiaomi LYWSD03MMC running pvvx firmware, Le'Fob, and
// any other BTHome broadcaster.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'bthome_objects.dart';
import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const int bthomeServiceUuid = 0xFCD2;

class BtHomeDecoder implements Decoder {
  final KeyProvider keyFor;

  const BtHomeDecoder({this.keyFor = noKeys});

  @override
  String get name => 'BTHome';

  @override
  bool matches(RawAdvertisement adv) =>
      adv.serviceData.containsKey(bthomeServiceUuid);

  @override
  Decoded? decode(RawAdvertisement adv) {
    final data = adv.serviceData[bthomeServiceUuid];
    if (data == null || data.isEmpty) return null;

    final info = data[0];
    final encrypted = info & 0x01 != 0;
    final macIncluded = info & 0x02 != 0;
    final triggerBased = info & 0x04 != 0;
    final version = (info >> 5) & 0x07;
    if (version != 2) {
      return Decoded(
        protocol: 'BTHome',
        kind: DeviceKind.needsSetup,
        model: 'BTHome v$version device',
        needs: 'Only BTHome v2 is supported',
      );
    }

    var offset = 1;
    Uint8List? mac = adv.mac;
    if (macIncluded) {
      if (data.length < 7) return null;
      // MAC is sent reversed (little-endian).
      mac = Uint8List.fromList(data.sublist(1, 7).reversed.toList());
      offset = 7;
    }

    final extra = <String, String>{
      if (triggerBased) 'mode': 'trigger based',
      if (mac != null) 'mac': hex(mac, sep: ':').toUpperCase(),
    };

    Uint8List payload;
    if (encrypted) {
      final key = keyFor(adv.id);
      if (key == null) {
        return Decoded(
          protocol: 'BTHome (encrypted)',
          kind: DeviceKind.needsSetup,
          model: _guessModel(adv, const []),
          needs: 'Needs the 16-byte BTHome encryption key',
          info: extra,
        );
      }
      if (mac == null) {
        return Decoded(
          protocol: 'BTHome (encrypted)',
          kind: DeviceKind.needsSetup,
          model: _guessModel(adv, const []),
          needs:
              'Cannot decrypt without the MAC address (iOS hides it). '
              'Ask the device to include its MAC in the payload.',
          info: extra,
        );
      }
      if (data.length < offset + 8 + 1) {
        return Decoded(
          protocol: 'BTHome (encrypted)',
          kind: DeviceKind.needsSetup,
          model: _guessModel(adv, const []),
          needs: 'Encrypted packet too short',
          info: extra,
        );
      }
      final counter = data.sublist(data.length - 8, data.length - 4);
      final mic = data.sublist(data.length - 4);
      final cipherText = data.sublist(offset, data.length - 8);
      final nonce = Uint8List.fromList([...mac, 0xD2, 0xFC, info, ...counter]);
      final plain = decryptCcm(key, nonce, cipherText, mic);
      if (plain == null) {
        return Decoded(
          protocol: 'BTHome (encrypted)',
          kind: DeviceKind.needsSetup,
          model: _guessModel(adv, const []),
          needs: 'Decryption failed: wrong key?',
          info: extra,
          keyCheck: KeyCheck.wrong,
        );
      }
      extra['counter'] = ByteData.sublistView(counter)
          .getUint32(0, Endian.little)
          .toString();
      payload = plain;
    } else {
      payload = data.sublist(offset);
    }

    final readings = <Reading>[];
    final events = <DeviceEvent>[];
    final seen = <String, int>{};
    var i = 0;
    while (i < payload.length) {
      final objId = payload[i];
      final obj = bthomeObjects[objId];
      if (obj == null) {
        extra['unknown object'] = '0x${objId.toRadixString(16)} at byte $i';
        break; // lengths after this are unknowable
      }
      i++;
      int len = obj.length;
      if (obj.format == BtFormat.text || obj.format == BtFormat.raw) {
        if (i >= payload.length) break;
        len = payload[i];
        i++;
      }
      if (i + len > payload.length) break;
      final bytes = payload.sublist(i, i + len);
      i += len;

      switch (obj.format) {
        case BtFormat.uint:
        case BtFormat.sint:
          var v = _leInt(bytes);
          if (obj.format == BtFormat.sint) v = _toSigned(v, len * 8);
          final label = _dedupe(seen, obj.label);
          if (objId == 0x00) {
            extra['packet id'] = '$v';
          } else if (obj.factor == 1) {
            readings.add(Reading(label, v, obj.unit));
          } else {
            readings.add(Reading(label, _round(v * obj.factor), obj.unit));
          }
        case BtFormat.bin:
          readings.add(Reading(_dedupe(seen, obj.label), bytes[0] != 0));
        case BtFormat.event:
          final n = (seen[obj.label] ?? 0) + 1;
          seen[obj.label] = n;
          if (objId == 0x3A) {
            final ev = bthomeButtonEvents[bytes[0]] ?? 'event_${bytes[0]}';
            if (ev != 'none') events.add(DeviceEvent('button $n', ev));
          } else {
            final ev = bthomeDimmerEvents[bytes[0]] ?? 'event_${bytes[0]}';
            if (ev != 'none') {
              events.add(DeviceEvent('dimmer $n', '$ev ${bytes[1]} steps'));
            }
          }
        case BtFormat.text:
          readings.add(
            Reading(
              _dedupe(seen, 'text'),
              utf8.decode(bytes, allowMalformed: true),
            ),
          );
        case BtFormat.raw:
          readings.add(Reading(_dedupe(seen, 'raw'), hex(bytes)));
        case BtFormat.timestamp:
          final ts = DateTime.fromMillisecondsSinceEpoch(
            _leInt(bytes) * 1000,
            isUtc: true,
          );
          readings.add(
            Reading(_dedupe(seen, 'timestamp'), ts.toIso8601String()),
          );
        case BtFormat.deviceType:
          extra['device type id'] = '${_leInt(bytes)}';
        case BtFormat.firmware:
          // Sent little-endian: patch, minor, major[, extra]
          extra['firmware'] = bytes.reversed.join('.');
      }
    }

    final model = _guessModel(adv, readings, events: events);
    return Decoded(
      protocol: encrypted ? 'BTHome (encrypted)' : 'BTHome',
      model: model,
      kind: _kindFor(model, readings, events),
      readings: readings,
      events: events,
      info: extra,
      keyCheck: encrypted ? KeyCheck.works : null,
    );
  }

  static String _guessModel(
    RawAdvertisement adv,
    List<Reading> readings, {
    List<DeviceEvent> events = const [],
  }) {
    final n = (adv.name ?? '').toLowerCase();
    if (n.contains('fob')) return "Le'Fob";
    if (n.contains('dongle')) return "Le'Dongle";
    if (n.startsWith('atc') || n.startsWith('lywsd') || n.startsWith('pvvx')) {
      return 'Xiaomi LYWSD03MMC (pvvx)';
    }
    final labels = readings.map((r) => r.label).toSet();
    if (events.isNotEmpty) return 'BTHome button device';
    if (labels.contains('temperature') && labels.contains('humidity')) {
      return 'Temperature/Humidity sensor';
    }
    return 'BTHome device';
  }

  static DeviceKind _kindFor(
    String model,
    List<Reading> readings,
    List<DeviceEvent> events,
  ) {
    if (model.startsWith("Le'")) return DeviceKind.leDevice;
    final labels = readings.map((r) => r.label).toSet();
    if (labels.contains('temperature') || labels.contains('humidity')) {
      return DeviceKind.climate;
    }
    // A button device may only send its battery level between presses, so
    // the model guess (from name or events) decides.
    if (events.isNotEmpty || model == 'BTHome button device') {
      return DeviceKind.buttons;
    }
    return DeviceKind.sensor;
  }

  static String _dedupe(Map<String, int> seen, String label) {
    final n = (seen[label] ?? 0) + 1;
    seen[label] = n;
    return n == 1 ? label : '$label $n';
  }

  static int _leInt(List<int> b) {
    var v = 0;
    for (var i = b.length - 1; i >= 0; i--) {
      v = (v << 8) | b[i];
    }
    return v;
  }

  static int _toSigned(int v, int bits) =>
      (v & (1 << (bits - 1))) != 0 ? v - (1 << bits) : v;

  static double _round(double v) => (v * 1e6).roundToDouble() / 1e6;

  /// AES-128-CCM with a 4-byte MIC, as BTHome v2 specifies.
  /// Returns null when the MIC does not verify.
  static Uint8List? decryptCcm(
    Uint8List key,
    Uint8List nonce,
    Uint8List cipherText,
    Uint8List mic,
  ) {
    try {
      final ccm = CCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 32, nonce, Uint8List(0)),
        );
      return ccm.process(Uint8List.fromList([...cipherText, ...mic]));
    } catch (_) {
      return null;
    }
  }
}
