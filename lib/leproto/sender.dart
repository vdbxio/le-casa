// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Sends Le'Proto commands as adverts: no connection, so every Le'LED in
// range hears it at once and the light's next state advert is the ack.

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../drivers/driver.dart';
import 'leled.dart';
import 'leproto.dart';

/// Puts [ad] on air while [hold] runs, in place of whatever this screen
/// advertises (a phone or tablet has one advert), then puts that back.
typedef AdvertBorrower = Future<void> Function(
  Advertisement ad,
  Future<void> Function() hold,
);

/// The (opcode, arg 0, arg 1) for a card's command, or throws
/// [ArgumentError] for a setting Le'LED does not have.
(int, int, int) lepCommandFor(DeviceCommand c, LeLedState? now) {
  final v = c.value;
  switch (c.setting) {
    case 'on' when v is bool:
      return (LepOp.power, v ? 1 : 0, 0);
    case 'brightness' when v is num:
      // 0 would turn WLED off; that is what the switch is for.
      return (LepOp.brightness, (v * 255 / 100).round().clamp(1, 255), 0);
    case 'colour' when v is String:
      final h = v.replaceFirst('#', '');
      final rgb = int.parse(h, radix: 16);
      final c565 = rgbTo565(rgb >> 16 & 0xFF, rgb >> 8 & 0xFF, rgb & 0xFF);
      return (LepOp.color, c565 & 0xFF, c565 >> 8);
    case 'effect' when v is int:
      final sx = now?.sx ?? 0;
      return (LepOp.effect, v, sx == 0 ? 128 : sx);
    case 'preset' when v is int:
      return (LepOp.preset, v, 0);
  }
  throw ArgumentError('Le\'LED has no setting ${c.setting}');
}

/// The sequence number for the next command from [slot] to [dst]. It must
/// climb: the light refuses anything at or below the last one it took.
/// Seconds since 2026-11-01 give a floor, so a reinstalled app or another
/// screen on the same slot still climbs; 24 bits of seconds last until
/// mid-2027, by when the replay window will be persisted (and reset).
int lepNextSeq(int stored, DateTime now) {
  final floor =
      now.toUtc().difference(DateTime.utc(2026, 11)).inSeconds & 0xFFFFFF;
  final next = stored + 1 > floor ? stored + 1 : floor;
  return next & 0xFFFFFF;
}

class LeProtoSender {
  final AdvertBorrower borrow;

  /// This screen's source slot (0-3). The bench tool uses 3.
  final int slot;

  /// How long to wait for the light's ack before giving up. The light
  /// keeps bursting while it hears the frame, but a cheap tablet (the M10)
  /// can take a few seconds to catch one of its packets.
  final Duration ackWait;

  /// Whether this screen holds a sync link now. A cheap tablet hears few
  /// adverts while it does, so the wait runs on (up to [ackWaitBusy]) until
  /// the link closes and scanning picks up again.
  final bool Function()? linkBusy;
  final Duration ackWaitBusy;

  LeProtoSender(
    this.borrow, {
    int? slot,
    this.ackWait = const Duration(seconds: 5),
    this.linkBusy,
    this.ackWaitBusy = const Duration(seconds: 15),
  }) : slot = slot ?? _platformSlot();

  static int _platformSlot() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 0,
    TargetPlatform.iOS => 1,
    _ => 2,
  };

  /// Whether [id] is a Le'LED this screen holds the key for.
  bool handles(String id) => LeLedKeys.keyOf(id) != null;

  Future<void> _queue = Future.value();

  Future<void> send(String id, DeviceCommand command) {
    final done = _queue.then((_) => _send(id, command));
    _queue = done.catchError((_) {});
    return done;
  }

  Future<void> _send(String id, DeviceCommand command) async {
    final key = LeLedKeys.keyOf(id);
    if (key == null) throw StateError('No key for this light');
    final (op, a0, a1) = lepCommandFor(command, LeLedKeys.stateOf(id));
    final k = LepKeys(key);
    final prefs = await SharedPreferences.getInstance();
    final seqKey = 'leproto:seq:${k.dstHex}:$slot';
    final seq = lepNextSeq(prefs.getInt(seqKey) ?? 0, DateTime.now());
    await prefs.setInt(seqKey, seq);
    final frame = lepSeal(k, slot, seq, op, a0, a1);
    final apple =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final ad = apple
        ? Advertisement(serviceUUIDs: [UUID.fromString(lepUuid(frame))])
        : Advertisement(
            manufacturerSpecificData: [
              ManufacturerSpecificData(id: leProtoCompanyId, data: frame),
            ],
          );
    debugPrint('leproto: $id $command seq $seq');
    var acked = false;
    final sentAt = DateTime.now();
    await borrow(ad, () async {
      final start = DateTime.now();
      final most = start.add(ackWaitBusy);
      var until = start.add(ackWait);
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (LeLedKeys.stateOf(id)?.acks(slot, seq) ?? false) {
          acked = true;
          return;
        }
        if ((linkBusy?.call() ?? false) && until.isBefore(most)) {
          final more = DateTime.now().add(const Duration(seconds: 1));
          if (more.isAfter(until)) until = more.isAfter(most) ? most : more;
        }
      }
    });
    debugPrint(
      'leproto: seq $seq ${acked ? 'acked' : 'no ack'} after '
      '${DateTime.now().difference(sentAt).inMilliseconds} ms',
    );
    if (!acked) {
      throw TimeoutException("The light didn't answer. Is it in range?");
    }
  }
}

/// For tests: a frame built the way [LeProtoSender] builds it.
@visibleForTesting
Uint8List lepFrameFor(Uint8List key, int slot, int seq, DeviceCommand c) {
  final (op, a0, a1) = lepCommandFor(c, null);
  return lepSeal(LepKeys(key), slot, seq, op, a0, a1);
}
