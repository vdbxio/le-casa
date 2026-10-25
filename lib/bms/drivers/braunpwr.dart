// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Braun Power smart BMS (HSKS, BL, KS, Vanvolt).

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class BraunpwrBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'braunpwr_bms',
    info: const {'manufacturer': 'Braun Power', 'model': 'smart BMS'},
    matchers: [
      for (final p in ['HSKS-*', 'BL-*', 'KS-*', 'Vanvolt-*'])
        MatcherPattern(localName: p, serviceUuid: 'ff00', manufacturerId: 0x7B),
    ],
    create: BraunpwrBms.new,
  );

  static const _head = [0x7B];
  static const _tail = 0x7D;
  static const _minLen = 4;
  static final _fields = <BmsDp>[
    BmsDp('cell_count', 3, 1, false, (x) => x, 0x2),
    BmsDp('temp_sensors', 3, 1, false, (x) => x, 0x3),
    BmsDp('voltage', 5, 2, false, (x) => x / 100, 0x1),
    BmsDp('current', 13, 2, true, (x) => x / 100, 0x1),
    BmsDp('battery_level', 4, 1, false, (x) => x, 0x1),
    BmsDp('battery_health', 34, 1, false, (x) => x, 0x1),
    BmsDp('cycle_charge', 15, 2, false, (x) => x / 100, 0x1),
    BmsDp('design_capacity', 17, 2, false, (x) => x ~/ 100, 0x1),
    BmsDp('cycles', 23, 2, false, (x) => x, 0x1),
    BmsDp('problem_code', 31, 2, false, (x) => x, 0x1),
    BmsDp('balancer', 25, 2, false, (x) => x, 0x1),
  ];
  static const _cmds = [0x1, 0x2, 0x3];
  // SW version, BMS boot version, BMS program version (upstream set order)
  static const _initCmds = [0xF5, 0x74, 0xF4];

  final Map<int, List<int>> _msg = {};
  List<int> _expReply = const [0x01];

  BraunpwrBms(super.device, [super.config]);

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
    for (final cmd in _initCmds) {
      _expReply = [cmd];
      await awaitMsg(_cmd(cmd));
    }
    return {
      'sw_version': _msg[0xF4]!.sl(3, 6).join('.'),
      'hw_version': b2str(_msg[0x74]!.sl(3, -1)),
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.startsWithBytes(_head) &&
        frame.length >= _minLen &&
        data.length >= _minLen &&
        (_cmds.contains(data[1]) || _initCmds.contains(data[1])) &&
        frame.length >= _minLen + frame[2]) {
      frame.clear();
    }
    frame.extend(data);
    if (frame.length < _minLen || frame.length < _minLen + frame[2]) return;
    if (frame[-1] != _tail) {
      frame.clear();
      return;
    }
    if (!_expReply.contains(frame[1])) {
      frame.clear();
      return;
    }
    if (frame.length != _minLen + frame[2]) {
      frame.clear();
      return;
    }
    _msg[frame[1]] = frame.bytes;
    msgEvent.set();
  }

  static Uint8List _cmd(int cmd, [List<int> data = const []]) =>
      Uint8List.fromList([..._head, cmd, data.length, ...data, _tail]);

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection();
    await fetchDeviceInfo();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    _msg.clear();
    for (final cmd in _cmds) {
      _expReply = [cmd];
      await awaitMsg(_cmd(cmd));
    }
    final data = BaseBms.decodeData(_fields, _msg);
    data['cell_voltages'] = BaseBms.cellVoltages(
      _msg[0x2]!,
      cells: (data['cell_count'] as int?) ?? 0,
      start: 4,
    );
    final temps = (data['temp_sensors'] as int?) ?? 0;
    data['temp_values'] = BaseBms.tempValues(
      _msg[0x3]!,
      values: temps,
      start: 4,
      offset: 2731,
      divider: 10,
      types: List.filled(temps, TempType.cell),
    );
    return data;
  }
}
