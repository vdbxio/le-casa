// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Connects to a Daly smart BMS module, works out which protocol generation
// it speaks, and reads one status snapshot. See daly_protocol.dart for the
// frame layouts.

import 'dart:async';
import 'dart:typed_data';

import '../ble/gatt_session.dart';
import '../decoders/daly.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'daly_protocol.dart';
import 'driver.dart';

class DalyDriver implements GattDriver {
  static const serviceUuid = 'fff0';
  static const notifyUuid = 'fff1';
  static const writeUuid = 'fff2';

  /// How long to wait for a module to answer one request. The first answer
  /// after connecting can be slow; later ones arrive within ~200 ms.
  static const replyTimeout = Duration(seconds: 3);

  const DalyDriver();

  @override
  String get name => 'Daly BMS';

  @override
  Duration get interval => const Duration(seconds: 30);

  @override
  Duration get timeout => const Duration(seconds: 25);

  @override
  bool matches(RawAdvertisement adv) => const DalyDecoder().matches(adv);

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async {
    final rx = s.require(notifyUuid, 'Daly notify');
    final tx = s.require(writeUuid, 'Daly write');
    // Fire the status request before subscribing. On the tablet the link to
    // the module has been seen to die a few seconds after connecting, so
    // every millisecond before the first request counts; if the module
    // answers before notifications are on, the reply is simply repeated
    // by the exchange below.
    await s.write(
      tx,
      dalyReadRequest(DalyProtocol.d2, 0x0000, 62),
      withResponse: false,
    );
    final notifications = await s.subscribe(rx);

    // Auto-detect: newer modules answer 0xD2, older ones 0x81. Whichever
    // replies first wins; a module ignores requests in the other dialect.
    final d2 = await _exchange(
      s,
      tx,
      notifications,
      DalyProtocol.d2,
      dalyReadRequest(DalyProtocol.d2, 0x0000, 62),
    );
    if (d2 != null) {
      var status = parseDalyD2Status(d2);
      if (status == null) {
        throw FormatException('Unexpected Daly status frame (${d2.length} B)');
      }
      if (status.mosTemperature == null) {
        // Separate MOS register block; not every module has it, so a
        // missing answer is fine.
        final mos = await _exchange(
          s,
          tx,
          notifications,
          DalyProtocol.d2,
          dalyReadRequest(DalyProtocol.d2, 0x003E, 9),
          timeout: const Duration(milliseconds: 1500),
        );
        final t = mos == null ? null : parseDalyD2MosTemperature(mos);
        if (t != null) status = _withMos(status, t);
      }
      return status.toDecoded(adv.name ?? adv.id);
    }

    final cells = await _exchange(
      s,
      tx,
      notifications,
      DalyProtocol.p81,
      dalyReadRequest(DalyProtocol.p81, 0x0000, 64),
    );
    if (cells == null) {
      throw TimeoutException('Daly module did not answer (tried D2 and 0x81)');
    }
    final extra = await _exchange(
      s,
      tx,
      notifications,
      DalyProtocol.p81,
      dalyReadRequest(DalyProtocol.p81, 0x0041, 62),
    );
    final status = parseDalyP81Status(cells, extra);
    if (status == null) {
      throw FormatException('Unexpected Daly 0x81 frame (${cells.length} B)');
    }
    return status.toDecoded(adv.name ?? adv.id);
  }

  /// Sends one request and reassembles the matching response, or returns
  /// null on timeout.
  Future<Uint8List?> _exchange(
    GattSession s,
    GattChar tx,
    Stream<Uint8List> rx,
    DalyProtocol p,
    Uint8List request, {
    Duration timeout = replyTimeout,
  }) async {
    final asm = DalyFrameAssembler(p);
    final done = Completer<Uint8List?>();
    final sub = rx.listen((chunk) {
      final f = asm.add(chunk);
      if (f != null && !done.isCompleted) done.complete(f);
    });
    try {
      // Both community drivers write without response; the module's UART
      // bridge does not like ATT write requests.
      await s.write(tx, request, withResponse: false);
      return await done.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  static DalyStatus _withMos(DalyStatus s, double t) => DalyStatus(
    protocol: s.protocol,
    voltage: s.voltage,
    current: s.current,
    soc: s.soc,
    cellVoltages: s.cellVoltages,
    temperatures: s.temperatures,
    remainingAh: s.remainingAh,
    cycles: s.cycles,
    chargeState: s.chargeState,
    balancing: s.balancing,
    chargeMos: s.chargeMos,
    dischargeMos: s.dischargeMos,
    mosTemperature: t,
    alarmBits: s.alarmBits,
  );
}
