// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Greenway BMS: one request per value.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

abstract final class _MsgT {
  static const temp = 0x8;
  static const voltage = 0x9;
  static const current = 0xA;
  static const soc = 0xD;
  static const soh = 0xE;
  static const cycChrg = 0xF;
  static const status = 0x16;
  static const cycles = 0x17;
  static const dcap = 0x18;
  static const version = 0x1A;
  static const manuf = 0x20;
  static const bmsType = 0x21;
  static const serial = 0x23;
  static const cellVoltages1 = 0x24;
  static const cellVoltages2 = 0x25;
}

class GreenwayBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'greenway_bms',
    info: {'manufacturer': 'Greenway', 'model': 'BMS'},
    matchers: [MatcherPattern(oui: 'C4:A9:B8', serviceUuid: 'fff0')],
    create: GreenwayBms.new,
  );

  static const _headCmd = [0x46, 0x16, 0x01];
  static const _headRsp = [0x47, 0x16, 0x01];
  static const _lenPos = 4;
  static const _minLen = 6;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 0, 4, false, (x) => x / 1000, _MsgT.voltage),
    BmsDp('current', 0, 4, true, (x) => x / 1000, _MsgT.current),
    BmsDp('battery_level', 0, 4, false, (x) => x, _MsgT.soc),
    BmsDp('battery_health', 0, 4, false, (x) => x, _MsgT.soh),
    BmsDp('cycles', 0, 4, false, (x) => x, _MsgT.cycles),
    BmsDp('cycle_charge', 0, 4, false, (x) => x / 1000, _MsgT.cycChrg),
    BmsDp('design_capacity', 0, 4, false, (x) => x ~/ 1000, _MsgT.dcap),
    BmsDp('problem_code', 2, 8, false, (x) => x, _MsgT.status),
  ];

  /// Upstream iterates a frozenset; this is the order it produces.
  static const _msgSet = [
    _MsgT.cellVoltages1,
    _MsgT.cellVoltages2,
    _MsgT.temp,
    _MsgT.voltage,
    _MsgT.current,
    _MsgT.soc,
    _MsgT.soh,
    _MsgT.cycChrg,
    _MsgT.status,
    _MsgT.cycles,
    _MsgT.dcap,
  ];
  static const _length = {
    8: 32, 9: 4, 10: 4, 13: 4, 14: 4, 15: 4, 16: 4, 20: 4, 22: 16, 23: 4, //
    24: 4, 25: 4, 26: 8, 27: 4, 28: 4, 29: 6, 30: 6, 32: 16, 33: 32, 34: 16,
    35: 32, 36: 32, 37: 32, 38: 14,
  };

  final Map<int, List<int>> _msg = {};
  int _expReply = 0;

  GreenwayBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'fff1';

  static Uint8List _cmd(int addr) {
    final len = _length[addr]!;
    return Uint8List.fromList([
      ..._headCmd,
      addr,
      len,
      0xFF & (_headCmd.sum + addr + len),
    ]);
  }

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    for (final addr in [
      _MsgT.version,
      _MsgT.manuf,
      _MsgT.bmsType,
      _MsgT.serial,
    ]) {
      _expReply = addr;
      await awaitMsg(_cmd(addr));
    }
    String body(int t) => b2str(_msg[t]!.sl(_lenPos + 1, -1));
    final ver = _msg[_MsgT.version]!.sl(_lenPos + 1, -1);
    if (ver.length < 4) throw const FormatException('BMS data incomplete.');
    return {
      'manufacturer': body(_MsgT.manuf),
      'model': body(_MsgT.bmsType),
      'serial_number': body(_MsgT.serial),
      'fw_version': b2str(ver.sl(4)),
      'hw_version': '${ver[3]}.${ver[2]}',
      'sw_version': '${ver[1]}.${ver[0]}',
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.startsWithBytes(_headRsp)) frame.clear();
    frame.extend(data);

    if (frame.length < _minLen || frame.length < frame[_lenPos] + _minLen) {
      return;
    }
    if (!frame.startsWithBytes(_headRsp)) {
      frame.clear();
      return;
    }
    if (frame[3] != _expReply) return;
    if (!checkIntegrity(frame, crcSum, (null, -1), (-1, null))) return;

    _msg[frame[3]] = frame.bytes;
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    for (final addr in _msgSet) {
      _expReply = addr;
      await awaitMsg(_cmd(addr));
    }
    final result = BaseBms.decodeData(
      _fields,
      _msg,
      little: true,
      start: _lenPos + 1,
    );
    result['cell_voltages'] = [
      for (final t in [_MsgT.cellVoltages1, _MsgT.cellVoltages2])
        ...BaseBms.cellVoltages(
          _msg[t]!,
          cells: 16,
          start: _lenPos + 1,
          little: true,
        ),
    ];
    result['temp_values'] = BaseBms.tempValues(
      _msg[_MsgT.temp]!,
      values: 7,
      start: _lenPos + 1,
      size: 1,
    );
    _msg.clear();
    msgEvent.clear();
    return result;
  }
}
