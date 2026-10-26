// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Redodo, LiTime, Starry Sea and some ECO-WORTHY batteries.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class RedodoBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'redodo_bms',
    info: const {'manufacturer': 'Redodo', 'model': 'Bluetooth battery'},
    matchers: [
      // the patterns keep "BT-ROCC2440" out
      for (final p in [
        'P-12*',
        'P-24*',
        'PQ-12*',
        'PQ-24*',
        'R-12*',
        'R-24*',
        'RO-12*',
        'RO-24*',
        'T-12*', // ECO-WORTHY
        'T-24*', // ECO-WORTHY
        'L-12*', // LiTime
        'L-24*',
        'L-51*',
        'LT-12???BG-A0[7-9]*', // LiTime, by serial number
        'LT-24???B-A00[3-9]*',
        'LT-24???B-A0[1-9]*',
        'LT-24???B-A[1-9]*',
        'LT-51*',
        'S-*', // Starry Sea by LiTime
        'SS-*', // Starry Sea
      ])
        MatcherPattern(
          localName: p,
          serviceUuid: 'ffe0',
          manufacturerId: 0x585A,
        ),
    ],
    create: RedodoBms.new,
  );

  static const _headLen = 3;
  static const _maxCells = 16;
  static const _maxTemp = 5;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 12, 2, false, (x) => x / 1000),
    BmsDp('current', 48, 4, true, (x) => x / 1000),
    BmsDp('battery_level', 90, 2, false),
    BmsDp('battery_health', 92, 4, false),
    BmsDp('cycle_charge', 62, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 64, 4, false, (x) => x ~/ 100),
    BmsDp('cycles', 96, 4, false),
    BmsDp('balancer', 84, 4, false),
    BmsDp('heater', 68, 4, false, (x) => x != 0),
    BmsDp('problem_code', 76, 8, false),
  ];

  int _tempSensors = 1;
  Uint8List _msg = Uint8List(0);

  RedodoBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe1';
  @override
  String get uuidTx => 'ffe2';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length < 3 || !data.startsWithBytes(const [0x00, 0x00])) return;
    if (data.length != data[2] + _headLen + 1) return; // header and CRC
    if (!checkIntegrity(data, crcSum, (null, -1), (-1, null))) return;
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(const [0x00, 0x00, 0x04, 0x01, 0x13, 0x55, 0xAA, 0x17]);
    final result = BaseBms.decodeData(_fields, _msg, little: true);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: _maxCells,
      start: 16,
      little: true,
    );
    final temps = BaseBms.tempValues(
      _msg,
      values: _maxTemp,
      start: 52,
      little: true,
    );
    // count higher-index sensors once they report something
    final n = temps.length < _maxTemp ? temps.length : _maxTemp;
    for (var i = n; i > 1; i--) {
      if (temps[i - 1].value != 0.0) {
        if (i > _tempSensors) _tempSensors = i;
        break;
      }
    }
    result['temp_values'] = temps.take(_tempSensors).toList();
    result['temp_sensors'] = _tempSensors;
    return result;
  }
}
