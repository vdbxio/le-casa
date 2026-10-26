// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Creabest VB series: ASCII-hex framed, Pylontech-like protocol.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class CbtpwrVbBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'cbtpwr_vb_bms',
    info: const {'manufacturer': 'Creabest', 'model': 'VB series'},
    matchers: const [
      MatcherPattern(localName: 'VB?????????', serviceUuid: 'fff0'),
    ],
    create: CbtpwrVbBms.new,
  );

  static const _head = [0x7E];
  static const _tail = [0x0D];
  static const _cmdVer = 0x11;
  static const _rspVer = [0x22];
  static const _lenPos = 9;
  static const _minLen = _lenPos + 3 + 1 + 1 + 4;
  static const _cellPos = 6;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 2, 2, false, (x) => x / 10),
    BmsDp('current', 0, 2, true, (x) => x / 10),
    BmsDp('battery_level', 4, 2, false, (x) => x < 100 ? x : 100),
    BmsDp('cycles', 7, 2, false),
    BmsDp('problem_code', 15, 6, false, (x) => x & 0xFFF000FF000F),
  ];
  static final int _fieldsEnd = _fields
      .map((f) => f.pos + f.size)
      .reduce((a, b) => a > b ? a : b);

  Uint8List _msg = Uint8List(0);
  int _expLen = 0;

  CbtpwrVbBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0), uuid16(0xFFE5)];
  @override
  String get uuidRx => 'ffe4';
  @override
  String get uuidTx => 'ffe9';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length > _lenPos + 4 && data.startsWithBytes(_head)) {
      frame.clear();
      try {
        final length = hexInt(data.sl(_lenPos, _lenPos + 4));
        _expLen = length & 0xFFF;
        if (lencs(length) != length >> 12) _expLen = 0;
      } on FormatException {
        _expLen = 0;
      }
    }
    frame.extend(data);
    final need = _expLen + _minLen;
    if (frame.length <
        (need < BaseBms.bleMaxAttrSize ? need : BaseBms.bleMaxAttrSize)) {
      return;
    }
    if (!frame.endsWithBytes(_tail)) {
      frame.clear();
      return;
    }
    if (frame.length.isOdd || !isHexDigits(frame.sl(1, -1))) {
      frame.clear();
      return;
    }
    if (!bytesEq(fromHexStr(String.fromCharCodes(frame.sl(1, 3))), _rspVer)) {
      frame.clear();
      return;
    }
    if (!checkIntegrity(
      frame,
      lrcModbus,
      (1, -5),
      hexInt(frame.sl(-5, -1)),
      little: true,
    )) {
      frame.clear();
      return;
    }
    var s = 0, e = frame.length;
    while (s < e && (frame[s] == 0x7E || frame[s] == 0x0D)) {
      s++;
    }
    while (e > s && (frame[e - 1] == 0x7E || frame[e - 1] == 0x0D)) {
      e--;
    }
    _msg = fromHexStr(String.fromCharCodes(frame.sl(s, e)));
    msgEvent.set();
  }

  static int lencs(int length) {
    var sum = 0;
    for (var i = 0; i < 3; i++) {
      sum += (length >> (i * 4)) & 0xF;
    }
    return ((sum ^ 0xF) + 1) & 0xF;
  }

  static Uint8List _cmd(int cmd, [int devId = 1, List<int> data = const []]) {
    final cdat = [...data, devId];
    final f = <int>[_cmdVer, devId, 0x46, cmd];
    f.addAll(intTo(cdat.length * 2 + (lencs(cdat.length * 2) << 12), 2));
    f.addAll(cdat);
    f.addAll(intTo(lrcModbus(ascii(f.hex.toUpperCase())), 2));
    return Uint8List.fromList([
      ..._head,
      ...ascii(f.hex.toUpperCase()),
      ..._tail,
    ]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(_cmd(0x42));
    final cells = _msg[_cellPos];
    final result = <String, Object?>{'cell_count': cells};
    final tempPos = _cellPos + cells * 2 + 1;
    final tempSensors = _msg.u(tempPos, 1);
    final fieldStart = tempPos + 2 * tempSensors + 1;
    if (_msg.length < fieldStart + _fieldsEnd) {
      throw const FormatException('BMS data incomplete.');
    }
    result['temp_sensors'] = tempSensors;
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: cells,
      start: _cellPos + 1,
    );
    result['temp_values'] = BaseBms.tempValues(
      _msg,
      values: tempSensors,
      start: tempPos + 1,
      divider: 10,
    );
    result.addAll(BaseBms.decodeData(_fields, _msg, start: fieldStart));

    await awaitMsg(_cmd(0x81, 1, const [0x01, 0x00]), maxSize: 20);
    result['design_capacity'] = _msg.u(6, 2) ~/ 10;
    return result;
  }
}
