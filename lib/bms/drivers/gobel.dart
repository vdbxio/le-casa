// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Gobel Power BLE BMS: Modbus RTU over BLE.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class GobelBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'gobel_bms',
    info: {'manufacturer': 'Gobel Power', 'model': 'BLE BMS'},
    matchers: [
      MatcherPattern(localName: 'BMS-[0-9A-F]*'),
      MatcherPattern(
        localName: 'B[0-9][0-9]*',
        manufacturerId: 65535,
        manufacturerDataStart: [0x4E],
      ),
    ],
    create: GobelBms.new,
  );

  static const _slaveAddr = 0x01;
  static const _funcRead = 0x03;
  static const _minFrameLen = 5; // addr + func + len + 2 * crc
  static const _maxCells = 32;
  static const _maxTemp = 8;
  static const _rdStatus = (0x0000, 0x003B);
  static const _rdDevInfo = (0x00AA, 0x0023);
  static final _fields = <BmsDp>[
    BmsDp('current', 0, 2, true, (x) => x / 100),
    BmsDp('voltage', 2, 2, false, (x) => x / 100),
    BmsDp('battery_level', 4, 2, false),
    BmsDp('battery_health', 6, 2, false),
    BmsDp('cycle_charge', 8, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 10, 2, false, (x) => x ~/ 100),
    BmsDp('cycles', 14, 2, false),
    BmsDp('problem_code', 16, 6, false),
    BmsDp('chrg_mosfet', 28, 2, false, (x) => x & 0x4000 != 0),
    BmsDp('dischrg_mosfet', 28, 2, false, (x) => x & 0x8000 != 0),
    BmsDp('cell_count', 30, 2, false, (x) => x & 0xFF),
    BmsDp('temp_sensors', 92, 2, false, (x) => x & 0xFF),
  ];
  static const _cellvStart = 35;
  static const _tempStart = 97;
  static const _tempMosOffset = 117;

  Uint8List _msg = Uint8List(0);

  GobelBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['00002760-08c2-11e1-9073-0e8ac72e1001'];
  @override
  String get uuidRx => '00002760-08c2-11e1-9073-0e8ac72e0002';
  @override
  String get uuidTx => '00002760-08c2-11e1-9073-0e8ac72e0001';

  static Uint8List _cmd((int, int) c) =>
      BaseBms.cmdModbus(devId: 0x1, fct: 0x3, addr: c.$1, count: c.$2);

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    final info = await super.fetchDeviceInfo();
    try {
      await awaitMsg(_cmd(_rdDevInfo));
    } on TimeoutException {
      return info;
    }
    if (_msg.length >= 65) {
      info.addAll({
        'sw_version': b2str(_msg.sl(3, 21)),
        'serial_number': b2str(_msg.sl(23, 43)),
        'model_id': b2str(_msg.sl(43, 63)),
      });
    }
    return info;
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length >= 2 && data[0] == _slaveAddr) {
      if (data[1] != _funcRead && data[1] != (_funcRead | 0x80)) return;
      frame.clear();
    } else if (frame.isEmpty) {
      return;
    }
    frame.extend(data);

    if (frame.length < _minFrameLen) return;
    if (frame[1] == (_funcRead | 0x80)) {
      frame.clear(); // Modbus error response
      return;
    }
    final expectedLen = _minFrameLen + frame[2];
    if (frame.length < expectedLen) return;
    frame.del(expectedLen, frame.length);

    if (!checkIntegrity(frame, crcModbus, (null, -2), (-2, null), little: true)) {
      frame.clear();
      return;
    }
    _msg = frame.bytes;
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(_cmd(_rdStatus));
    if (_msg[2] != _rdStatus.$2 * 2) return {};

    final result = BaseBms.decodeData(_fields, _msg, start: 3);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: ((result['cell_count'] as int?) ?? 0).clamp(0, _maxCells),
      start: _cellvStart,
    );
    final temps = BaseBms.tempValues(
      _msg,
      values: ((result['temp_sensors'] as int?) ?? 0).clamp(0, _maxTemp),
      start: _tempStart,
      divider: 10,
    );
    // 0xFFFF means there is no MOSFET sensor
    final mos = BaseBms.tempValues(
      _msg,
      start: _tempMosOffset,
      divider: 10,
      types: const [TempType.mosfet],
    );
    if (mos[0].value != -0.1) temps.add(mos[0]);
    result['temp_values'] = temps;
    return result;
  }
}
