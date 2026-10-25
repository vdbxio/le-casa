// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// RoyPow smart BMS.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class RoypowBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'roypow_bms',
    info: const {'manufacturer': 'RoyPow', 'model': 'smart BMS'},
    matchers: [
      // OUI "12:" is private
      for (final p in [' [BS]12*', ' [BS]24*', ' UT*'])
        MatcherPattern(localName: p, serviceUuid: 'ffe0'),
    ],
    create: RoypowBms.new,
  );

  static const _head = [0xEA, 0xD1, 0x01];
  static const _tail = 0xF5;
  static final _btModuleMsg = ascii('AT+STAT\r\n');
  static const _minLen = 4;
  static final _fields = <BmsDp>[
    BmsDp('battery_level', 7, 1, false, (x) => x, 0x4),
    BmsDp('voltage', 47, 2, false, (x) => x / 100, 0x4),
    BmsDp(
      'current',
      6,
      3,
      false,
      (x) => (x & 0xFFFF) * ((x >> 16) & 0x1 != 0 ? -1 : 1) / 100,
      0x3,
    ),
    BmsDp('problem_code', 9, 3, false, (x) => x, 0x3),
    BmsDp(
      'cycle_charge',
      24,
      4,
      false,
      (x) => ((x & 0xFFFF0000) | (x & 0xFF00) >> 8 | (x & 0xFF) << 8) / 1000,
      0x4,
    ),
    BmsDp('runtime', 30, 2, false, (x) => x * 60, 0x4),
    BmsDp('temp_sensors', 13, 1, false, (x) => x, 0x3),
    BmsDp('cycles', 9, 2, false, (x) => x, 0x4),
    BmsDp('chrg_mosfet', 24, 1, false, (x) => x & 0x4 != 0, 0x3),
    BmsDp('dischrg_mosfet', 24, 1, false, (x) => x & 0x2 != 0, 0x3),
  ];

  /// Upstream iterates a frozenset; this is the order it produces.
  static const _cmds = [0x2, 0x3, 0x4];

  final Map<int, List<int>> _msg = {};
  int _expLen = 0;

  RoypowBms(super.device, [super.config]);

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
    final d = data.startsWithBytes(_btModuleMsg)
        ? data.sl(_btModuleMsg.length)
        : data;
    if (d.isEmpty) return;

    if (d.startsWithBytes(_head) &&
        !frame.startsWithBytes(_head) &&
        d.length > _head.length) {
      _expLen = d[_head.length];
      frame.clear();
    }
    frame.extend(d);

    if (!frame.startsWithBytes(_head)) {
      frame.clear();
      return;
    }
    if (frame.length < _minLen + _expLen) return;

    final endIdx = _minLen + _expLen - 1;
    if (frame[endIdx] != _tail) {
      frame.clear();
      return;
    }
    if (!checkIntegrity(
      frame,
      _crc,
      (_head.length, endIdx - 1),
      (endIdx - 1, endIdx),
    )) {
      frame.clear();
      return;
    }
    _msg[frame[5]] = frame.bytes;
    frame.clear();
    msgEvent.set();
  }

  static int _crc(List<int> frame) => frame.fold(0, (c, b) => c ^ b);

  static Uint8List _cmd(List<int> cmd) {
    final data = [cmd.length + 2, ...cmd];
    return Uint8List.fromList([..._head, ...data, _crc(data), _tail]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    frame.clear();
    _msg.clear();
    for (final cmd in _cmds) {
      await awaitMsg(_cmd([0xFF, cmd]));
    }
    if (!_cmds.every(_msg.containsKey)) {
      throw const FormatException('BMS data incomplete.');
    }
    final result = BaseBms.decodeData(_fields, _msg);

    // no remaining runtime while charging
    if (result['runtime'] == 0xFFFF * 60) result.remove('runtime');

    final cells = _msg[0x2] ?? const <int>[];
    final n = (cells.length - 11) ~/ 2;
    result['cell_voltages'] = BaseBms.cellVoltages(
      cells,
      cells: n > 0 ? n : 0,
      start: 9,
    );
    result['temp_values'] = BaseBms.tempValues(
      _msg[0x3] ?? const [],
      values: (result['temp_sensors'] as int?) ?? 0,
      start: 14,
      size: 1,
      signed: false,
      offset: 40,
    );
    return result;
  }
}
