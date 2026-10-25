// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Ective LiPower BMS. Modbus over BLE with a device ID that varies.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class LipowerBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'lipower_bms',
    info: {'manufacturer': 'Ective', 'model': 'LiPower BMS'},
    matchers: [MatcherPattern(serviceUuid: 'af30')],
    create: LipowerBms.new,
  );

  static const _devIds = [0x22, 0x0B, 0x08, 0x38];
  static const _minLen = 5;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 15, 2, false, (x) => x / 10),
    // upstream: (x & 0xFFFF) * -(1 ** (x >> 16)) / 100
    BmsDp('current', 12, 3, false, (x) => (x & 0xFFFF) * -1 / 100),
    BmsDp('battery_level', 5, 2, false),
    BmsDp(
      'runtime',
      7,
      4,
      false,
      (x) => (x >> 16) * BaseBms.hrsToSecs + (x & 0xFFFF) * 60,
    ),
    BmsDp('cycle_charge', 3, 2, false),
  ];

  List<int> _heads = _devIds;
  Uint8List _msg = Uint8List(0);

  LipowerBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe1';
  @override
  String get uuidTx => 'ffe1';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.isEmpty || !_heads.contains(data[0]) || data.length < _minLen) {
      return;
    }
    if (data.length != data[2] + _minLen) return;
    if (!checkIntegrity(data, crcModbus, (null, -2), (-2, null), little: true)) {
      return;
    }
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    var found = false;
    for (final head in _heads) {
      try {
        await awaitMsg(BaseBms.cmdModbus(devId: head, addr: 0x400, count: 0x8));
        if (_heads.length > 1) _heads = [head]; // stick to the one that answered
        found = true;
        break;
      } on TimeoutException {
        // try the next device ID
      }
    }
    if (!found) throw TimeoutException('no answer');
    return BaseBms.decodeData(_fields, _msg);
  }
}
