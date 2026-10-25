// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// CBT Power / Creabest smart BMS.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class CbtpwrBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'cbtpwr_bms',
    info: const {'manufacturer': 'CBT Power', 'model': 'smart BMS'},
    matchers: const [
      MatcherPattern(serviceUuid: 'ffe5'),
      // Creabest
      MatcherPattern(localName: '???[CR]??????', serviceUuid: 'fff0'),
      MatcherPattern(serviceUuid: '03c1', manufacturerId: 0x5352),
    ],
    create: CbtpwrBms.new,
  );

  static const _head = [0xAA, 0x55];
  static const _tailRx = [0x0D, 0x0A];
  static const _tailTx = [0x0A, 0x0D];
  static const _minFrame = 2 + 2 + 3;
  static const _crcPos = -2 - 1;
  static const _lenPos = 3;
  static const _cellvCmds = [0x5, 0x6, 0x7, 0x8];
  static final _fields = <BmsDp>[
    BmsDp('voltage', 4, 4, false, (x) => x / 1000, 0x0B),
    BmsDp('current', 8, 4, true, (x) => x / 1000, 0x0B),
    BmsDp('temp_values', 4, 2, true, (x) => [TempSensor(x)], 0x09),
    BmsDp('battery_level', 4, 1, false, (x) => x, 0x0A),
    BmsDp('design_capacity', 4, 2, false, (x) => x, 0x15),
    BmsDp('cycles', 6, 2, false, (x) => x, 0x15),
    BmsDp(
      'runtime',
      14,
      2,
      false,
      (x) => floorDiv(x * BaseBms.hrsToSecs, 100),
      0x0C,
    ),
    BmsDp('problem_code', 4, 4, false, (x) => x, 0x21),
  ];
  // upstream iterates a frozenset; this is its order
  static const _cmds = [0x21, 0x09, 0x0A, 0x0B, 0x0C, 0x15];

  final Map<int, List<int>> _msg = {};

  CbtpwrBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE5), uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe4';
  @override
  String get uuidTx => 'ffe9';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length < _minFrame || data.length != _minFrame + data[_lenPos]) {
      return;
    }
    if (!data.startsWithBytes(_head) || !data.endsWithBytes(_tailRx)) return;
    if (!checkIntegrity(
      data,
      crcSum,
      (_head.length, data.length + _crcPos),
      (_crcPos, _crcPos + 1),
    )) {
      return;
    }
    _msg[data[2]] = Uint8List.fromList(data);
    msgEvent.set();
  }

  static Uint8List _cmd(int cmd, [List<int> value = const []]) {
    final f = [..._head, cmd, value.length, ...value];
    return Uint8List.fromList([
      ...f,
      crcSum(f.sublist(_head.length)),
      ..._tailTx,
    ]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    _msg.clear();
    for (final cmd in _cmds) {
      await awaitMsg(_cmd(cmd));
    }
    if (!_cmds.every(_msg.containsKey)) {
      throw const FormatException('BMS data incomplete.');
    }
    final voltages = <double>[];
    for (final cmd in _cellvCmds) {
      await awaitMsg(_cmd(cmd));
      if (!_msg.containsKey(cmd)) {
        throw const FormatException('BMS data incomplete.');
      }
      final cells = BaseBms.cellVoltages(
        _msg[cmd]!,
        cells: 5,
        start: 4,
        little: true,
      );
      voltages.addAll(cells);
      if (voltages.length % 5 != 0 || cells.isEmpty) break;
    }
    final data = BaseBms.decodeData(_fields, _msg, little: true);
    if (((data['current'] as num?) ?? 0) >= 0) data.remove('runtime');
    return data..['cell_voltages'] = voltages;
  }
}
