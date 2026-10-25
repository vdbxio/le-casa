// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// ANT legacy smart BMS ("ANT-BLE0..", "ANT-BLE1..", "ANT-BLE22..").

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';
import 'ant.dart';

class AntLegBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'ant_leg_bms',
    info: const {'manufacturer': 'ANT', 'model': 'legacy smart BMS'},
    matchers: [
      for (final p in ['ANT-BLE[01]*', 'ANT-BLE22*'])
        MatcherPattern(localName: p, serviceUuid: 'ffe0'),
    ],
    create: AntLegBms.new,
  );

  static const _cmdGet = 0xDB;
  static const _adrStatus = 0x00;
  static const _rxHeaderRspStat = [0xAA, 0x55, 0xAA, 0xFF];
  static const _rspStatLen = 140;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 4, 2, false, (x) => x / 10),
    BmsDp('current', 70, 4, true, (x) => x / -10),
    BmsDp('battery_level', 74, 1, false),
    BmsDp('design_capacity', 75, 4, false, (x) => x ~/ 1000000),
    BmsDp('cycle_charge', 79, 4, false, (x) => x / 1e6),
    BmsDp('total_charge', 83, 4, false, (x) => x ~/ 1000),
    BmsDp('runtime', 87, 4, false),
    BmsDp('cell_count', 123, 1, false),
    BmsDp('problem_code', 103, 2, false, antProblemCode),
    BmsDp('chrg_mosfet', 103, 1, false, (x) => x == 0x1),
    BmsDp('dischrg_mosfet', 104, 1, false, (x) => x == 0x1),
    BmsDp('balancer', 105, 1, false, (x) => x & 0x4 != 0),
  ];

  Uint8List _msg = Uint8List(0);

  AntLegBms(super.device, [super.config]);

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
    if (data.startsWithBytes(_rxHeaderRspStat)) {
      frame.clear();
    } else if (frame.isEmpty) {
      return;
    }
    frame.extend(data);
    final n = frame.length;
    if (n < _rspStatLen) return;
    if (n > _rspStatLen) {
      frame.clear();
      return;
    }
    if (!checkIntegrity(
      frame,
      (x) => crcSum(x.sl(4, -2), 2),
      (null, null),
      (-2, null),
    )) {
      frame.clear();
      return;
    }
    _msg = frame.bytes;
    frame.clear();
    msgEvent.set();
  }

  static Uint8List _cmd(int cmd, int adr, [int value = 0]) {
    final f = [cmd, cmd, adr, ...intTo(value, 2)];
    return Uint8List.fromList([...f, crcSum(f.sublist(2))]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(_cmd(_cmdGet, _adrStatus));
    final result = BaseBms.decodeData(_fields, _msg);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: (result['cell_count'] as int?) ?? 0,
      start: 6,
    );
    if ((result['design_capacity'] ?? 1) == 0) {
      // some BMSs always report 0 here; estimate it from charge and level
      result.remove('design_capacity');
      final level = (result['battery_level'] as num?) ?? 0;
      if (level != 0) {
        result['design_capacity'] = pyRound(
          ((result['cycle_charge'] as num?) ?? 0) / level * 100,
          -1,
        ).toInt();
      }
    }
    // 6 sensor slots, but only 4 seem to be connected by default
    result['temp_values'] = BaseBms.tempValues(_msg, values: 4, start: 91);
    return result;
  }
}
