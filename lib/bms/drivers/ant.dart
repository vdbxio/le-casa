// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// ANT smart BMS (current generation, "ANT-BLE24..." / "ANT-BLE3...").

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

int antProblemCode(int x) =>
    ((const {0x1, 0x4, 0xF}.contains(x >> 8)) ? 0 : (x & 0xF00)) |
    ((const {0x1, 0x4, 0xB, 0xF}.contains(x & 0xF)) ? 0 : (x & 0xF));

class AntBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'ant_bms',
    info: const {'manufacturer': 'ANT', 'model': 'smart BMS'},
    matchers: [
      for (final p in ['ANT?BLE24*', 'ANT?BLE3*'])
        MatcherPattern(localName: p, serviceUuid: 'ffe0'),
    ],
    create: AntBms.new,
    acceptSecret: true,
    secretHint: 'Only if a password is set in the ANT BMS app.',
  );

  static const _head = [0x7E, 0xA1];
  static const _tail = [0xAA, 0x55];
  static const _minLen = 10;
  static const _cmdStat = 0x01;
  static const _cmdDev = 0x02;
  static const _cmdAuth = 0x23;
  static const _tempPos = 8;
  static const _maxTemps = 6;
  static const _cellCount = 9;
  static const _cellPos = 34;
  static const _maxCells = 32;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 38, 2, false, (x) => x / 100),
    BmsDp('current', 40, 2, true, (x) => x / 10),
    BmsDp('design_capacity', 50, 4, false, (x) => x ~/ 1000000),
    BmsDp('battery_level', 42, 2, false),
    BmsDp('battery_health', 44, 2, false),
    BmsDp('problem_code', 46, 2, false, antProblemCode),
    BmsDp('cycle_charge', 54, 4, false, (x) => x / 1e6),
    BmsDp('total_charge', 58, 4, false, (x) => x ~/ 1000),
    BmsDp('delta_voltage', 82, 2, false, (x) => x / 1000),
    BmsDp('power', 62, 4, true, (x) => x.toDouble()),
    BmsDp('chrg_mosfet', 46, 1, false, (x) => x == 0x1),
    BmsDp('dischrg_mosfet', 47, 1, false, (x) => x == 0x1),
    BmsDp('balancer', 48, 1, false, (x) => x & 0x4 != 0),
  ];

  Uint8List _msg = Uint8List(0);
  int _validReply = _cmdStat | 0x10;
  int _expLen = 0;

  AntBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  bool get acceptSecret => true;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe1';
  @override
  String get uuidTx => 'ffe1';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitMsg(_cmd(_cmdDev, 0x026C, 0x20));
    return {
      'hw_version': b2str(_msg.sl(6, 22)),
      'sw_version': b2str(_msg.sl(22, 38)),
    };
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    _expLen = 0;
    if (cfg.secret.isNotEmpty) {
      await awaitMsg(
        _cmd(_cmdAuth, 0x6A01, cfg.secret.length, ascii(cfg.secret)),
        waitForNotify: false,
      );
    }
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.startsWithBytes(_head) &&
        frame.length >= _expLen &&
        data.length >= _minLen) {
      frame.clear();
      _expLen = data[5] + _minLen;
    }
    frame.extend(data);

    if (frame.length < _expLen || frame.length < _minLen) return;
    if (frame[2] != _validReply) return;
    // the length of CMD_DEV replies is wrong, so it is not checked
    if (frame.length != _expLen && frame[2] != (_cmdDev | 0x10)) return;
    if (!frame.endsWithBytes(_tail)) return;
    if (!checkIntegrity(
      frame,
      crcModbus,
      (1, _expLen - 4),
      (_expLen - 4, _expLen - 2),
      little: true,
    )) {
      return;
    }
    _msg = frame.bytes;
    msgEvent.set();
  }

  static Uint8List _cmd(int cmd, int adr, int length, [List<int> data = const []]) {
    final f = [..._head, cmd & 0xFF, ...intTo(adr, 2, little: true), length & 0xFF, ...data];
    final crc = crcModbus(f.sublist(1));
    return Uint8List.fromList([...f, ...intTo(crc, 2, little: true), ..._tail]);
  }

  @override
  Future<void> awaitMsg(
    List<int> data, {
    CharSpec? char,
    bool waitForNotify = true,
    int maxSize = 0,
  }) {
    _validReply = data[2] | 0x10;
    return super.awaitMsg(
      data,
      char: char,
      waitForNotify: waitForNotify,
      maxSize: maxSize,
    );
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(_cmd(_cmdStat, 0, 0xBE));
    final result = <String, Object?>{};
    result['battery_charging'] = _msg[7] == 0x2;
    final cells = _msg[_cellCount] < _maxCells ? _msg[_cellCount] : _maxCells;
    result['cell_count'] = cells;
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: cells,
      start: _cellPos,
      little: true,
    );
    final temps = _msg[_tempPos] < _maxTemps ? _msg[_tempPos] : _maxTemps;
    result['temp_sensors'] = temps;
    result['temp_values'] = BaseBms.tempValues(
      _msg,
      values: temps + 2, // + MOSFET, balancer temperature
      start: _cellPos + cells * 2,
      little: true,
      types: [
        for (var i = 0; i < temps; i++) TempType.generic,
        TempType.mosfet,
        TempType.balancer,
      ],
    );
    result.addAll(
      BaseBms.decodeData(_fields, _msg, little: true, start: (temps + cells) * 2),
    );
    return result;
  }
}
