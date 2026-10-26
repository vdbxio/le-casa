// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Renogy Bluetooth batteries (BT-TH module). Modbus over BLE.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class RenogyBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'renogy_bms',
    info: {'manufacturer': 'Renogy', 'model': 'Bluetooth battery'},
    matchers: [MatcherPattern(localName: 'BT-TH-*', serviceUuid: 'ffd0')],
    create: RenogyBms.new,
  );

  static const _head = [0x30, 0x03]; // start, read function
  static const _crcPos = -2;
  static const _tempPos = 37;
  static const _cellPos = 3;
  static const _minLen = 5;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 5, 2, false, (x) => x / 10),
    BmsDp('current', 3, 2, true, (x) => x / 100),
    BmsDp('design_capacity', 11, 4, false, (x) => x ~/ 1000),
    BmsDp('cycle_charge', 7, 4, false, (x) => x / 1000),
    BmsDp('cycles', 15, 2, false),
  ];

  Uint8List msg = Uint8List(0);

  List<BmsDp> get fields => _fields;

  RenogyBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFD0), uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'ffd1';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitMsg(BaseBms.cmdModbus(devId: 0x30, addr: 0x13F0, count: 0x1C));
    return {
      'serial_number': b2str(msg.sl(15, 31)),
      'name': b2str(msg.sl(39, 55)),
      'sw_version': b2str(msg.sl(55, 59)),
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (!data.startsWithBytes(_head) || data.length < 3) return;
    if (data[2] + _minLen != data.length) return;
    if (!checkIntegrity(
      data,
      crcModbus,
      (null, _crcPos),
      (_crcPos, null),
      little: true,
    )) {
      return;
    }
    msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  static int _int16(List<int> data, int pos) => intFrom(data.sl(pos, pos + 2));

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(BaseBms.cmdModbus(devId: 0x30, addr: 0x13B2, count: 0x7));
    final result = BaseBms.decodeData(fields, msg);

    await awaitMsg(BaseBms.cmdModbus(devId: 0x30, addr: 0x1388, count: 0x22));
    final cellCount = _int16(msg, _cellPos);
    result['cell_count'] = cellCount;
    result['cell_voltages'] = BaseBms.cellVoltages(
      msg,
      cells: cellCount < 16 ? cellCount : 16,
      start: _cellPos + 2,
      divider: 10,
    );
    final tempSensors = _int16(msg, _tempPos);
    result['temp_sensors'] = tempSensors;
    result['temp_values'] = BaseBms.tempValues(
      msg,
      values: tempSensors < 16 ? tempSensors : 16,
      start: _tempPos + 2,
      divider: 10,
    );

    await awaitMsg(BaseBms.cmdModbus(devId: 0x30, addr: 0x13EC, count: 0x8));
    if (msg.length < _minLen + 0x8 * 2) {
      throw const FormatException('BMS data incomplete.');
    }
    // 14 bytes, wider than a Dart int
    final pc = BigInt.parse(msg.sl(3, 17).hex, radix: 16) & ~BigInt.from(0xE);
    result['problem_code'] = pc.isValidInt ? pc.toInt() : pc;
    result['chrg_mosfet'] = msg[16] & 0x2 != 0;
    result['dischrg_mosfet'] = msg[16] & 0x4 != 0;
    result['heater'] = msg[17] & 0x20 != 0;
    return result;
  }
}
