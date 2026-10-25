// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Daly smart BMS (D2 and 0x81 protocol generations).

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class _Cmd {
  final int fct, adr, length;
  const _Cmd(this.fct, this.adr, this.length);
}

class _ProtoDef {
  final int resp;
  final int maxCells;
  final List<_Cmd> cmds;
  final _Cmd info;
  final _Cmd? mos;
  final List<BmsDp> fields;
  const _ProtoDef(
    this.resp,
    this.maxCells,
    this.cmds,
    this.info,
    this.mos,
    this.fields,
  );
}

class DalyBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'daly_bms',
    info: {'manufacturer': 'Daly', 'model': 'smart BMS'},
    matchers: [
      MatcherPattern(localName: 'DL-*', serviceUuid: 'fff0'),
      MatcherPattern(manufacturerId: 0x102),
      MatcherPattern(manufacturerId: 0x104),
      MatcherPattern(manufacturerId: 0x302),
      MatcherPattern(manufacturerId: 0x303),
      MatcherPattern(manufacturerId: 0x402),
    ],
    create: DalyBms.new,
  );

  static const _fctRd = 0x03;
  static const _headLen = 3;
  static const _crcLen = 2;
  static const _mosTempPos = _headLen + 8;
  static const _d2 = 0xD2;
  static const _x81 = 0x81;

  static final Map<int, _ProtoDef> _protos = {
    _d2: _ProtoDef(
      0xD2,
      32,
      const [_Cmd(_fctRd, 0x0, 62)],
      const _Cmd(_fctRd, 0xA9, 32),
      const _Cmd(_fctRd, 0x3E, 0x9),
      [
        BmsDp('voltage', 80, 2, false, (x) => x / 10, 62),
        BmsDp('current', 82, 2, false, (x) => (x - 30000) / 10, 62),
        BmsDp('battery_level', 84, 2, false, (x) => x / 10, 62),
        BmsDp('cycle_charge', 96, 2, false, (x) => x / 10, 62),
        BmsDp('cell_count', 98, 2, false, (x) => x < 32 ? x : 32, 62),
        BmsDp('temp_sensors', 100, 2, false, (x) => x < 8 ? x : 8, 62),
        BmsDp('cycles', 102, 2, false, (x) => x, 62),
        BmsDp('delta_voltage', 112, 2, false, (x) => x / 1000, 62),
        BmsDp('problem_code', 116, 8, false, (x) => x, 62),
        BmsDp('balancer', 104, 2, false, (x) => x, 62),
        BmsDp('chrg_mosfet', 106, 2, false, (x) => x != 0, 62),
        BmsDp('dischrg_mosfet', 108, 2, false, (x) => x != 0, 62),
      ],
    ),
    _x81: _ProtoDef(
      0x51,
      48,
      const [_Cmd(_fctRd, 0x0, 64), _Cmd(_fctRd, 0x41, 62)],
      const _Cmd(_fctRd, 0x178, 74),
      null,
      [
        BmsDp('voltage', 112, 2, false, (x) => x / 10, 64),
        BmsDp('current', 114, 2, false, (x) => (x - 30000) / 10, 64),
        BmsDp('battery_level', 116, 2, false, (x) => x / 10, 64),
        BmsDp('cell_count', 120, 2, false, (x) => x < 48 ? x : 48, 64),
        BmsDp('cycle_charge', 20, 2, false, (x) => x / 10, 62),
        BmsDp('temp_sensors', 122, 2, false, (x) => x < 8 ? x : 8, 64),
        BmsDp('cycles', 22, 2, false, (x) => x, 62),
        BmsDp('problem_code', 88, 4, false, (x) => x, 62),
        BmsDp('balancer', 24, 2, false, (x) => x, 62),
        BmsDp('chrg_mosfet', 34, 2, false, (x) => x != 0, 62),
        BmsDp('dischrg_mosfet', 36, 2, false, (x) => x != 0, 62),
        BmsDp('heater', 40, 2, false, (x) => x != 0, 62),
      ],
    ),
  };

  int _proto = _d2;
  Uint8List _msg = Uint8List(0);
  bool? _mosAvail;

  DalyBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'fff2';

  /// Which protocol generation answered: "D2" or "0x81".
  String get protocol => _proto == _d2 ? 'D2' : '0x81';

  Uint8List _cmd(_Cmd c) =>
      BaseBms.cmdModbus(devId: _proto, fct: c.fct, addr: c.adr, count: c.length);

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitMsg(_cmd(_protos[_proto]!.info));
    if (_msg[0] == _protos[_x81]!.resp) {
      return {
        'sw_version': b2str(_msg.sl(3, 31)),
        'hw_version': b2str(_msg.sl(31, 45)),
        'serial_number': b2str(_msg.sl(45, 59)),
      };
    }
    return {
      'sw_version': b2str(_msg.sl(3, 19)),
      'hw_version': b2str(_msg.sl(19, 35)),
    };
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    for (final p in _protos.keys) {
      _proto = p;
      try {
        await awaitMsg(_cmd(_protos[p]!.cmds[0]));
        if (_protos[p]!.mos == null) _mosAvail = false;
        return;
      } on TimeoutException {
        // try the next protocol
      }
    }
    _proto = _d2;
    throw TimeoutException('Daly BMS answered neither D2 nor 0x81');
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length < _headLen ||
        data[0] != _protos[_proto]!.resp ||
        data[1] != _fctRd ||
        data[2] != data.length - _headLen - _crcLen) {
      return;
    }
    if (!checkIntegrity(data, crcModbus, (null, -2), (-2, null), little: true)) {
      return;
    }
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    final result = <String, Object?>{};
    final def = _protos[_proto]!;
    if (_mosAvail != false && def.mos != null) {
      try {
        await awaitMsg(_cmd(def.mos!));
        final raw = _msg.sl(_mosTempPos, _mosTempPos + 2);
        if (_mosAvail == null &&
            (bytesEq(raw, [0, 0]) || bytesEq(raw, [0xFF, 0xFF]))) {
          _mosAvail = false;
        } else {
          result['temp_values'] = <TempSensor>[
            TempSensor(intFrom(raw) - 40, TempType.mosfet),
          ];
          _mosAvail = true;
        }
      } on TimeoutException {
        _mosAvail = false;
      }
    }

    final rtMsgs = <int, List<int>>{};
    for (final cmd in def.cmds) {
      await awaitMsg(_cmd(cmd));
      if (_msg[2] ~/ 2 != cmd.length) break;
      rtMsgs[cmd.length] = _msg;
    }
    if (rtMsgs.length != def.cmds.length) {
      throw const FormatException('BMS data incomplete.');
    }

    result.addAll(BaseBms.decodeData(def.fields, rtMsgs, start: _headLen));

    final rt1 = rtMsgs.values.first;
    final temps = (result['temp_values'] as List<TempSensor>?) ?? <TempSensor>[];
    temps.addAll(
      BaseBms.tempValues(
        rt1,
        values: (result['temp_sensors'] as int?) ?? 0,
        start: def.maxCells * 2 + _headLen,
        offset: 40,
      ),
    );
    result['temp_values'] = temps;
    result['cell_voltages'] = BaseBms.cellVoltages(
      rt1,
      cells: (result['cell_count'] as int?) ?? 0,
      start: _headLen,
    );
    return result;
  }
}
