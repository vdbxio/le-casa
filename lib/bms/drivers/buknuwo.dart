// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Buknuwo smart batteries (CDZG, MEY): Modbus over a custom service.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class BuknuwoBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'buknuwo_bms',
    info: const {'manufacturer': 'Buknuwo', 'model': 'smart battery'},
    matchers: const [
      MatcherPattern(localName: 'CDZG*'),
      MatcherPattern(localName: 'MEY-?????-*'),
    ],
    create: BuknuwoBms.new,
  );

  static const _head = [0x01, 0x03];
  static const _minLen = 5;
  static const _maxTemp = 10;
  static const _prbMask = 0xFF3FFF7F007F;
  static final _fields = <BmsDp>[
    BmsDp('current', 3, 2, true, (x) => x / 100),
    BmsDp('voltage', 5, 2, false, (x) => x / 100),
    BmsDp('battery_level', 7, 2, false),
    BmsDp('battery_health', 9, 2, false),
    BmsDp('cycle_charge', 11, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 15, 2, false, (x) => x ~/ 100),
    BmsDp('cycles', 17, 2, false),
    BmsDp('chrg_mosfet', 25, 1, false, (x) => x & 0x4 != 0),
    BmsDp('dischrg_mosfet', 25, 1, false, (x) => x & 0x8 != 0),
    BmsDp('problem_code', 21, 6, false, (x) => x & _prbMask),
  ];

  int _expLen = 0;
  Uint8List _msg = Uint8List(0);

  BuknuwoBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['00002760-08c2-11e1-9073-0e8ac72e1001'];
  @override
  String get uuidRx => '00002760-08c2-11e1-9073-0e8ac72e0002';
  @override
  String get uuidTx => '00002760-08c2-11e1-9073-0e8ac72e0001';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length > _minLen &&
        data.startsWithBytes(_head) &&
        frame.length >= _expLen) {
      _expLen = _minLen + data[2];
      frame.clear();
    }
    frame.extend(data);
    if (frame.length < 3 || frame.length < frame[2] + _minLen) return;
    if (!checkIntegrity(frame, crcModbus, (null, -2), (-2, null), little: true)) {
      return;
    }
    _msg = frame.bytes;
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(BaseBms.cmdModbus(devId: 0x1, addr: 0x0, count: 0xD));
    final result = BaseBms.decodeData(_fields, _msg);

    await awaitMsg(BaseBms.cmdModbus(devId: 0x1, addr: 0x39, count: 0x1));
    final temps = BaseBms.tempValues(
      _msg,
      start: 3,
      divider: 10,
      types: const [TempType.mosfet],
    );

    await awaitMsg(
      BaseBms.cmdModbus(devId: 0x1, addr: 0x2E, count: _maxTemp + 1),
    );
    final n = _msg.u(3, 2);
    result['temp_sensors'] = n;
    temps.addAll(
      BaseBms.tempValues(
        _msg,
        values: n,
        start: 5,
        divider: 10,
        types: List.filled(n, TempType.cell),
      ),
    );
    result['temp_values'] = temps;
    return result;
  }
}
