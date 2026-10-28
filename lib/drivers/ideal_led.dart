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

/// Takes scene colours, unencrypted, after a `MULT` header.
const idealLedBulk = 'd44bc439-abfd-45a2-b575-92541612960a';
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

int _scale(int v, int pct) => v == 0 ? 0 : (v * pct ~/ 100).clamp(_minLit, 255);

/// `SGLS`: effect [mode] (0 is a solid colour) in [fg] over [bg], each
/// 0xRRGGBB scaled to [brightness] percent, the way the app does
/// brightness. Byte 7 stays 100 and the last byte 0x32, as captured.
/// Plaintext.
Uint8List idealLedEffect(
  int mode,
  int fg,
  int bg, {
  int brightness = 100,
  int speed = 0x50,
}) {
  RangeError.checkValueInInterval(mode, 0, idealEffectCount - 1, 'mode');
  final pct = brightness.clamp(0, 100);
  List<int> rgb(int c) => [
    _scale((c >> 16) & 0xFF, pct),
    _scale((c >> 8) & 0xFF, pct),
    _scale(c & 0xFF, pct),
  ];
  return _tagged('SGLS', [
    mode,
    0,
    0x64,
    speed.clamp(0, 100),
    ...rgb(fg),
    ...rgb(bg),
    0x32,
  ]);
}

/// A solid colour: `SGLS` mode 0 with the colour twice.
Uint8List idealLedColour(int rgb, int brightness) =>
    idealLedEffect(0, rgb, rgb, brightness: brightness);

/// The firmware indexes 10 `SGLS` and 12 `MULT` slots with these values
/// unchecked and saves them to flash, so nothing outside them is ever sent.
const idealEffectCount = 10;
const idealSceneCount = 12;
const idealSceneMaxColours = 7;

/// `MULT` header for a multi-colour scene; its colours follow as
/// [idealLedSceneFrame] on [idealLedBulk]. The last byte repeats the
/// brightness the frame is scaled to, as the app sends it. Plaintext.
Uint8List idealLedScene(
  int effect,
  int colours, {
  int speed = 0x50,
  int brightness = 100,
}) {
  RangeError.checkValueInInterval(effect, 0, idealSceneCount - 1, 'effect');
  RangeError.checkValueInInterval(colours, 1, idealSceneMaxColours, 'colours');
  return _tagged('MULT', [
    effect,
    0,
    0x64,
    speed.clamp(0, 100),
    colours,
    brightness.clamp(0, 100),
  ]);
}

/// The scene's colours, scaled to [brightness] percent and truncated (no
/// floor here, as the app does), in the 98-byte frame the app writes:
/// `<data length + 1> <frame index 0> R G B ...`.
Uint8List idealLedSceneFrame(List<int> colours, int brightness) {
  final pct = brightness.clamp(0, 100);
  final f = Uint8List(98);
  f[0] = colours.length * 3 + 1;
  for (var i = 0; i < colours.length; i++) {
    final c = colours[i];
    f[2 + i * 3] = ((c >> 16) & 0xFF) * pct ~/ 100;
    f[3 + i * 3] = ((c >> 8) & 0xFF) * pct ~/ 100;
    f[4 + i * 3] = (c & 0xFF) * pct ~/ 100;
  }
  return f;
}

/// The vendor app's rainbow (red, orange, yellow, green, blue, purple,
/// white), as captured at 50 % and doubled.
const idealRainbow = [
  0xFF0000, 0xFFA200, 0xFFFF00, 0x00FF00, 0x0000FF, 0xFF00FF, 0xFFFFFF, //
];

/// A named look: a `MULT` scene in [colours], or (with [effect]) an `SGLS`
/// effect in the colour picked on the light page over black.
class IdealPattern {
  final String name;
  final int? scene;
  final int? effect;
  final List<int> colours;
  const IdealPattern(
    this.name, {
    this.scene,
    this.effect,
    this.colours = idealRainbow,
  });
}

/// Scenes 0, 1, 7, 8 and 9 and effects 0 and 1 were captured from the
/// vendor app; the rest differ only in that index, inside the range the
/// firmware draws.
const idealPatterns = [
  IdealPattern('Rainbow flow', scene: 9),
  IdealPattern('Rainbow bands', scene: 0),
  IdealPattern('Rainbow waves', scene: 8),
  IdealPattern('Rainbow meteors', scene: 7),
  IdealPattern('Twinkle', scene: 1),
  IdealPattern('Colour jump', scene: 10),
  IdealPattern('Colour fade', scene: 11),
  IdealPattern('Colour wipe', scene: 2),
  IdealPattern('Chase', effect: 5),
  IdealPattern('Meteor', effect: 3),
  IdealPattern('Pulse', effect: 4),
  IdealPattern('Running dot', effect: 6),
  IdealPattern('Stacking', effect: 2),
  IdealPattern('Breathe', effect: 8),
  IdealPattern('Strobe', effect: 9),
];

IdealPattern? idealPatternNamed(Object? name) =>
    idealPatterns.where((p) => p.name == name).firstOrNull;

/// Setting names [IdealLedDriver.control] understands.
abstract final class LightSetting {
  static const on = 'on'; // bool
  /// `{'rgb': 0xRRGGBB, 'brightness': 1..100}`: the whole look at once, so
  /// any screen can send it without knowing what another one set.
  static const colour = 'colour';

