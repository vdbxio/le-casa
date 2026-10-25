// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// PowerXtreme smart BMS: Topband frames plus a small control protocol.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';
import 'topband.dart';

class PwrxtremeBms extends TopbandBms {
  static const spec = BmsSpec(
    module: 'pwrxtreme_bms',
    info: {'manufacturer': 'PowerXtreme', 'model': 'smart BMS'},
    matchers: [MatcherPattern(serviceUuid: 'fff0', manufacturerId: 76)],
    create: PwrxtremeBms.new,
  );

  static final _fields = [
    for (final f in TopbandBms.topbandFields)
      f.key == 'current'
          ? BmsDp(f.key, f.pos, f.size, f.signed, (x) => x / 10, f.idx)
          : f,
  ];

  /// Upstream sends this every 3 s while connected. Le'Casa does not keep
  /// links open, so it is only used if a caller keeps one alive.
  static const aliveInterval = 3.0;

  List<int> _ctrlProto = const [];

  PwrxtremeBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<BmsDp> get fields => _fields;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'fff2';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    final bmsInfo = await super.fetchDeviceInfo();
    for (final (cmd, key) in [
      ('<M:SR>', 'serial_number'),
      ('<N:NA>', 'model'),
    ]) {
      try {
        _ctrlProto = ascii(cmd.substring(1, 2));
        await awaitMsg(ascii(cmd));
        final v = msg.sl(2);
        if (v.any((c) => c > 0x7F)) throw const FormatException('not ASCII');
        bmsInfo[key] = String.fromCharCodes(v);
      } on TimeoutException {
        // not answered
      } on FormatException {
        // not text
      } finally {
        _ctrlProto = const [];
        msgEvent.clear();
      }
    }
    return bmsInfo;
  }

  /// Keep-alive request.
  Future<void> alive() async {
    try {
      _ctrlProto = ascii('I');
      await awaitMsg(ascii('<I:WA>'));
      _ctrlProto = const [];
      msgEvent.clear();
    } on TimeoutException {
      // ignored, like upstream
    }
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (_ctrlProto.isNotEmpty) {
      if (data.length >= 3 &&
          data[0] == 0x3C &&
          data[data.length - 1] == 0x3E &&
          data[1] == _ctrlProto[0]) {
        msg = data.sl(1, -1);
        msgEvent.set();
      }
      return;
    }
    super.notificationHandler(sender, data);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(ascii('<B:ST>'), waitForNotify: false);
    await awaitMsg(ascii('<H:ST>'), waitForNotify: false);
    await waitEventFor(timeout);
    return BaseBms.decodeData(fields, msg, little: true)
      ..['cell_voltages'] = BaseBms.cellVoltages(
        msg,
        cells: TopbandBms.maxCells,
        start: 22,
        little: true,
      );
  }
}
