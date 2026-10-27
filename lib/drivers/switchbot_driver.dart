// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Switches SwitchBot Plug Minis on and off. The plug broadcasts its state,
// so it is never polled; a connection is opened only for a command. The
// command service and the on/off frames come from sblibs/pySwitchbot
// (MIT), switchbot/devices/device.py and plug.py. The US and JP Plug Minis
// take plain commands; the EU one and the Relay Switches encrypt theirs
// with a key from the SwitchBot account, so they are not offered here.

import 'dart:async';
import 'dart:typed_data';

import '../ble/gatt_session.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import '../decoders/switchbot.dart';
import 'driver.dart';

const switchBotWrite = 'cba20002-224d-11e6-9fb8-0002a5d5c51b';
const switchBotNotify = 'cba20003-224d-11e6-9fb8-0002a5d5c51b';

/// Setting names [SwitchBotPlugDriver.control] understands.
abstract final class SwitchSetting {
  static const on = 'on'; // bool
}

Uint8List switchBotPlugCommand(bool on) =>
    Uint8List.fromList([0x57, 0x0F, 0x50, 0x01, 0x01, on ? 0x80 : 0x00]);

class SwitchBotPlugDriver implements ControllableDriver {
  const SwitchBotPlugDriver();

  @override
  String get name => 'SwitchBot Plug Mini';

  // Never polled: its broadcasts carry the state.
  @override
  Duration get interval => const Duration(hours: 1);

  @override
  Duration get timeout => const Duration(seconds: 20);

  @override
  bool matches(RawAdvertisement adv) {
    final d = adv.serviceData[switchBotServiceUuid];
    if (d == null || d.isEmpty) return false;
    // 'g' / 'G' Plug Mini (US), 'j' / 'J' Plug Mini (JP).
    return const {0x67, 0x47, 0x6A, 0x4A}.contains(d[0] & 0x7F);
  }

  @override
  Future<Decoded> read(GattSession session, RawAdvertisement adv) async {
    final out = SwitchBotDecoder().decode(adv);
    if (out == null) {
      throw const UnsupportedDeviceException('No Plug Mini broadcast yet');
    }
    return out;
  }

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand command,
  ) async {
    if (command.setting != SwitchSetting.on || command.value is! bool) {
      throw ArgumentError('Unknown setting ${command.setting}');
    }
    final want = command.value as bool;
    // Also accepted: 57 0f 51 01 asks for the state, 57 0f 50 01 02 80
    // toggles.
    final tx = s.require(switchBotWrite, 'SwitchBot command');
    final rx = s.require(switchBotNotify, 'SwitchBot reply');
    final replies = await s.subscribe(rx);
    Future<Uint8List> send() async {
      final reply = replies.first.timeout(const Duration(seconds: 5));
      try {
        await s.write(
          tx,
          switchBotPlugCommand(want),
          withResponse: tx.canWrite || !tx.canWriteWithoutResponse,
        );
      } catch (_) {
        reply.ignore();
        rethrow;
      }
      return reply;
    }

    // The plug answers 01 (done) and its new state: 80 on, 00 off.
    // Checked on Chloe's Plug Mini (US) from a Mac, 2026-10-27.
    var on = !want;
    for (var attempt = 1; attempt <= 2 && on != want; attempt++) {
      final r = await send();
      if (r.length < 2 || r[0] != 0x01) {
        throw StateError('The plug did not take the command');
      }
      on = r[1] & 0x80 != 0;
    }
    if (on != want) {
      throw StateError('The plug stayed ${on ? 'on' : 'off'}');
    }
    // The advert handed in may be one without the service data that names
    // the model; the next broadcast fills in the rest either way.
    final before = SwitchBotDecoder().decode(adv);
    return Decoded(
      protocol: 'SwitchBot',
      kind: DeviceKind.switches,
      model: before?.model ?? 'SwitchBot Plug Mini',
      readings: [
        for (final x in before?.readings ?? const <Reading>[])
          if (x.label != SwitchSetting.on) x,
        Reading(SwitchSetting.on, on),
      ],
      info: before?.info ?? const {},
    );
  }
}
