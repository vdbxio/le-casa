// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// LED strip controllers made for the "iDeal LED" app (Winkison), which
// advertise as ISP-xxxxxx or IDL-xxxxxx. Every command is one 16-byte
// block, AES-128-ECB with a key fixed in the app, written without response
// to ...9600; acks come back the same way on ...9601. The controller says
// nothing about its state, so Le'Casa shows what it last set.
//
// Layouts and the key from KyleJamesWalker/glowmote (MIT),
// crates/glowmote-core/src/ideal.rs and docs/protocols/ideal-led.md, and
// 8none1/idealLED (MIT). Only byte patterns captured from the vendor app
// are sent: the idealLED author bricked lights with made-up ones.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../ble/gatt_session.dart';
import '../decoders/decoded.dart';
import '../decoders/decoder.dart';
import '../decoders/raw_advertisement.dart';
import 'driver.dart';

const idealLedWrite = 'd44bc439-abfd-45a2-b575-925416129600';
const idealLedNotify = 'd44bc439-abfd-45a2-b575-925416129601';
const idealLedCompanyId = 0x5254; // "TR", the firmware family

final _key = Uint8List.fromList([
  0x34, 0x52, 0x2a, 0x5b, 0x7a, 0x6e, 0x49, 0x2c, //
  0x08, 0x09, 0x0a, 0x9d, 0x8d, 0x2a, 0x23, 0xf8,
]);

Uint8List _aes(bool encrypt, Uint8List block) {
  final aes = AESEngine()..init(encrypt, KeyParameter(_key));
  final out = Uint8List(16);
  aes.processBlock(block, 0, out, 0);
  return out;
}

Uint8List idealLedEncrypt(Uint8List plain) => _aes(true, plain);
Uint8List idealLedDecrypt(Uint8List cipher) => _aes(false, cipher);

Uint8List _tagged(String tag, List<int> args) {
  final p = Uint8List(16);
  p[0] = tag.length + args.length;
  p.setRange(1, 1 + tag.length, ascii.encode(tag));
  p.setRange(1 + tag.length, 1 + tag.length + args.length, args);
  return p;
}

/// `TURN 01` / `TURN 00`, plaintext.
Uint8List idealLedPower(bool on) => _tagged('TURN', [on ? 1 : 0]);

/// The vendor app never sends a lit channel below this.
const _minLit = 2;

/// `SGLS` with mode 0 (static colour): [rgb] as 0xRRGGBB, scaled to
/// [brightness] percent, the way the app does brightness. Plaintext.
Uint8List idealLedColour(int rgb, int brightness) {
  final pct = brightness.clamp(0, 100);
  int ch(int v) => v == 0 ? 0 : (v * pct ~/ 100).clamp(_minLit, 255);
  final r = ch((rgb >> 16) & 0xFF);
  final g = ch((rgb >> 8) & 0xFF);
  final b = ch(rgb & 0xFF);
  return _tagged('SGLS', [0, 0, 0x64, 0x50, r, g, b, r, g, b, 0x32]);
}

/// What Le'Casa last set on a controller, by device id. The controller
/// cannot be asked.
class IdealLedState {
  final bool on;
  final int colour;
  final int brightness;
  const IdealLedState({
    this.on = true,
    this.colour = 0xFFFFFF,
    this.brightness = 100,
  });

  IdealLedState copyWith({bool? on, int? colour, int? brightness}) =>
      IdealLedState(
        on: on ?? this.on,
        colour: colour ?? this.colour,
        brightness: brightness ?? this.brightness,
      );
}

final Map<String, IdealLedState> idealLedSet = {};

/// Setting names [IdealLedDriver.control] understands.
abstract final class LightSetting {
  static const on = 'on'; // bool
  static const colour = 'colour'; // int 0xRRGGBB
  static const brightness = 'brightness'; // int 0..100
}

List<Reading> _readings(IdealLedState? s) => s == null
    ? const []
    : [
        Reading(LightSetting.on, s.on),
        Reading(
          LightSetting.colour,
          '#${s.colour.toRadixString(16).padLeft(6, '0').toUpperCase()}',
        ),
        Reading(LightSetting.brightness, s.brightness, '%'),
      ];

Decoded _decoded(String id, String? name) => Decoded(
  protocol: 'iDeal LED',
  kind: DeviceKind.lights,
  model: 'iDeal LED controller',
  readings: _readings(idealLedSet[id]),
  info: {
    'module': ?name,
    'state': 'as last set from this screen; the controller does not report it',
  },
);

class IdealLedDecoder implements Decoder {
  const IdealLedDecoder();

  @override
  String get name => 'iDeal LED';

  @override
  bool matches(RawAdvertisement adv) {
    final n = adv.name ?? '';
    return n.startsWith('ISP-') ||
        n.startsWith('IDL-') ||
        adv.manufacturerData.containsKey(idealLedCompanyId);
  }

  @override
  Decoded? decode(RawAdvertisement adv) => _decoded(adv.id, adv.name);
}

class IdealLedDriver implements ControllableDriver {
  const IdealLedDriver();

  @override
  String get name => 'iDeal LED controller';

  // Never polled: there is nothing to read.
  @override
  Duration get interval => const Duration(hours: 1);

  @override
  Duration get timeout => const Duration(seconds: 20);

  @override
  bool matches(RawAdvertisement adv) => const IdealLedDecoder().matches(adv);

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async =>
      _decoded(adv.id, adv.name);

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand command,
  ) async {
    final before = idealLedSet[adv.id] ?? const IdealLedState();
    final v = command.value;
    final after = switch (command.setting) {
      LightSetting.on when v is bool => before.copyWith(on: v),
      LightSetting.colour when v is int => before.copyWith(
        on: true,
        colour: v & 0xFFFFFF,
      ),
      LightSetting.brightness when v is int => before.copyWith(
        on: true,
        brightness: v.clamp(1, 100),
      ),
      _ => throw ArgumentError('Unknown setting $command'),
    };
    final tx = s.require(idealLedWrite, 'iDeal LED command');
    final rx = s.require(idealLedNotify, 'iDeal LED ack');
    final acks = (await s.subscribe(rx)).map(idealLedDecrypt);
    if (command.setting == LightSetting.on) {
      await _send(s, tx, acks, 'TURN', idealLedPower(after.on));
    } else {
      // A colour or brightness on a strip that is off turns it on, as the
      // app does.
      if (!before.on) {
        await _send(s, tx, acks, 'TURN', idealLedPower(true));
      }
      await _send(
        s,
        tx,
        acks,
        'SGLS',
        idealLedColour(after.colour, after.brightness),
      );
    }
    idealLedSet[adv.id] = after;
    return _decoded(adv.id, adv.name);
  }

  /// Writes one command and waits for its ack ("TURNOK"); a second try if
  /// none comes.
  Future<void> _send(
    GattSession s,
    GattChar tx,
    Stream<Uint8List> acks,
    String tag,
    Uint8List plain,
  ) async {
    final ok = ascii.encode('${tag}OK');
    for (var attempt = 1; ; attempt++) {
      final ack = acks
          .where((a) => _contains(a, ok))
          .first
          .timeout(const Duration(seconds: 3));
      try {
        await s.write(tx, idealLedEncrypt(plain), withResponse: false);
      } catch (_) {
        ack.ignore();
        rethrow;
      }
      try {
        await ack;
        return;
      } on TimeoutException {
        if (attempt == 2) {
          throw TimeoutException('The light did not confirm $tag');
        }
      }
    }
  }
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
