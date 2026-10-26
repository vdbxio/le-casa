// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// ABC-BMS (Chunguang Song), also SOK and Hoover batteries.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class AbcBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'abc_bms',
    info: const {'manufacturer': 'Chunguang Song', 'model': 'ABC-BMS'},
    matchers: [
      for (final p in ['ABC-*', 'SOK-*', 'NB-*', 'Hoover'])
        MatcherPattern(localName: p, serviceUuid: 'fff0'),
    ],
    create: AbcBms.new,
  );

  static const _headCmd = 0xEE;
  static const _headResp = [0xCC];
  static const _infoLen = 0x14;
  static const _maxCell = 32;
  static const _expReplyDef = <int, Set<int>>{
    0xC0: {0xF1},
    0xC1: {0xF0, 0xF2},
    0xC2: {0xF0, 0xF3, 0xF4},
    0xC3: {0xF5, 0xF6, 0xF7, 0xF8, 0xFA},
    0xC4: {0xF9},
  };
  static final _fields = <BmsDp>[
    BmsDp('temp_sensors', 4, 1, false, (x) => x, 0xF2),
    BmsDp('voltage', 2, 3, false, (x) => x / 1000, 0xF0),
    BmsDp('current', 5, 3, true, (x) => x / 1000, 0xF0),
    BmsDp('design_capacity', 8, 3, false, (x) => x ~/ 1000, 0xF0),
    BmsDp('battery_level', 16, 1, false, (x) => x, 0xF0),
    BmsDp('cycle_charge', 11, 3, false, (x) => x / 1000, 0xF0),
    BmsDp('cycles', 14, 2, false, (x) => x, 0xF0),
    // only the first bit of each byte is used
    BmsDp.bytes('problem_code', 2, 16, (b) {
      var v = 0;
      for (var i = 0; i < 16; i++) {
        v |= (b[i] & 1) << i;
      }
      return v;
    }, 0xF9),
    BmsDp('chrg_mosfet', 2, 1, false, (x) => x != 0, 0xF2),
    BmsDp('dischrg_mosfet', 3, 1, false, (x) => x != 0, 0xF2),
    BmsDp('heater', 8, 1, false, (x) => x != 0, 0xF3),
    BmsDp('balancer', 10, 1, false, (x) => x, 0xF3),
  ];
  static final Set<int> _resps = {for (final f in _fields) f.idx, 0xF4};

  final Map<int, List<int>> _msg = {};
  final Set<int> _expReply = {};

  AbcBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe1';
  @override
  String get uuidTx => 'ffe2';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    final info = await super.fetchDeviceInfo();
    _expReply
      ..clear()
      ..addAll(_expReplyDef[0xC0]!);
    await awaitMsg(_cmd(0xC0));
    info['model'] = b2str(_msg[0xF1]!.sl(2, -1));
    return info;
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (!data.startsWithBytes(_headResp)) return;
    if (data.length != _infoLen) return;
    if (!checkIntegrity(data, crc8, (null, -1), (-1, null))) return;

    if (data[1] == 0xF4 && _msg.containsKey(0xF4)) {
      // each part holds 4 cells, only accept the consecutive next part
      if (data[2] != _msg[0xF4]!.length ~/ 4 || data[2] > _maxCell) return;
      _msg[0xF4] = [..._msg[0xF4]!.sl(null, -2), ...data.sl(2)];
    } else {
      _msg[data[1]] = Uint8List.fromList(data);
    }
    _expReply.remove(data[1]);
    if (_expReply.isEmpty) msgEvent.set();
  }

  static Uint8List _cmd(int cmd) {
    final f = [_headCmd, cmd, 0x00, 0x00, 0x00];
    return Uint8List.fromList([...f, crc8(f)]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    _msg.clear();
    _expReply.clear();
    for (final cmd in [0xC1, 0xC2, 0xC4]) {
      _expReply.addAll(_expReplyDef[cmd]!);
      try {
        await awaitMsg(_cmd(cmd));
      } on TimeoutException {
        // not every BMS answers every request
      }
    }
    if (!_resps.every((r) => _msg.containsKey(r) || r == 0xF9)) {
      throw const FormatException('BMS data incomplete.');
    }
    final result = BaseBms.decodeData(_fields, _msg, little: true);
    final cells = BaseBms.cellVoltages(
      _msg[0xF4]!,
      cells: (_msg[0xF4]!.length - 4) ~/ 2,
      start: 3,
      little: true,
    );
    result['cell_voltages'] = [
      for (var i = 0; i < cells.length; i += 2) cells[i],
    ];
    result['temp_values'] = BaseBms.tempValues(
      _msg[0xF2]!,
      start: 5,
      values: (result['temp_sensors'] as int?) ?? 0,
      little: true,
    );
    return result;
  }
}
