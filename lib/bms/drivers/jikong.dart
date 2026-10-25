// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Jikong (JK) smart BMS, JK02 protocol (24S and 32S).

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class JikongBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'jikong_bms',
    info: const {'manufacturer': 'Jikong', 'model': 'smart BMS'},
    matchers: [
      for (final id in [0x0B65, 0x4B4A])
        MatcherPattern(serviceUuid: 'ffe0', manufacturerId: id),
    ],
    create: JikongBms.new,
  );

  static const _headRsp = [0x55, 0xAA, 0xEB, 0x90];
  static const _headCmd = [0xAA, 0x55, 0x90, 0xEB]; // byte order!
  static final _readyMsg = [
    ..._headCmd,
    0xC8,
    0x01,
    0x01,
    ...List.filled(12, 0),
    0x44,
  ];
  static const _btModuleMsg = [0x41, 0x54, 0x0D, 0x0A]; // AT\r\n
  static const _typePos = 4;
  static const _infoLen = 300;
  // JK02_32S; JK02_24S is 32 bytes earlier
  static final _fields = <BmsDp>[
    BmsDp('voltage', 150, 4, false, (x) => x / 1000),
    BmsDp('current', 158, 4, true, (x) => x / 1000),
    BmsDp('problem_code', 166, 4, false),
    BmsDp('balance_current', 170, 2, true, (x) => x / 1000),
    BmsDp('balancer', 172, 1, false, (x) => x != 0),
    BmsDp('battery_level', 173, 1, false),
    BmsDp('cycle_charge', 174, 4, false, (x) => x / 1000),
    BmsDp('design_capacity', 178, 4, false, (x) => x ~/ 1000),
    BmsDp('cycles', 182, 4, false),
    BmsDp('battery_health', 190, 1, false),
    BmsDp('chrg_mosfet', 198, 1, false, (x) => x != 0),
    BmsDp('dischrg_mosfet', 199, 1, false, (x) => x != 0),
    BmsDp('temp_sensors', 214, 1, false),
    BmsDp('heater', 215, 1, false, (x) => x != 0),
    BmsDp('heater_current', 236, 2, true, (x) => x / 1000),
  ];

  Uint8List _msg = Uint8List(0);
  GattChar? _writeChar;
  int _swVersion = 0;
  int _protOffset = 0;
  int _validReply = 0x02;
  bool _bmsReady = false;

  JikongBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe1';
  @override
  String get uuidTx => 'ffe1';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    _validReply = 0x03;
    try {
      await awaitMsg(_cmd(0x97), char: _writeChar);
    } finally {
      _validReply = 0x02;
    }
    return {
      'model': b2str(_msg.sl(6, 22)),
      'hw_version': b2str(_msg.sl(22, 30)),
      'sw_version': b2str(_msg.sl(30, 38)),
      'name': b2str(_msg.sl(46, 62)),
      'serial_number': b2str(_msg.sl(86, 94)),
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    var d = data;
    if (d.startsWithBytes(_btModuleMsg)) {
      d = d.sl(_btModuleMsg.length);
      if (d.isEmpty) return;
    }
    if ((frame.length >= _infoLen &&
            (d.startsWithBytes(_headRsp) || d.startsWithBytes(_headCmd))) ||
        !frame.startsWithBytes(_headRsp)) {
      frame.clear();
    }
    frame.extend(d);

    if (frame.length < _infoLen && !frame.startsWithBytes(_readyMsg)) return;
    if (frame[_typePos] != _validReply) return;

    if (frame.endsWithBytes(_btModuleMsg)) {
      frame.del(frame.length - _btModuleMsg.length, frame.length);
    }
    // v19.05 attaches the ready message to its last answers
    if (frame.sl(_infoLen).startsWithBytes(_readyMsg)) _bmsReady = true;
    if (frame.length > _infoLen) frame.del(_infoLen, frame.length);

    if (!checkIntegrity(frame, crcSum, (null, -1), (-1, null))) return;
    _msg = frame.bytes;
    msgEvent.set();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    GattChar? notifyChar;
    _writeChar = null;
    _bmsReady = false;
    final rx = normalizeUuid(uuidRx), tx = normalizeUuid(uuidTx);
    for (final c in client.characteristics) {
      if (c.uuid == rx || c.uuid == tx) {
        if (c.canNotify) notifyChar = c;
        if (c.canWrite || c.canWriteWithoutResponse) _writeChar = c;
      }
    }
    if (notifyChar == null || _writeChar == null) {
      await disconnect();
      throw UnsupportedDeviceException(
        'Failed to detect characteristics from $name.',
      );
    }
    await super.initConnection(notifyChar);

    // wait for the BMS to be ready (0xC8)
    final bmsInfo = await fetchDeviceInfo();
    try {
      _swVersion = lstr2int(bmsInfo['sw_version'] ?? '0');
    } on FormatException {
      debugPrint('bms: $name: invalid sw_version ${bmsInfo['sw_version']}, assuming 0');
      _swVersion = 0;
    }
    _protOffset = _swVersion < 11 ? -32 : 0;
    if (!_bmsReady) {
      _validReply = 0xC8; // ready confirmation
      await waitEventFor(timeout);
    }
    _validReply = 0x02; // cell information
  }

  static Uint8List _cmd(int cmd, [List<int> value = const []]) {
    assert(value.length <= 13);
    final f = [..._headCmd, cmd, value.length, ...value, ...List.filled(13 - value.length, 0)];
    return Uint8List.fromList([...f, crcSum(f)]);
  }

  List<(int, int, TempType)> _tempPos() {
    const v11 = [
      (0, 144, TempType.mosfet),
      (1, 162, TempType.generic),
      (2, 164, TempType.generic),
      (3, 254, TempType.mosfet),
    ];
    if (_swVersion >= 14) {
      return [...v11, (4, 256, TempType.generic), (5, 258, TempType.generic)];
    }
    if (_swVersion >= 11) return v11;
    return const [
      (0, 130, TempType.generic),
      (1, 132, TempType.generic),
      (2, 134, TempType.mosfet),
    ];
  }

  static List<TempSensor> _tempSensors(
    List<int> data,
    List<(int, int, TempType)> pos,
    int mask,
  ) => [
    for (final (idx, p, t) in pos)
      if (mask & (1 << idx) != 0)
        if (intFrom(data.sl(p, p + 2), little: true, signed: true) case final v
            when v != -2000)
          TempSensor(v / 10, t),
  ];

  static int _bitCount(int v) {
    var n = 0;
    for (var x = v; x != 0; x >>= 1) {
      n += x & 1;
    }
    return n;
  }

  static BmsSample _convData(List<int> data, int offs, int swMajv) {
    final result = BaseBms.decodeData(_fields, data, little: true, start: offs);
    final h = offs >> 1;
    result['cell_count'] = _bitCount(intFrom(data.sl(70 + h, 74 + h), little: true));
    result['delta_voltage'] = intFrom(data.sl(76 + h, 78 + h), little: true) / 1000;
    if (swMajv >= 15) {
      final m = data[280 + offs];
      result['battery_mode'] = BmsMode.values.firstWhere(
        (b) => b.code == m,
        orElse: () => BmsMode.unknown,
      );
    }
    return result;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    if (!msgEvent.isSet || _msg[4] != 0x02) {
      // request cell info unless the BMS keeps publishing it
      await awaitMsg(_cmd(0x96), char: _writeChar);
    }
    final data = _convData(_msg, _protOffset, _swVersion);
    data['temp_values'] = _tempSensors(
      _msg,
      _tempPos(),
      (data['temp_sensors'] as int?) ?? 0,
    );
    final pc = (data['problem_code'] as int?) ?? 0;
    data['problem_code'] = _protOffset != 0 ? pc >> 16 : pc & 0xFFFF;
    data['cell_voltages'] = BaseBms.cellVoltages(
      _msg,
      cells: (data['cell_count'] as int?) ?? 0,
      start: 6,
      little: true,
    );
    msgEvent.clear();
    return data;
  }
}
