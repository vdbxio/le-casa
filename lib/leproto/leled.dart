// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Le'LED (the WLED usermod in firmware/le-led) seen through its encrypted
// BTHome advert: a power object and a 10-byte raw object of light state.

import 'dart:typed_data';

import '../decoders/decoded.dart';
import 'leproto.dart';

/// The model name Le'LED shows as.
const String leLedModel = "Le'LED";

/// Keys that decrypted a Le'LED, by device id. Sending a command needs the
/// same key, wherever it came from (saved here, synced, or matched by trial).
class LeLedKeys {
  static final Map<String, Uint8List> _keys = {};
  static final Map<String, LeLedState> _state = {};

  static Uint8List? keyOf(String id) => _keys[id];
  static LeLedState? stateOf(String id) => _state[id];

  static void remember(String id, Uint8List key, LeLedState s) {
    _keys[id] = key;
    _state[id] = s;
  }

  /// For tests.
  static void clear() {
    _keys.clear();
    _state.clear();
  }
}

/// A decrypted BTHome payload is Le'LED when it holds exactly a power
/// object and a 10-byte raw object (PROTOCOL.md, "Uplink").
Decoded? leLedDecoded(
  String id,
  Uint8List key,
  List<Reading> readings,
  Map<String, String> info,
) {
  if (readings.length != 2) return null;
  final power = readings.where((r) => r.label == 'power').firstOrNull;
  final raw = readings.where((r) => r.label == 'raw').firstOrNull;
  if (power?.value is! bool || raw?.value is! String) return null;
  final hexRaw = (raw!.value as String).replaceAll(' ', '');
  if (hexRaw.length != 20) return null;
  final bytes = [
    for (var i = 0; i < 20; i += 2)
      int.parse(hexRaw.substring(i, i + 2), radix: 16),
  ];
  final s = LeLedState.parse(bytes)!;
  LeLedKeys.remember(id, key, s);
  final on = power!.value as bool;
  return Decoded(
    protocol: "Le'Proto",
    kind: DeviceKind.lights,
    model: leLedModel,
    readings: [
      Reading('on', on),
      Reading('brightness', (s.bri * 100 / 255).round(), '%'),
      Reading('pattern', wledEffects[s.fx] ?? 'Effect ${s.fx}'),
      Reading('colour', '#${s.colourHex}'),
      Reading('speed', s.sx),
      Reading('intensity', s.ix),
      if (s.preset != 0) Reading('preset', s.preset),
    ],
    info: {
      ...info,
      'revision': '${s.rev}',
      'ack': 'slot ${s.ackSlot}, seq ${s.ackSeqLow}',
      'palette': '${s.pal}',
      "Le'Proto id": LepKeys(key).dstHex,
    },
    keyCheck: KeyCheck.works,
  );
}
