// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// PeiCheng Technology PACEEX smart BMS.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

abstract final class _Cmd {
  static const serial = [0x00, 0x00, 0x00, 0x02, 0x00, 0x00];
  static const versions = [0x00, 0x00, 0x00, 0x01, 0x00, 0x00];
  static const sysInfo = [0x00, 0x00, 0x0A, 0x00, 0x00, 0x00];
  static const packInfo = [0x00, 0x00, 0x0A, 0x01, 0x00, 0x00];
  static const cellInfo = [0x00, 0x00, 0x0A, 0x02, 0x00, 0x00];
}

class PaceBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'pace_bms',
    info: {'manufacturer': 'PeiCheng Technology', 'model': 'PACEEX Smart BMS'},
    matchers: [MatcherPattern(localName: 'PC-????')],
    create: PaceBms.new,
  );

  static const _head = 0x9A;
  static const _tail = 0x9D;
  static const _minLen = 11;
  static const _cellPos = 12;
  static const _hwvPos = 65;
  static const _swvPos = 10;
  static final _fields = <BmsDp>[
    BmsDp('current', 1, 2, true, (x) => x / 100),
    BmsDp('voltage', 3, 2, false, (x) => x / 100),
    BmsDp('cycle_charge', 5, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 9, 2, false, (x) => x ~/ 100),
    BmsDp('battery_level', 11, 1, false),
    BmsDp('battery_health', 12, 1, false),
    BmsDp('cycles', 13, 2, false),
  ];

  List<int> _validReply = const [];
  Uint8List _msg = Uint8List(0);

  PaceBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'fff2';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    final result = <String, String>{};
    await awaitMsg(_cmd(_Cmd.serial));
    final length = _msg[8];
    result['serial_number'] = b2str(_msg.sl(9, 9 + length));
    await awaitMsg(_cmd(_Cmd.versions));
    if (_msg.length < _hwvPos) {
      throw const FormatException('BMS data incomplete.');
    }
    result['sw_version'] = b2str(_msg.sl(_swvPos, _swvPos + _msg[_swvPos - 1]));
    result['hw_version'] = b2str(_msg.sl(_hwvPos, _hwvPos + _msg[_hwvPos - 1]));
    return result;
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.isEmpty || data[0] != _head) return;
    if (data.length < _minLen || data.length != _minLen + data[7]) return;
    if (!checkIntegrity(data, crcModbus, (null, -3), (-3, -1))) return;
    if (!bytesEq(data.sl(1, 7), _validReply)) return;
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  static Uint8List _cmd(List<int> cmd, [List<int> data = const []]) {
    final f = [_head, ...cmd, data.length & 0xFF, ...data];
    return Uint8List.fromList([...f, ...intTo(crcModbus(f), 2), _tail]);
  }

  @override
  Future<void> awaitMsg(
    List<int> data, {
    CharSpec? char,
    bool waitForNotify = true,
    int maxSize = 0,
  }) {
    _validReply = data.sl(1, 7);
    return super.awaitMsg(
      data,
      char: char,
      waitForNotify: waitForNotify,
      maxSize: maxSize,
    );
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(_cmd(_Cmd.packInfo, const [0x01, 0x01]));
    final result = BaseBms.decodeData(_fields, _msg, start: 8);
    await awaitMsg(_cmd(_Cmd.cellInfo, const [0x01, 0x01]));
    if (_msg.length < _cellPos) {
      throw const FormatException('BMS data incomplete.');
    }
    final cellCount = _msg[_cellPos - 1];
    result['cell_count'] = cellCount;
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: cellCount,
      start: _cellPos,
      gap: 2,
    );
    result['temp_values'] = BaseBms.tempValues(
      _msg,
      values: 6,
      start: 14,
      gap: 2,
      signed: false,
      offset: 2731,
      divider: 10,
      types: const [
        TempType.cell,
        TempType.cell,
        TempType.cell,
        TempType.cell,
        TempType.mosfet,
        TempType.ambient,
      ],
    );
    await awaitMsg(_cmd(_Cmd.sysInfo));
    final packCount = _msg[8]; // zero on all packs but the master
    if (packCount != 0) result['pack_count'] = packCount;
    return result;
  }
}
