// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Reads and controls diesel heaters: Hcalory's own MVP2 module, and the
// BYD- module of Vevor-style heaters. Like the fridge, every change is
// followed by a fresh status read, so the card shows what the heater
// accepted rather than what we asked for.

import 'dart:async';
import 'dart:typed_data';

import '../ble/gatt_session.dart';
import '../decoders/appliances.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'driver.dart';
import 'hcalory_protocol.dart';
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
  HeaterMode.fan: 'Fan only',
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
    info: {
      'module': ?module,
      'layout': s.layout,
      'target range': '${s.minTarget} to ${s.maxTarget} $u',
    },
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
        await link.power(v as bool);
      case HeaterSetting.mode:
        await link.mode(
          v == 'Temperature' ? HeaterMode.temperature : HeaterMode.level,
        );
      case HeaterSetting.level || HeaterSetting.target:
        final want = command.setting == HeaterSetting.level
            ? HeaterMode.level
            : HeaterMode.temperature;
        if (before.mode != want) {
          await link.mode(want);
          await _settle();
        }
        final n = (v as num).round();
        if (want == HeaterMode.level) {
          await link.level(n.clamp(heaterMinLevel, heaterMaxLevel));
        } else {
          await link.target(
            n.clamp(before.minTarget, before.maxTarget),
            before.fahrenheit,
          );
        }
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

/// One session's way of talking to the heater, for either module.
abstract class _HeaterLink {
  static Future<_HeaterLink> open(GattSession s) async {
    if (s.find(hcaloryWrite) case final w?) {
      final link = _HcaloryLink(
        s,
        w,
        await _frames(
          s,
          s.require(hcaloryNotify, 'heater notify'),
          HcaloryFramer().add,
        ),
      );
      await link.unlock();
      return link;
    }
    final c = s.require(heaterChar, 'heater');
    return _BydLink(s, c, await _frames(s, c, HeaterFramer().add));
  }

  static Future<Stream<Uint8List>> _frames(
    GattSession s,
    GattChar c,
    List<Uint8List> Function(List<int>) framer,
  ) async => (await s.subscribe(c)).expand(framer).asBroadcastStream();

  Stream<Uint8List> get frames;
  HeaterStatus? parse(Uint8List f);
  Future<void> askStatus();
  Future<void> power(bool on);
  Future<void> mode(int mode);
  Future<void> level(int level);
  Future<void> target(int target, bool fahrenheit);

  /// Asks for the status. The heaters also push it every second or so,
  /// so any status frame will do.
  Future<HeaterStatus> query() async {
    for (var attempt = 1; ; attempt++) {
      final reply = frames
          .map(parse)
          .where((st) => st != null)
          .first
          .timeout(const Duration(seconds: 4));
      try {
        await askStatus();
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

class _BydLink extends _HeaterLink {
  final GattSession s;
  final GattChar char;
  @override
  final Stream<Uint8List> frames;

  _BydLink(this.s, this.char, this.frames);

  Future<void> _send(int cmd, int arg) =>
      s.write(char, heaterCommand(cmd, arg), withResponse: false);

  @override
  HeaterStatus? parse(Uint8List f) => parseHeaterStatus(f);
  @override
  Future<void> askStatus() => _send(HeaterCmd.status, 0);
  @override
  Future<void> power(bool on) => _send(HeaterCmd.power, on ? 1 : 0);
  @override
  Future<void> mode(int mode) => _send(HeaterCmd.mode, mode);
  @override
  Future<void> level(int level) => _send(HeaterCmd.setValue, level);
  @override
  Future<void> target(int target, bool fahrenheit) =>
      _send(HeaterCmd.setValue, target);
}

class _HcaloryLink extends _HeaterLink {
  final GattSession s;
  final GattChar tx;
  @override
  final Stream<Uint8List> frames;

  _HcaloryLink(this.s, this.tx, this.frames);

  Future<void> _send(Uint8List f) => s.write(tx, f, withResponse: false);

  /// Sends the PIN; nothing else is answered until it is accepted.
  Future<void> unlock() async {
    for (final pin in hcaloryPins) {
      final reply = frames
          .map(hcaloryPinAccepted)
          .where((ok) => ok != null)
          .first
          .timeout(const Duration(seconds: 3));
      await _send(hcaloryPin(pin));
      try {
        if (await reply == true) return;
      } on TimeoutException {
        // try the next one
      }
    }
    throw StateError(
      'The heater refused its PIN (tried ${hcaloryPins.join(' and ')})',
    );
  }

  @override
  HeaterStatus? parse(Uint8List f) => parseHcaloryStatus(f);
  @override
  Future<void> askStatus() => _send(hcaloryPress(HcaloryButton.query));
  @override
  Future<void> power(bool on) =>
      _send(hcaloryPress(on ? HcaloryButton.on : HcaloryButton.off));
  @override
  Future<void> mode(int mode) => _send(
    hcaloryPress(
      mode == HeaterMode.temperature
          ? HcaloryButton.thermostat
          : HcaloryButton.level,
    ),
  );
  @override
  Future<void> level(int level) => _send(hcaloryLevel(level));
  @override
  Future<void> target(int target, bool fahrenheit) =>
      _send(hcaloryTarget(target, fahrenheit: fahrenheit));
}
