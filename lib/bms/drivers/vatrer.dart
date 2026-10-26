// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Vatrer smart BMS: Modbus over the Nordic UART service.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class VatrerBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'vatrer_bms',
    info: const {'manufacturer': 'Vatrer', 'model': 'smart BMS'},
    matchers: const [
      // name is likely YYMMDDVVVAAAAxx (date, V, Ah)
      MatcherPattern(
        localName: '[2-9]???[0-3]?512??00??',
        serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      ),
    ],
    create: VatrerBms.new,
  );

  static const _head = [0x02, 0x03];
  static const _frameLen = 5;
  static const _maxCells = 0x1F;
  static const _maxTemp = 6;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 3, 2, false, (x) => x / 100, 0x28),
    BmsDp('current', 5, 4, true, (x) => x / 100, 0x28),
    BmsDp('battery_level', 9, 2, false, (x) => x, 0x28),
    BmsDp('battery_health', 17, 2, false, (x) => x, 0x28),
    BmsDp('cycle_charge', 11, 2, false, (x) => x / 100, 0x28),
    BmsDp(
      'cell_count',
      3,
      2,
      false,
      (x) => x < _maxCells ? x : _maxCells,
      0x3E,
    ),
    BmsDp(
      'temp_sensors',
      3,
      2,
      false,
      (x) => x < _maxTemp ? x : _maxTemp,
      0x24,
    ),
    BmsDp('cycles', 15, 2, false, (x) => x, 0x28),
    BmsDp('delta_voltage', 29, 2, false, (x) => x / 1000, 0x28),
    BmsDp.bytes('problem', 17, 15, (b) => b.any((v) => v != 0), 0x24),
    BmsDp('chrg_mosfet', 32, 1, false, (x) => x & 0x10 != 0, 0x24),
    BmsDp('dischrg_mosfet', 32, 1, false, (x) => x & 0x20 != 0, 0x24),
    BmsDp('balancer', 35, 4, false, (x) => x, 0x24),
  ];
  static final Set<int> _resps = {for (final f in _fields) f.idx};
  // upstream iterates a frozenset; this is its order
  static const _cmds = [(0x15, 0x1F), (0x0, 0x14), (0x34, 0x12)];

  final Map<int, List<int>> msg = {};

  VatrerBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['6e400001-b5a3-f393-e0a9-e50e24dcca9e'];
  @override
  String get uuidRx => '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  @override
  String get uuidTx => '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (!data.startsWithBytes(_head)) return;
    if (data.length < _frameLen || data.length != data[2] + _frameLen) return;
    if (!checkIntegrity(
      data,
      crcModbus,
      (null, -2),
      (-2, null),
      little: true,
    )) {
      return;
    }
    msg[data[2]] = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    msg.clear();
    for (final (addr, length) in _cmds) {
      await awaitMsg(BaseBms.cmdModbus(devId: 0x2, addr: addr, count: length));
    }
    if (!_resps.every(msg.containsKey)) {
      throw TimeoutException('BMS data incomplete.');
    }
    final result = BaseBms.decodeData(_fields, msg);
    result['cell_voltages'] = BaseBms.cellVoltages(
      msg[0x3E]!,
      cells: (result['cell_count'] as int?) ?? 0,
      start: 5,
    );
    final t = (result['temp_sensors'] as int?) ?? 0;
    result['temp_values'] = BaseBms.tempValues(
      msg[0x24]!,
      values: t + 2,
      start: 5,
      types: [...List.filled(t + 1, TempType.generic), TempType.mosfet],
    );
    return result;
  }
}
