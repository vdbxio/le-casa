// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Saihang Technology intelligent BMS. Modbus after a two byte header.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class SaihangBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'saihang_bms',
    info: {'manufacturer': 'Saihang Technology', 'model': 'intelligent BMS'},
    matchers: [MatcherPattern(localName: 'SH*', serviceUuid: 'fffa')],
    create: SaihangBms.new,
  );

  static const _head = [0xA5, 0xA5];
  static const _minFrameLen = 7;
  static const _maxTemp = 10;
  static const _maxCells = 20;
  static final _fields = <BmsDp>[
    BmsDp('current', 5, 4, true, (x) => x / 100),
    BmsDp('voltage', 9, 4, false, (x) => x / 100),
    BmsDp('battery_level', 13, 2, false),
    BmsDp('battery_health', 15, 2, false),
    BmsDp('cycle_charge', 17, 4, false, (x) => x / 100),
    BmsDp('design_capacity', 25, 4, false, (x) => x ~/ 100),
    BmsDp('cycles', 29, 2, false),
    BmsDp('problem_code', 31, 2, false, (x) => ~x & 0xFFFF),
    BmsDp('chrg_mosfet', 37, 2, false, (x) => x & 0x0200 != 0),
    BmsDp('dischrg_mosfet', 37, 2, false, (x) => x & 0x0400 != 0),
    BmsDp('balancer', 41, 2, false),
    BmsDp('cell_count', 43, 2, false, (x) => x < _maxCells ? x : _maxCells),
    BmsDp('temp_sensors', 85, 2, false, (x) => x < _maxTemp ? x : _maxTemp),
  ];

  Uint8List _msg = Uint8List(0);

  SaihangBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFFA)];
  @override
  String get uuidRx => 'fffc';
  @override
  String get uuidTx => 'fffb';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (!data.startsWithBytes(_head)) return;
    if (data.length < _minFrameLen || data.length != _minFrameLen + data[4]) {
      return;
    }
    if (!checkIntegrity(data, crcModbus, (2, -2), (-2, null), little: true)) {
      return;
    }
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg([..._head, ...BaseBms.cmdModbus(count: 0x48)]);
    final result = BaseBms.decodeData(_fields, _msg);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: (result['cell_count'] as int?) ?? 0,
      start: 45,
    );
    final n = (result['temp_sensors'] as int?) ?? 0;
    final temps = [
      ...BaseBms.tempValues(
        _msg,
        values: n,
        start: 87,
        offset: 2730,
        divider: 10,
        types: List.filled(n < 0 ? 0 : n, TempType.cell),
      ),
      ...BaseBms.tempValues(
        _msg,
        values: 2,
        start: 107,
        offset: 2730,
        divider: 10,
        types: const [TempType.mosfet, TempType.ambient],
      ),
    ];
    result['temp_values'] = temps;
    result['temp_sensors'] = temps.length;
    return result;
  }
}
