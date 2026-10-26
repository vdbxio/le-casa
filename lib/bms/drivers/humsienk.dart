// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Humsienk BMC.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class HumsienkBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'humsienk_bms',
    info: const {'manufacturer': 'Humsienk', 'model': 'BMC'},
    matchers: [
      for (final p in ['HS*', 'ECO????', 'DCH????'])
        MatcherPattern(localName: p, serviceUuid: '0001'),
    ],
    create: HumsienkBms.new,
  );

  static const _head = 0xAA;
  static const _minLen = 5;
  // bits 7, 15, 23 are charge FET, heater, discharge FET
  static const _alarmMask = 0xFF7F7F7F;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 3, 4, false, (x) => x / 1000, 0x21),
    BmsDp('current', 7, 4, true, (x) => x / 1000, 0x21),
    BmsDp('battery_level', 11, 1, false, (x) => x, 0x21),
    BmsDp('battery_health', 12, 1, false, (x) => x, 0x21),
    BmsDp('cycle_charge', 13, 4, false, (x) => x / 1000, 0x21),
    BmsDp('design_capacity', 17, 4, false, (x) => pyRoundInt(x / 1000), 0x21),
    BmsDp('cycles', 21, 2, false, (x) => x, 0x21),
    BmsDp('chrg_mosfet', 7, 1, false, (x) => x & 0x80 != 0, 0x20),
    BmsDp('heater', 8, 1, false, (x) => x & 0x80 != 0, 0x20),
    BmsDp('dischrg_mosfet', 9, 1, false, (x) => x & 0x80 != 0, 0x20),
    BmsDp('balancer', 11, 3, false, (x) => x, 0x20), // bit 0 = cell 1
    BmsDp('problem_code', 7, 4, false, (x) => x & _alarmMask, 0x20),
  ];

  /// Upstream iterates a frozenset; this is the order it produced.
  static const _cmds = [0x22, 0x21, 0x20];

  final Map<int, List<int>> _msg = {};
  int _validReply = 0x00;

  HumsienkBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0x0001)];
  @override
  String get uuidRx => '0003';
  @override
  String get uuidTx => '0002';

  static Uint8List _cmd(int cmd) {
    final f = [cmd, 0x00];
    return Uint8List.fromList([
      _head,
      ...f,
      ...intTo(crcSum(f), 2, little: true),
    ]);
  }

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    for (final cmd in [0x11, 0xF5]) {
      await awaitMsg(_cmd(cmd));
    }
    return {
      'model': b2str(_msg[0x11]!.sl(3, -2)),
      'hw_version': b2str(_msg[0xF5]!.sl(3, -2)),
    };
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    await awaitMsg(_cmd(0x00));
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.isEmpty || data[0] != _head || data.length < _minLen) return;
    if (data.length != data[2] + _minLen) return;
    if (data[1] != _validReply) return;
    if (!checkIntegrity(
      data,
      (x) => crcSum(x, 2),
      (1, -2),
      (-2, null),
      little: true,
    )) {
      return;
    }
    _msg[data[1]] = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<void> awaitMsg(
    List<int> data, {
    CharSpec? char,
    bool waitForNotify = true,
    int maxSize = 0,
  }) {
    _validReply = data[1];
    return super.awaitMsg(
      data,
      char: char,
      waitForNotify: waitForNotify,
      maxSize: maxSize,
    );
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    _msg.clear();
    for (final cmd in _cmds) {
      await awaitMsg(_cmd(cmd));
    }
    final result = BaseBms.decodeData(_fields, _msg, little: true);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg[0x22]!,
      cells: 24,
      start: 3,
      little: true,
    );
    result['temp_values'] = BaseBms.tempValues(
      _msg[0x21]!,
      values: 6,
      start: 23,
      size: 1,
      little: true,
      types: const [
        TempType.cell,
        TempType.cell,
        TempType.cell,
        TempType.cell,
        TempType.mosfet,
        TempType.ambient,
      ],
    );
    // cell disconnect bitmap
    if (_msg[0x20]!.sl(14, 17).any((b) => b != 0)) result['problem'] = true;
    return result;
  }
}
