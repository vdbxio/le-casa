// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// EG4 electronics LL batteries: Modbus over a 0x1000 service.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class Eg4Bms extends BaseBms {
  static final spec = BmsSpec(
    module: 'eg4_bms',
    info: const {'manufacturer': 'EG4 electronics', 'model': 'LL'},
    matchers: const [
      MatcherPattern(
        serviceUuid: '1000',
        manufacturerId: 0x6F80,
        manufacturerDataStart: [0xB0],
      ),
      MatcherPattern(manufacturerId: 0x45CC, manufacturerDataStart: [0xA5]),
    ],
    create: Eg4Bms.new,
  );

  static const _head = [0x01, 0x03];
  static const _maxCells = 16;
  static const _maxTemp = 6;
  static const _minLen = 5;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 3, 2, false, (x) => x / 100),
    BmsDp('current', 5, 2, true, (x) => x / 10),
    BmsDp('battery_health', 49, 2, false),
    BmsDp('battery_level', 51, 2, false),
    BmsDp('cycle_charge', 45, 2, false, (x) => x / 10),
    BmsDp('cycles', 61, 4, false),
    BmsDp('cell_count', 75, 2, false),
    BmsDp('design_capacity', 77, 2, false, (x) => x ~/ 10),
    BmsDp('temperature', 39, 2, true),
    BmsDp('problem_code', 55, 6, false),
    BmsDp('balancer', 79, 2, false),
  ];
  static const _optFields = ['cycle_charge', 'cycles', 'design_capacity'];

  Uint8List _msg = Uint8List(0);
  int _expLen = 0;

  Eg4Bms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0x1000)];
  @override
  String get uuidRx => '1002';
  @override
  String get uuidTx => '1001';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length > _minLen &&
        data.startsWithBytes(_head) &&
        frame.length >= _expLen) {
      _expLen = _minLen + data[2];
      frame.clear();
    }
    frame.extend(data);
    if (frame.length < _expLen) return;
    frame.del(_expLen);
    if (!checkIntegrity(
      frame,
      crcModbus,
      (null, -2),
      (-2, null),
      little: true,
    )) {
      return;
    }
    _msg = frame.bytes;
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(BaseBms.cmdModbus(devId: 0x1, addr: 0x0, count: 0x27));
    final result = BaseBms.decodeData(_fields, _msg);
    for (final f in _optFields) {
      final v = result[f];
      if (v == null || v == 0) result.remove(f);
    }
    final cells = (result['cell_count'] as int?) ?? 0;
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: cells < _maxCells ? cells : _maxCells,
      start: 7,
    );
    result['temp_values'] = [
      ...BaseBms.tempValues(
        _msg,
        values: 1,
        start: 39,
        types: const [TempType.pcb],
      ),
      ...BaseBms.tempValues(
        _msg,
        values: _maxTemp,
        start: 69,
        size: 1,
        types: List.filled(_maxTemp, TempType.cell),
      ),
    ];
    return result;
  }
}
