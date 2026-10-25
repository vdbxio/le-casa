// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Neey (Heltec, EnerKey) active balancer. Values are 32-bit floats.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

/// A field read with Python's struct format `<f` (float) or `B` (byte).
class _Fp {
  final String key;
  final int pos;
  final bool isFloat;
  final Object? Function(num) fct;
  const _Fp(this.key, this.pos, this.isFloat, this.fct);
}

class NeeyBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'neey_bms',
    info: const {'manufacturer': 'Neey', 'model': 'Balancer'},
    matchers: [
      for (final p in ['EK-*', 'GW-*'])
        MatcherPattern(localName: p, serviceUuid: 'fee7'),
    ],
    create: NeeyBms.new,
  );

  static const _headRsp = [0x55, 0xAA, 0x11, 0x01]; // start, address, read
  static const _headCmd = [0xAA, 0x55, 0x11, 0x01];
  static const _tail = 0xFF;
  static const _typePos = 4;
  static const _minFrame = 10;

  static double _r3(num x) => pyRound(x, 3);
  static final _fields = <_Fp>[
    _Fp('voltage', 201, true, _r3),
    _Fp('delta_voltage', 209, true, _r3),
    _Fp('problem_code', 216, false, (x) => const {1, 3, 7, 8, 9, 10, 11}.contains(x) ? x : 0),
    _Fp('balancer', 216, false, (x) => x == 0x5),
    _Fp('balance_current', 218, true, _r3),
    _Fp('current', 222, true, _r3),
    _Fp('design_capacity', 242, true, (x) => x.truncate()),
    _Fp('cycle_charge', 246, true, _r3),
    _Fp('battery_level', 250, true, _r3),
  ];
  static final _fieldsV1 = [
    ..._fields.take(4),
    _Fp('balance_current', 217, true, _r3),
  ];

  int _expLen = _minFrame;
  Uint8List _msg = Uint8List(0);
  String _proto = 'v1';
  int _validReply = 0x02;

  NeeyBms(super.device, [super.config]);

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
    _validReply = 0x01;
    await awaitMsg(_cmd(0x01));
    _validReply = 0x02;
    final model = b2str(_msg.sl(8, 24));
    if (model.startsWith('EK-B')) _proto = 'v2';
    return {
      'model': model,
      'hw_version': b2str(_msg.sl(24, 32)),
      'sw_version': b2str(_msg.sl(32, 40)),
    };
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if ((frame.length >= _expLen || !frame.startsWithBytes(_headRsp)) &&
        data.startsWithBytes(_headRsp)) {
      frame.clear();
      final len = data.u(6, 2, little: true);
      _expLen = len > _minFrame ? len : _minFrame;
    }
    frame.extend(data);

    if (frame.length < _expLen) return;
    if (!frame.startsWithBytes(_headRsp)) {
      frame.clear();
      return;
    }
    if (frame.length > _expLen) frame.del(_expLen, frame.length);
    if (frame[frame.length - 1] != _tail) {
      frame.clear();
      return;
    }
    if (frame[_typePos] != _validReply) return;
    if (!checkIntegrity(frame, crcSum, (null, -2), (-2, -1))) {
      frame.clear();
      return;
    }
    _msg = frame.bytes;
    msgEvent.set();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    await fetchDeviceInfo();
    _validReply = 0x02; // cell information
  }

  static Uint8List _cmd(int cmd, [int reg = 0, List<int> value = const []]) {
    assert(value.length <= 11);
    final f = [..._headCmd, cmd, reg & 0xFF, 0x14, ...value, ...List.filled(11 - value.length, 0)];
    return Uint8List.fromList([...f, crcSum(f), _tail]);
  }

  /// struct.unpack_from; throws [RangeError] where Python raises struct.error.
  static double _f32(Uint8List d, int pos) {
    if (pos < 0 || pos + 4 > d.length) throw RangeError('unpack_from out of range');
    return ByteData.sublistView(d).getFloat32(pos, Endian.little);
  }

  static int _u8(Uint8List d, int pos) {
    if (pos < 0 || pos + 1 > d.length) throw RangeError('unpack_from out of range');
    return d[pos];
  }

  static BmsSample _convData(List<_Fp> fields, Uint8List data) {
    final result = <String, Object?>{};
    for (final f in fields) {
      final num value = f.isFloat ? _f32(data, f.pos) : _u8(data, f.pos);
      if (value.isFinite) result[f.key] = f.fct(value);
    }
    return result;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    if (!msgEvent.isSet || _msg[4] != 0x02) {
      // request cell info unless the balancer keeps publishing it
      await awaitMsg(_cmd(0x02));
    }
    try {
      final data = _convData(_proto == 'v2' ? _fields : _fieldsV1, _msg);
      final (n, start) = _proto == 'v2' ? (4, 226) : (2, 221);
      data['temp_values'] = [
        for (var i = 0; i < n; i++) TempSensor(pyRound(_f32(_msg, start + i * 4), 2)),
      ];
      data['cell_voltages'] = [
        for (var i = 0; i < 24; i++)
          if (_f32(_msg, 9 + i * 4) case final v when v != 0) pyRound(v, 3),
      ];
      return data;
    } on RangeError {
      throw const FormatException('BMS data incomplete.');
    } finally {
      msgEvent.clear();
    }
  }
}