  /// `{'pattern': name, 'rgb': 0xRRGGBB, 'speed': 0..100,
  /// 'brightness': 1..100}`, a pattern from [idealPatterns].
  static const pattern = 'pattern';
  static const brightness = 'brightness'; // reading only, percent
  static const speed = 'speed'; // reading only, percent
}

/// What a solid colour shows as in the pattern reading.
const idealSolid = 'Solid colour';

String idealLedHex(int rgb) =>
    '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The colour a light was last set to, as its reading holds it.
int? idealLedRgb(Object? reading) => reading is String && reading.length == 7
    ? int.tryParse(reading.substring(1), radix: 16)
    : null;

/// The controller says nothing, so the broadcast only names it; what it was
/// last set to comes back from the command (and travels to other screens
/// like any connected reading).
Decoded _decoded(String? name, [List<Reading> readings = const []]) => Decoded(
  protocol: 'iDeal LED',
  kind: DeviceKind.lights,
  model: 'iDeal LED controller',
  readings: readings,
  info: {
    'module': ?name,
    'state': 'as last set from Le\'Casa; the controller does not report it',
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
  Decoded? decode(RawAdvertisement adv) => _decoded(adv.name);
}

class IdealLedDriver implements LingeringDriver {
  const IdealLedDriver();

  // Brightness and speed come in runs; each new connection also makes the
  // strip blink three times.
  @override
  Duration get linger => const Duration(seconds: 6);

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
      _decoded(adv.name);

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand command,
  ) async {
    final v = command.value;
    final tx = s.require(idealLedWrite, 'iDeal LED command');
    final rx = s.require(idealLedNotify, 'iDeal LED ack');
    final acks = (await s.subscribe(rx)).map(idealLedDecrypt);
    int pctOf(Map v) => (v['brightness'] as num? ?? 100).toInt().clamp(1, 100);
    int rgbOf(Map v) => (v['rgb'] as num? ?? 0xFFFFFF).toInt() & 0xFFFFFF;
    switch (command.setting) {
      case LightSetting.on when v is bool:
        // The connection manager keeps the look shown alongside.
        await _send(s, tx, acks, 'TURN', idealLedPower(v));
        return _decoded(adv.name, [Reading(LightSetting.on, v)]);
      case LightSetting.colour when v is Map:
        final rgb = rgbOf(v);
        final pct = pctOf(v);
        // A colour on a dark strip turns it on, as the app does; sending
        // TURN first does no harm when it is already on.
        await _send(s, tx, acks, 'TURN', idealLedPower(true));
        await _send(s, tx, acks, 'SGLS', idealLedColour(rgb, pct));
        return _decoded(adv.name, [
          const Reading(LightSetting.on, true),
          const Reading(LightSetting.pattern, idealSolid),
          Reading(LightSetting.colour, idealLedHex(rgb)),
          Reading(LightSetting.brightness, pct, '%'),
        ]);
      case LightSetting.pattern when v is Map:
        final p = idealPatternNamed(v['pattern']);
        if (p == null) throw ArgumentError('Unknown pattern ${v['pattern']}');
        final rgb = rgbOf(v);
        final pct = pctOf(v);
        final speed = (v['speed'] as num? ?? 80).toInt().clamp(0, 100);
        await _send(s, tx, acks, 'TURN', idealLedPower(true));
        if (p.scene case final scene?) {
          final bulk = s.require(idealLedBulk, 'iDeal LED scene data');
          await _send(
            s,
            tx,
            acks,
            'MULT',
            idealLedScene(
              scene,
              p.colours.length,
              speed: speed,
              brightness: pct,
            ),
          );
          final done = _ack(acks, 'MULTCP');
          try {
            await s.write(
              bulk,
              idealLedSceneFrame(p.colours, pct),
              withResponse: bulk.canWrite || !bulk.canWriteWithoutResponse,
            );
          } catch (_) {
            done.ignore();
            rethrow;
          }
          await done;
        } else {
          await _send(
            s,
            tx,
            acks,
            'SGLS',
            idealLedEffect(p.effect!, rgb, 0, brightness: pct, speed: speed),
          );
        }
        return _decoded(adv.name, [
          const Reading(LightSetting.on, true),
          Reading(LightSetting.pattern, p.name),
          Reading(LightSetting.colour, idealLedHex(rgb)),
          Reading(LightSetting.brightness, pct, '%'),
          Reading(LightSetting.speed, speed, '%'),
        ]);
      default:
        throw ArgumentError('Unknown setting $command');
    }
  }

  /// The ack for [tag]: `<len> <tag>OK`. Only the first len + 1 bytes count;
  /// the firmware sends the next reply in its table after them, so an
  /// SGLS ack also holds "MULTOK".
  Future<void> _ack(Stream<Uint8List> acks, String tag) {
    final ok = ascii.encode('${tag}OK');
    return acks
        .where((a) => _isAck(a, ok))
        .first
        .timeout(const Duration(seconds: 3));
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
    for (var attempt = 1; ; attempt++) {
      final ack = _ack(acks, tag);
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

bool _isAck(List<int> a, List<int> ok) {
  if (a.length < ok.length + 1 || a[0] != ok.length) return false;
  for (var i = 0; i < ok.length; i++) {
    if (a[i + 1] != ok[i]) return false;
  }
  return true;
}
