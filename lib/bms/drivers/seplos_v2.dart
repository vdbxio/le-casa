// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Seplos smart BMS V2.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class SeplosV2Bms extends BaseBms {
  static final spec = BmsSpec(
    module: 'seplos_v2_bms',
    info: const {'manufacturer': 'Seplos', 'model': 'smart BMS V2'},
    matchers: [
      for (final p in ['BP0?', 'BP1?', 'BP2?'])
        MatcherPattern(localName: p, serviceUuid: 'ff00'),
    ],
    create: SeplosV2Bms.new,
  );

  static const _head = 0x7E;
  static const _tail = 0x0D;
  static const _cmdVer = 0x10;
  static const _rspVer = 0x14;
  static const _minLen = 10;
  static const _cellPos = 9;
  static const _packPos = 42;
  static const _swvPos = 38;
  static const _prbMax = 8; // alarm event bytes
  static const _prbMask = ~0x80FFC0; // events 6-8 are internal
  static final _pfields = <BmsDp>[
    BmsDp('voltage', 2, 2, false, (x) => x / 100),
    BmsDp('current', 0, 2, true, (x) => x / 100), // /10 for 0x62
    BmsDp('cycle_charge', 4, 2, false, (x) => x / 100), // /10 for 0x62
    BmsDp('cycles', 13, 2, false),
    BmsDp('design_capacity', 11, 2, false, (x) => x ~/ 100),
    BmsDp('battery_level', 9, 2, false, (x) => x / 10),
    BmsDp('battery_health', 15, 2, false, (x) => x / 10),
  ];
  static final int _gsmdLen =
      _cellPos +
      _pfields.map((d) => d.pos + d.size).reduce((a, b) => a > b ? a : b) +
      3;

  /// Upstream iterates a frozenset; this is the order it produced.
  static const _cmds = [
    (0x51, <int>[]),
    (0x61, [0x00]),
  ];

  final Map<int, List<int>> _msg = {};
  int _expLen = _minLen;
  final Set<int> _expReply = {};

  SeplosV2Bms(super.device, [super.config]);

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
    _expReply
      ..clear()
      ..add(0x51);
    await awaitMsg(_cmd(0x51));
    final dat = _msg[0x51]!;
    if (dat.length <= _swvPos) {
      throw const FormatException('BMS data incomplete');
    }
    return {
      'model': b2str(dat.sl(26, 36)),
      'sw_version': '${dat[_swvPos - 1]}.${dat[_swvPos]}',
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length > _minLen &&
        data[0] == _head &&
        (frame.length >= _expLen || frame.isEmpty)) {
      final len = _minLen + data.u(5, 2);
      _expLen = len < BaseBms.maxMsgLen ? len : BaseBms.maxMsgLen;
      frame.clear();
    }
    frame.extend(data);

    if (frame.length < _expLen) return;
    if (frame.isEmpty || frame[frame.length - 1] != _tail) return;
    if (frame[1] != _rspVer) return;
    if (frame[4] != 0) return;
    if (!checkIntegrity(
      frame,
      (x) => crcXmodem(x.sl(1, -3)),
      (null, null),
      (-3, -1),
    )) {
      return;
    }
    _msg[frame[3]] = frame.bytes;
    if (_expReply.remove(frame[3])) msgEvent.set();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection();
    _expLen = _minLen;
  }

  static Uint8List _cmd(int cmd, {int address = 0, List<int> data = const []}) {
    assert(const {0x47, 0x51, 0x61, 0x62, 0x04}.contains(cmd));
    final f = [
      _head,
      _cmdVer,
      address,
      0x46,
      cmd,
      ...intTo(data.length, 2),
      ...data,
    ];
    return Uint8List.fromList([
      ...f,
      ...intTo(crcXmodem(f.sublist(1)), 2),
      _tail,
    ]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    for (final (cmd, data) in _cmds) {
      _expReply.add(cmd);
      await awaitMsg(_cmd(cmd, data: data));
    }

    final m61 = _msg[0x61]!, m51 = _msg[0x51]!;
    final result = <String, Object?>{};
    final cellCount = m61[_cellPos];
    result['cell_count'] = cellCount;
    final tempPos = _cellPos + cellCount * 2 + 1;
    if (m51.length <= _packPos || m61.length <= tempPos) {
      throw const FormatException('BMS data incomplete');
    }
    // extension pack count, only the main unit has one
    result['pack_count'] = m51[_packPos];
    final tempSensors = m61[tempPos];
    result['temp_sensors'] = tempSensors;
    final ctBlkLen = (cellCount + tempSensors) * 2 + 2;
    if (_gsmdLen + ctBlkLen > m61.length) {
      throw const FormatException('BMS data incomplete');
    }
    result.addAll(
      BaseBms.decodeData(_pfields, m61, start: _cellPos + ctBlkLen),
    );

    final statesPos =
        (_cellPos + ctBlkLen) + (cellCount + tempSensors) + (3 + 19);
    final cstAlarmPos = statesPos + 1;
    if (m61.length <= cstAlarmPos) {
      throw const FormatException('BMS data incomplete');
    }
    // switches and alarms of the main pack
    final states = m61[statesPos];
    result['dischrg_mosfet'] = states & 0x1 != 0;
    result['chrg_mosfet'] = states & 0x2 != 0;
    result['heater'] = states & 0x8 != 0;

    final balancePos = cstAlarmPos + 1 + m61[cstAlarmPos];
    final bl = (cellCount + 7) ~/ 8;
    result['balancer'] = intFrom(
      m61.sl(balancePos, balancePos + (bl < 8 ? bl : 8)),
    );

    final alarmEvt = m61[cstAlarmPos] < _prbMax ? m61[cstAlarmPos] : _prbMax;
    result['problem_code'] =
        intFrom(m61.sl(cstAlarmPos + 1, cstAlarmPos + 1 + alarmEvt)) & _prbMask;

    result['cell_voltages'] = BaseBms.cellVoltages(
      m61,
      cells: m61[_cellPos],
      start: 10,
    );
    result['temp_values'] = BaseBms.tempValues(
      m61,
      values: tempSensors,
      start: _cellPos + cellCount * 2 + 2,
      signed: false,
      offset: 2731,
      divider: 10,
      types: [
        ...List.filled(
          tempSensors - 2 < 0 ? 0 : tempSensors - 2,
          TempType.cell,
        ),
        TempType.ambient,
        TempType.mosfet,
      ],
    );
    _msg.clear();
    return result;
  }
}
