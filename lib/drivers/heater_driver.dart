// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Reads and controls diesel heaters with the BYD- module. Like the fridge,
// every change is followed by a fresh status read, so the card shows what
// the heater accepted rather than what we asked for.

import 'dart:async';
import 'dart:typed_data';

import '../ble/gatt_session.dart';
import '../decoders/appliances.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'driver.dart';
import 'heater_protocol.dart';

/// Setting names [HeaterDriver.control] understands.
abstract final class HeaterSetting {
  static const power = 'power'; // bool
  static const mode = 'mode'; // 'Level' or 'Temperature'
  static const level = 'level'; // int 1..10
  static const target = 'target'; // int, °C
}

const heaterModeNames = {
  HeaterMode.manual: 'Manual',
  HeaterMode.level: 'Level',
  HeaterMode.temperature: 'Temperature',
};

Decoded heaterToDecoded(HeaterStatus s, {String? module}) {
  final u = s.unit;
  return Decoded(
    protocol: 'Hcalory',
    kind: DeviceKind.appliance,
    model: 'Diesel heater',
    readings: [
      Reading('temperature', s.cabinTemp, u),
      Reading(HeaterSetting.power, s.on),
      Reading('state', s.errorName ?? s.stepName),
      Reading(HeaterSetting.mode, heaterModeNames[s.mode] ?? 'Mode ${s.mode}'),
      Reading(HeaterSetting.level, s.level),
      Reading(HeaterSetting.target, s.target, u),
      Reading('heater temperature', s.caseTemp, u),
      Reading('supply voltage', s.voltage, 'V'),
      Reading('fault', s.errorName),
      if (s.coPpm case final co?) Reading('carbon monoxide', co, 'ppm'),
    ],
    info: {'module': ?module, 'layout': s.layout},
  );
}

class HeaterDriver implements ControllableDriver {
  const HeaterDriver();

  @override
  String get name => 'Diesel heater';

  @override
  Duration get interval => const Duration(seconds: 30);

  @override
  Duration get timeout => const Duration(seconds: 20);

  @override
  bool matches(RawAdvertisement adv) => const HcaloryDecoder().matches(adv);

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async {
    final link = await _HeaterLink.open(s);
    return heaterToDecoded(await link.query(), module: adv.name);
  }

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand command,
  ) async {
    final link = await _HeaterLink.open(s);
    final before = await link.query();
    final v = command.value;
    switch (command.setting) {
      case HeaterSetting.power:
        await link.send(HeaterCmd.power, v as bool ? 1 : 0);
      case HeaterSetting.mode:
        final mode = v == 'Temperature'
            ? HeaterMode.temperature
            : HeaterMode.level;
        await link.send(HeaterCmd.mode, mode);
      case HeaterSetting.level || HeaterSetting.target:
        // One command sets either, read by the heater per its mode, so
        // switch the mode first when it is the other one.
        final want = command.setting == HeaterSetting.level
            ? HeaterMode.level
            : HeaterMode.temperature;
        if (before.mode != want) {
          await link.send(HeaterCmd.mode, want);
          await _settle();
        }
        final n = (v as num).round();
        await link.send(
          HeaterCmd.setValue,
          want == HeaterMode.level
              ? n.clamp(heaterMinLevel, heaterMaxLevel)
              : n.clamp(heaterMinTemp, heaterMaxTemp),
        );
      default:
        throw ArgumentError('Unknown setting ${command.setting}');
    }
    await _settle();
    return heaterToDecoded(await link.query(), module: adv.name);
  }

  /// Gives the controller a moment to apply a command before the next.
  static Future<void> _settle() =>
      Future<void>.delayed(const Duration(milliseconds: 500));
}

/// The heater's one characteristic and a stream of whole frames from it,
/// for the length of one session.
class _HeaterLink {
  final GattSession s;
  final GattChar char;
  final Stream<Uint8List> frames;

  _HeaterLink(this.s, this.char, this.frames);

  static Future<_HeaterLink> open(GattSession s) async {
    final c = s.require(heaterChar, 'heater');
    final framer = HeaterFramer();
    final raw = await s.subscribe(c);
    return _HeaterLink(s, c, raw.expand(framer.add).asBroadcastStream());
  }

  Future<void> send(int cmd, int arg) =>
      s.write(char, heaterCommand(cmd, arg), withResponse: false);

  /// Asks for the status. Most heaters also push it every second or so
  /// once a command has arrived, so any status frame will do.
  Future<HeaterStatus> query() async {
    for (var attempt = 1; ; attempt++) {
      final reply = frames
          .map(parseHeaterStatus)
          .where((st) => st != null)
          .first
          .timeout(const Duration(seconds: 4));
      try {
        await send(HeaterCmd.status, 0);
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
