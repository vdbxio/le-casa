// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Reads and controls Alpicool-style fridges over a connection. The fridge
// answers a query with its whole state; a change is either the per-zone
// target command or the full settings block read back with one field
// changed. Every change is followed by a fresh query, so what the card
// shows is what the fridge accepted, not what we asked for.

import 'dart:async';
import 'dart:typed_data';

import '../ble/gatt_session.dart';
import '../decoders/appliances.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'alpicool_protocol.dart';
import 'driver.dart';

/// Setting names [AlpicoolDriver.control] understands.
abstract final class FridgeSetting {
  static const power = 'power'; // bool
  static const eco = 'eco'; // bool
  static const locked = 'locked'; // bool
  static const batteryProtection = 'battery protection'; // 0 low .. 2 high
  static const target = 'target'; // int, in the fridge's unit
  static const target2 = 'target 2'; // int, second zone
}

Decoded alpicoolToDecoded(AlpicoolStatus s, {String? module}) {
  final u = s.unit;
  final z2 = s.zone2;
  return Decoded(
    protocol: 'Alpicool',
    kind: DeviceKind.appliance,
    model: z2 == null ? 'Alpicool fridge' : 'Alpicool fridge (two zones)',
    readings: [
      Reading('temperature', s.zone1.current, u),
      Reading(FridgeSetting.target, s.zone1.target, u),
      if (z2 != null) ...[
        Reading('temperature 2', z2.current, u),
        Reading(FridgeSetting.target2, z2.target, u),
      ],
      Reading(FridgeSetting.power, s.on),
      Reading('mode', s.eco ? 'Eco' : 'Max'),
      Reading('battery voltage', s.batteryVoltage, 'V'),
      if (s.batteryPercent case final p?) Reading('battery', p, '%'),
      Reading(
        FridgeSetting.batteryProtection,
        alpicoolBatteryProtection[s.batteryProtection],
      ),
      Reading(FridgeSetting.locked, s.locked),
    ],
    info: {
      'module': ?module,
      'settable range': '${s.minTemp} to ${s.maxTemp} $u',
      'hysteresis': '${s.zone1.hysteresis} $u',
      'start delay': '${s.startDelay} min',
    },
  );
}

class AlpicoolDriver implements ControllableDriver {
  const AlpicoolDriver();

  @override
  String get name => 'Alpicool fridge';

  @override
  Duration get interval => const Duration(minutes: 1);

  @override
  Duration get timeout => const Duration(seconds: 30);

  @override
  bool matches(RawAdvertisement adv) => const AlpicoolDecoder().matches(adv);

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async {
    final link = await _FridgeLink.open(s);
    return alpicoolToDecoded(await link.query(), module: adv.name);
  }

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand command,
  ) async {
    final link = await _FridgeLink.open(s);
    final before = await link.query();
    final v = command.value;
    final Uint8List frame = switch (command.setting) {
      FridgeSetting.target || FridgeSetting.target2 => () {
        final zone = command.setting == FridgeSetting.target2 ? 2 : 1;
        if (zone == 2 && before.zone2 == null) {
          throw ArgumentError('This fridge has one zone');
        }
        final t = (v as num).round().clamp(before.minTemp, before.maxTemp);
        return alpicoolSetTarget(zone, t);
      }(),
      FridgeSetting.power => alpicoolFrame(
        AlpicoolCmd.set,
        before.settings(on: v as bool),
      ),
      FridgeSetting.eco => alpicoolFrame(
        AlpicoolCmd.set,
        before.settings(eco: v as bool),
      ),
      FridgeSetting.locked => alpicoolFrame(
        AlpicoolCmd.set,
        before.settings(locked: v as bool),
      ),
      FridgeSetting.batteryProtection => alpicoolFrame(
        AlpicoolCmd.set,
        before.settings(batteryProtection: (v as int).clamp(0, 2)),
      ),
      _ => throw ArgumentError('Unknown setting ${command.setting}'),
    };
    await link.send(frame);
    // Give the controller a moment to apply it before reading it back.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return alpicoolToDecoded(await link.query(), module: adv.name);
  }
}

/// The write characteristic plus a stream of whole frames from the notify
/// one, for the length of one session.
class _FridgeLink {
  final GattSession s;
  final GattChar tx;
  final Stream<Uint8List> frames;

  _FridgeLink(this.s, this.tx, this.frames);

  static Future<_FridgeLink> open(GattSession s) async {
    final tx = s.require(alpicoolWrite, 'Alpicool write');
    final rx = s.require(alpicoolNotify, 'Alpicool notify');
    final framer = AlpicoolFramer();
    final raw = await s.subscribe(rx);
    final frames = raw
        .expand(framer.add)
        .where(alpicoolValid)
        .asBroadcastStream();
    return _FridgeLink(s, tx, frames);
  }

  Future<void> send(Uint8List frame) => s.write(tx, frame);

  /// Asks for the status; a couple of tries, since the first query after
  /// connecting is sometimes not answered.
  Future<AlpicoolStatus> query() async {
    for (var attempt = 1; ; attempt++) {
      final reply = frames
          .map(parseAlpicoolStatus)
          .where((st) => st != null)
          .first
          .timeout(const Duration(seconds: 4));
      try {
        await send(alpicoolQuery());
      } catch (_) {
        reply.ignore();
        rethrow;
      }
      try {
        return (await reply)!;
      } on TimeoutException {
        if (attempt == 3) rethrow;
      }
    }
  }
}
