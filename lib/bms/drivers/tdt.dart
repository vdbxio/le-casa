// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// TDT smart BMS.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class TdtBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'tdt_bms',
    info: const {'manufacturer': 'TDT', 'model': 'smart BMS'},
    matchers: [
      for (final p in ['WTDH*', 'WT???AZ*'])
        MatcherPattern(localName: p, serviceUuid: 'fff0'),
      for (final p in ['HS*', 'WT???BG*'])
        MatcherPattern(localName: p, serviceUuid: 'ffe1'),
      const MatcherPattern(manufacturerId: 54976),
    ],
    create: TdtBms.new,
  );

  static const _uuidCfg = 'fffa';
  static const _rspHead = 0x7E;
  static const _cmdHeadsAll = [0x7E, 0x1E]; // alternative command head
  static const _tail = 0x0D;
  static const _cmdVer = 0x00;
  static const _rspVer = {0x00, 0x04};
  static const _cellPos = 0x8;
  static const _infoLen = 10;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 2, 2, false, (x) => x / 100, 0x8C),
    BmsDp(
      'current',
      0,
      2,
      false,
      (x) => (x & 0x3FFF) / 10 * (x >> 15 != 0 ? -1 : 1),
      0x8C,
    ),
    BmsDp('cycle_charge', 4, 2, false, (x) => x / 10, 0x8C),
    BmsDp('battery_level', 12, 2, false, (x) => x, 0x8C),
    BmsDp('cycles', 8, 2, false, (x) => x, 0x8C),
    BmsDp('design_capacity', 10, 2, false, (x) => x ~/ 10, 0x8C),
    BmsDp('battery_health', 14, 2, false, (x) => x, 0x8C),
  ];
  static final _fieldsV1 = <BmsDp>[
    BmsDp(
      'current',
      0,
      2,
      false,
      (x) => (x & 0x3FFF) * (x >> 15 != 0 ? -1 : 1),
      0x8C,
    ),
    BmsDp('cycle_charge', 4, 2, false, (x) => x, 0x8C),
    BmsDp('design_capacity', 10, 2, false, (x) => x, 0x8C),
  ];
  static const _cmds = [0x8C, 0x8D];

  final Map<int, List<int>> _msg = {};
  List<int> _cmdHeads = _cmdHeadsAll;
  int _validReply = 0;
  int _expLen = 0;
  List<BmsDp> _activeFields = _fields;
  bool? _crcFix; // 0x8D frames come with a broken CRC on some units

  TdtBms(super.device, [super.config]);

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
    for (final head in _cmdHeads) {
      try {
        _validReply = 0x92;
        await awaitMsg(_cmd(0x92, head: head));
        break;
      } on TimeoutException {
        // try the next command head
      }
    }
    final m = _msg[0x92];
    if (m == null) return super.fetchDeviceInfo();
    return {
      'sw_version': b2str(m.sl(8, 28)),
      'manufacturer': b2str(m.sl(28, 48)),
      'serial_number': b2str(m.sl(48, 68)),
    };
  }

  static List<BmsDp> _mergeFields(List<BmsDp> base, List<BmsDp> overrides) {
    final o = {for (final f in overrides) f.key: f};
    return [for (final f in base) o[f.key] ?? f];
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    try {
      await awaitMsg(ascii('HiLink'), char: _uuidCfg, waitForNotify: false);
      final ret = intFrom(await client.read(char(_uuidCfg)));
      if (ret != 0x1) debugPrint('bms: $name: HiLink returned $ret');
    } on UnsupportedDeviceException {
      // no configuration characteristic
    }
    await super.initConnection();
    final bmsInfo = await fetchDeviceInfo();
    final sw = bmsInfo['sw_version'] ?? '';
    if (sw.isNotEmpty && sw.substring(0, sw.length - 1).endsWith('1.')) {
      _activeFields = _mergeFields(_fields, _fieldsV1);
    }
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length > _infoLen && data[0] == _rspHead && frame.length >= _expLen) {
      final len = _infoLen + data.u(6, 2);
      _expLen = len < BaseBms.maxMsgLen ? len : BaseBms.maxMsgLen;
      frame.clear();
    }
    frame.extend(data);

    if (frame.length < (_infoLen > _expLen ? _infoLen : _expLen)) return;
    if (frame[frame.length - 1] != _tail) return;
    if (!_rspVer.contains(frame[1])) return;
    if (frame[4] != 0 || frame[5] != _validReply) return;

    if (!checkIntegrity(frame, crcModbus, (null, -3), (-3, -1))) {
      if (_crcFix == false || frame[5] != 0x8D) return;
      if (_crcFix == null) {
        // only 0x8D frames are wrong, and only in one byte
        _crcFix = frame.u(frame.length - 3, 2) <= 0xFF;
        if (!_crcFix!) return;
        debugPrint('bms: $name: disabling CRC check, values might be unreliable');
      }
    }
    _msg[frame[5]] = frame.sl(0, -3);
    msgEvent.set();
  }

  static Uint8List _cmd(int cmd, {List<int> data = const [], int head = _rspHead}) {
    assert(const {0x8C, 0x8D, 0x92}.contains(cmd));
    final f = [head, _cmdVer, 0x1, 0x3, 0x0, cmd, ...intTo(data.length, 2), ...data];
    return Uint8List.fromList([...f, ...intTo(crcModbus(f), 2), _tail]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    var done = false;
    for (final head in _cmdHeads) {
      try {
        for (final cmd in _cmds) {
          _validReply = cmd;
          await awaitMsg(_cmd(cmd, head: head));
        }
        if (_cmdHeads.length > 1) _cmdHeads = [head]; // stick to this head
        done = true;
        break;
      } on TimeoutException {
        // try the next command head
      }
    }
    if (!done) throw TimeoutException('no answer');

    final m8c = _msg[0x8C]!, m8d = _msg[0x8D]!;
    final cellCount = m8c.length > _cellPos ? m8c[_cellPos] : 0;
    final result = <String, Object?>{'cell_count': cellCount};
    final tempPos = _cellPos + cellCount * 2 + 1;
    if (m8c.length <= tempPos) {
      throw const FormatException('BMS data incomplete.');
    }
    final tempSensors = m8c[tempPos];
    result['temp_sensors'] = tempSensors;
    result['cell_voltages'] = BaseBms.cellVoltages(
      m8c,
      cells: cellCount,
      start: _cellPos + 1,
    );
    result['temp_values'] = BaseBms.tempValues(
      m8c,
      values: tempSensors,
      start: _cellPos + cellCount * 2 + 2,
      signed: false,
      offset: 2730,
      divider: 10,
      types: const [
        TempType.ambient,
        TempType.mosfet,
        TempType.cell,
        TempType.cell,
        TempType.cell,
        TempType.cell,
      ],
    );
    final idx = cellCount + tempSensors;
    if (m8d.length <= _cellPos + idx + 8) {
      throw const FormatException('BMS data incomplete.');
    }
    result.addAll(
      BaseBms.decodeData(_activeFields, _msg, start: _cellPos + idx * 2 + 2),
    );
    result['problem_code'] = intFrom(m8d.sl(_cellPos + idx + 6, _cellPos + idx + 8));
    final mosfets = m8d[_cellPos + idx + 8];
    result['chrg_mosfet'] = mosfets & 0x2 != 0;
    result['dischrg_mosfet'] = mosfets & 0x4 != 0;
    _msg.clear();
    return result;
  }
}
