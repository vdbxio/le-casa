// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Pylontech RT series. Modbus over BLE.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class PylontechBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'pylontech_bms',
    info: {'manufacturer': 'Pylontech', 'model': 'RT series'},
    matchers: [
      MatcherPattern(localName: 'RT[1-4][2,4,6,8]*', serviceUuid: '180f'),
    ],
    create: PylontechBms.new,
  );

  static const _devId = 1;
  static const _regSn = (0x2000, 8);
  static const _infoBlock = (0x1016, 13); // 0x1016-0x1022
  static final _fields = <BmsDp>[
    BmsDp('voltage', 0, 2, false, (x) => x / 100),
    BmsDp('current', 2, 2, true, (x) => x / 10),
    BmsDp('battery_level', 12, 2, false),
    BmsDp('battery_health', 14, 2, false),
    BmsDp('power', 16, 2, false, (x) => x.toDouble()),
    BmsDp('design_capacity', 24, 2, false, (x) => x ~/ 10),
  ];

  Uint8List _msg = Uint8List(0);
  int _expLen = 0;

  PylontechBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['00010203-0405-0607-0809-0a0b0c0d1910'];
  @override
  String get uuidRx => '00010203-0405-0607-0809-0a0b0c0d2b10';
  @override
  String get uuidTx => '00010203-0405-0607-0809-0a0b0c0d2b11';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    frame.extend(data);
    if (frame.length >= 5 && frame.startsWithBytes(const [0x01, 0x03])) {
      _expLen = 3 + frame[2] + 2;
    } else {
      frame.clear();
      return;
    }
    if (_expLen == 0 || frame.length < _expLen) return;

    final f = frame.sl(0, _expLen);
    frame.clear();
    _expLen = 0;
    if (!checkIntegrity(f, crcModbus, (null, -2), (-2, null), little: true)) {
      return;
    }
    _msg = f;
    msgEvent.set();
  }

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    final info = await super.fetchDeviceInfo();
    try {
      await awaitMsg(
        BaseBms.cmdModbus(devId: _devId, addr: _regSn.$1, count: _regSn.$2),
      );
      final sn = b2str(_msg.sl(3, 3 + _regSn.$2 * 2));
      if (sn.isNotEmpty) info['serial_number'] = sn;
    } on TimeoutException {
      // no serial number
    }
    return info;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(
      BaseBms.cmdModbus(devId: _devId, addr: _infoBlock.$1, count: _infoBlock.$2),
    );
    final result = BaseBms.decodeData(_fields, _msg, start: 3);
    // Modbus only has the lowest and highest cell (0x1018, 0x1019)
    result['cell_voltages'] = BaseBms.cellVoltages(_msg, cells: 2, start: 7);
    result['temp_values'] = BaseBms.tempValues(
      _msg,
      values: 2,
      start: 11,
      divider: 10,
    );
    return result;
  }
}
