// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// D-powercore smart BMS (DXB, TBA). Paged frames, each page acknowledged.
// DXB modules unlock with the last four hex digits of their name.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class DpwrcoreBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'dpwrcore_bms',
    info: const {'manufacturer': 'D-powercore', 'model': 'smart BMS'},
    matchers: [
      for (final p in ['DXB-*', 'TBA-*']) MatcherPattern(localName: p),
    ],
    create: DpwrcoreBms.new,
  );

  static const _legInfo1 = 0x60;
  static const _legInfo2 = 0x61;
  static const _cellVolt = 0x62;
  static const _unlock = 0x64;
  static const _pageLen = 20;
  static const _minLen = 8;
  static const _maxCells = 32;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 6, 2, false, (x) => x / 10, _legInfo1),
    BmsDp('current', 8, 2, true, (x) => x / 10, _legInfo1),
    BmsDp('battery_level', 14, 1, false, (x) => x, _legInfo1),
    BmsDp('cycle_charge', 12, 2, false, (x) => x / 1000, _legInfo1),
    BmsDp(
      'temp_values',
      12,
      2,
      false,
      (x) => [TempSensor(pyRound(x / 10 - 273.15, 3))],
      _legInfo2,
    ),
    BmsDp(
      'cell_count',
      6,
      1,
      false,
      (x) => x < _maxCells ? x : _maxCells,
      _cellVolt,
    ),
    BmsDp('cycles', 8, 2, false, (x) => x, _legInfo2),
    BmsDp('problem_code', 15, 1, false, (x) => x & 0xFF, _legInfo1),
  ];
  static const _cmds = [_legInfo1, _legInfo2, _cellVolt];

  Map<int, List<int>> _msg = {};

  DpwrcoreBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff4';
  @override
  String get uuidTx => 'fff3';

  @override
  Future<void> notificationHandler(GattChar sender, Uint8List data) async {
    if (data.length != _pageLen) return;
    if (data[0] & 0x80 != 0) return; // ACK
    final page = data[1] >> 4;
    if (page == 1) frame.clear();
    frame.extend(data.sl(2, data[0] + 2));
    // acknowledge the page
    await awaitMsg([data[0] | 0x80, ...data.sl(1)], waitForNotify: false);
    if (page == data[1] & 0xF) {
      if (frame.length < _minLen ||
          !checkIntegrity(frame, _crc, (3, -4), (-4, -2))) {
        frame.clear();
        _msg = {};
        return;
      }
      _msg[frame[3]] = frame.bytes;
      msgEvent.set();
    }
  }

  static int _crc(List<int> data) => data.sum + 8;

  static Uint8List _cmd(int cmd, List<int> data) {
    var f = <int>[cmd, 0x00, 0x00, ...data];
    final checksum = _crc(f);
    f = [0x3A, 0x03, 0x05, ...f, ...intTo(checksum, 2), 0x0D, 0x0A];
    f = [f.length + 2, 0x11, ...f];
    f.addAll(List.filled(_pageLen - f.length, 0));
    return Uint8List.fromList(f);
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection();
    if (name.startsWith('TBA-')) return; // TBA modules need no unlock
    if (name.length < 4) return;
    final tail = ascii(name.substring(name.length - 4));
    if (!isHexDigits(tail)) return;
    final pwd = hexInt(tail);
    await awaitMsg(
      _cmd(_unlock, [(pwd >> 8) & 0xFF, pwd & 0xFF]),
      waitForNotify: false,
    );
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    for (final r in _cmds) {
      await awaitMsg(_cmd(r, const []));
    }
    if (!_cmds.every(_msg.containsKey)) {
      throw const FormatException('BMS data incomplete.');
    }
    final result = BaseBms.decodeData(_fields, _msg);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg[_cellVolt]!,
      cells: (result['cell_count'] as int?) ?? 0,
      start: 7,
    );
    _msg.clear();
    return result;
  }
}
