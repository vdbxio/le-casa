// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// TianPwr smart BMS.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class TianpwrBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'tianpwr_bms',
    info: {'manufacturer': 'TianPwr', 'model': 'smart BMS'},
    matchers: [MatcherPattern(localName: 'TP_*')],
    create: TianpwrBms.new,
  );

  static const _head = 0x55;
  static const _tail = 0xAA;
  static const _rdCmd = 0x04;
  static const _maxCells = 16;
  static const _maxTemp = 6;
  static const _defLen = 20;
  static final _fields = <BmsDp>[
    BmsDp('battery_level', 3, 2, false, (x) => x, 0x83),
    BmsDp('voltage', 5, 2, false, (x) => x / 100, 0x83),
    BmsDp('current', 13, 2, true, (x) => x / 100, 0x83),
    BmsDp('battery_health', 17, 2, false, (x) => x, 0x83),
    BmsDp('problem_code', 11, 8, false, (x) => x, 0x84),
    BmsDp('cell_count', 3, 1, false, (x) => x, 0x84),
    BmsDp('temp_sensors', 4, 1, false, (x) => x, 0x84),
    BmsDp('design_capacity', 5, 2, false, (x) => x ~/ 100, 0x84),
    BmsDp('cycle_charge', 7, 2, false, (x) => x / 100, 0x84),
    BmsDp('cycles', 9, 2, false, (x) => x, 0x84),
    BmsDp('balancer', 13, 2, false, (x) => x, 0x85),
    BmsDp('chrg_mosfet', 4, 1, false, (x) => x & 0x2 != 0, 0x85),
    BmsDp('dischrg_mosfet', 4, 1, false, (x) => x & 0x1 != 0, 0x85),
  ];

  /// Upstream iterates a frozenset; this is the order it produces.
  static const _cmds = [0x83, 0x84, 0x85, 0x87];

  final Map<int, List<int>> _msg = {};

  TianpwrBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFF00)];
  @override
  String get uuidRx => 'ff01';
  @override
  String get uuidTx => 'ff02';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    for (final cmd in [0x81, 0x82]) {
      await awaitMsg(_cmd(cmd));
    }
    return {
      'sw_version': b2str(_msg[0x81]!.sl(3, -1)),
      'hw_version': b2str(_msg[0x82]!.sl(3, -1)),
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length != _defLen) return;
    if (data[0] != _head || data[data.length - 1] != _tail) return;
    _msg[data[2]] = Uint8List.fromList(data);
    msgEvent.set();
  }

  static Uint8List _cmd(int addr) =>
      Uint8List.fromList([_head, _rdCmd, addr & 0xFF, _tail]);

  @override
  Future<BmsSample> asyncUpdate() async {
    _msg.clear();
    for (final cmd in _cmds) {
      await awaitMsg(_cmd(cmd));
    }
    if (!_cmds.every(_msg.containsKey)) {
      throw const FormatException('BMS data incomplete.');
    }
    final result = BaseBms.decodeData(_fields, _msg);

    final cc = (result['cell_count'] as int?) ?? 0;
    final cellPages = (cc < _maxCells ? cc : _maxCells) ~/ 8;
    for (var cmd = 0x88; cmd < 0x89 + cellPages; cmd++) {
      await awaitMsg(_cmd(cmd));
      result['cell_voltages'] = [
        ...((result['cell_voltages'] as List<double>?) ?? const <double>[]),
        ...BaseBms.cellVoltages(_msg[cmd] ?? const [], cells: 8, start: 3),
      ];
    }

    final ts = (result['temp_sensors'] as int?) ?? 0;
    final temps = BaseBms.tempValues(
      _msg[0x87]!,
      values: ts < _maxTemp ? ts : _maxTemp,
      start: 3,
      divider: 10,
    );
    for (final (idx, t) in [(9, TempType.ambient), (11, TempType.mosfet)]) {
      temps.addAll(
        BaseBms.tempValues(_msg[0x83]!, start: idx, divider: 10, types: [t]),
      );
    }
    result['temp_values'] = temps;
    return result;
  }
}
