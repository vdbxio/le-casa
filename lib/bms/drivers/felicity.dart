// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Felicity Solar LiFePO4 batteries. Answers text commands with JSON.

import 'dart:convert';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class FelicityBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'felicity_bms',
    info: const {'manufacturer': 'Felicity Solar', 'model': 'LiFePo4 battery'},
    matchers: [
      for (final p in ['F07*', 'F10*']) MatcherPattern(localName: p),
    ],
    create: FelicityBms.new,
  );

  static const _head = 0x7B; // {
  static const _tail = 0x7D; // }
  static const _cmdPre = 'wifilocalMonitor:';
  static const _cmdBi = 'get dev basice infor';
  static const _cmdRt = 'get dev real infor';
  static const _maxVal = 0xFFFFFFFF; // JSON numbers are limited to 32 bit

  static final _fields = <(String, String, double Function(List<List<int>>))>[
    ('voltage', 'BattList', (x) => x[0][0] / 1000),
    ('current', 'BattList', (x) => x[1][0] / 10),
    ('cycle_charge', 'BatsocList', (x) => (x[0][0] * x[0][2]) / 1e7),
    ('battery_level', 'BatsocList', (x) => x[0][0] / 100),
  ];

  Map<String, dynamic> _msg = {};

  FelicityBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['6e6f736a-4643-4d44-8fa9-0fafd005e455'];
  @override
  String get uuidRx => '49535458-8341-43f4-a9d4-ec0e34729bb3';
  @override
  String get uuidTx => '49535258-184d-4bd9-bc61-20c647249616';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitMsg(ascii(_cmdPre + _cmdBi));
    String s(String k) => '${_msg[k] ?? ''}';
    return {
      'fw_version': s('M1SwVer'),
      'sw_version': s('version'),
      'model_id': s('Type'),
      'serial_number': s('DevSN'),
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.isNotEmpty && data[0] == _head) frame.clear();
    frame.extend(data);
    if (data.isEmpty || data.last != _tail) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame));
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    _msg = decoded;
    if ((_msg['CommVer'] ?? 0) != 1) return;
    msgEvent.set();
  }

  /// Python's int() on a JSON value, limited to 32 bit.
  static int _int(Object? value) {
    final int result;
    if (value is int) {
      result = value;
    } else if (value is double) {
      if (!value.isFinite) throw const FormatException('not a number');
      result = value.truncate();
    } else if (value is bool) {
      result = value ? 1 : 0;
    } else if (value is String) {
      result = int.parse(value.trim().replaceAll('_', ''));
    } else {
      throw const FormatException('not a number');
    }
    if (result.abs() > _maxVal) {
      throw FormatException('value out of range: $result');
    }
    return result;
  }

  static List<List<int>> _rows(Object? v) => [
    for (final row in (v ?? const []) as List)
      [for (final value in row as List) _int(value)],
  ];

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(ascii(_cmdPre + _cmdRt));
    try {
      final result = <String, Object?>{
        for (final (key, itm, func) in _fields) key: func(_rows(_msg[itm])),
      };
      final temps = _msg['BtemList'];
      if (temps is! List || temps.isEmpty) {
        throw const FormatException('invalid temperature data');
      }
      result['temp_values'] = [
        for (final value in temps[0] as List)
          if (_int(value) case final t when t != 0x7FFF) TempSensor(t / 10),
      ];
      final cells = (_msg['BatcelList'] ?? const []) as List;
      result['cell_voltages'] = [
        for (final value in cells[0] as List) _int(value) / 1000,
      ];
      result['problem_code'] =
          _int(_msg['Bwarn'] ?? 0) + _int(_msg['Bfault'] ?? 0);
      return result;
    } on FormatException {
      throw const FormatException('BMS data incomplete.');
    } on RangeError {
      throw const FormatException('BMS data incomplete.');
    } on TypeError {
      throw const FormatException('BMS data incomplete.');
    }
  }
}
