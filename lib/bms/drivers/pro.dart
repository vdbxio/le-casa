// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Pro BMS Smart Shunt. Streams data once started.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class ProBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'pro_bms',
    info: {'manufacturer': 'Pro BMS', 'model': 'Smart Shunt'},
    matchers: [MatcherPattern(localName: 'Pro BMS', serviceUuid: 'fff0')],
    create: ProBms.new,
  );

  static const _head = [0x55, 0xAA];
  static const _minLen = 5;
  static const _initResp = 0x03;
  static const _rtData = 0x04;
  static const _cmdInit = [0x0A, 0x01, 0x01, 0x55, 0x80, 0x04, 0x07, 0x7F, 0x64, 0x8E, 0x68, 0x2B];
  static const _cmdHwid = [0x07, 0x01, 0x01, 0x55, 0x80, 0x40, 0x00, 0x00, 0x95];
  static const _cmdDataStream = [0x07, 0x01, 0x01, 0x55, 0x80, 0x42, 0x00, 0x00, 0x97];
  // starts the data stream (function 0x43)
  static const _cmdTriggerData = [0x09, 0x01, 0x01, 0x55, 0x80, 0x43, 0x00, 0x00, 0x12, 0x00, 0x84];

  static final _fields = <BmsDp>[
    BmsDp('voltage', 8, 2, false, (x) => x / 100),
    BmsDp(
      'current',
      12,
      4,
      false,
      (x) => ((x & 0xFFFF) / 1000) * ((x >> 24) & 0x80 != 0 ? -1 : 1),
    ),
    BmsDp('problem_code', 15, 4, false, (x) => x & 0x7F),
    BmsDp(
      'temp_values',
      16,
      3,
      false,
      (x) => [TempSensor(((x & 0xFFFF) / 10) * (x >> 16 != 0 ? -1 : 1))],
    ),
    BmsDp('cycle_charge', 20, 4, false, (x) => x / 100),
    BmsDp('battery_level', 24, 1, false),
    BmsDp('power', 32, 4, false, (x) => x / 100),
  ];

  int _validReply = _rtData;
  Uint8List _msg = Uint8List(0);

  ProBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff4';
  @override
  String get uuidTx => 'fff3';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length < _minLen || !data.startsWithBytes(_head)) return;
    if (data[3] != _validReply) return;
    if (data.length != data[2] + _minLen) return;
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection();
    _validReply = _initResp;
    await awaitMsg([..._head, ..._cmdInit]);
    for (final cmd in [_cmdHwid, _cmdDataStream, _cmdTriggerData]) {
      await awaitMsg([..._head, ...cmd], waitForNotify: false);
    }
    _validReply = _rtData;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    try {
      await waitEventFor(timeout);
    } on TimeoutException {
      await disconnect();
      rethrow;
    }
    final result = BaseBms.decodeData(_fields, _msg, little: true);
    final current = (result['current'] as num?) ?? 0;
    result['power'] = ((result['power'] as num?) ?? 0) * (current < 0 ? -1 : 1);
    msgEvent.clear();
    frame.clear();
    return result;
  }
}
