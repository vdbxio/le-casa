// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Seplos smart BMS V3. Modbus, with one sub-address per battery pack.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class SeplosBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'seplos_bms',
    info: const {'manufacturer': 'Seplos', 'model': 'smart BMS V3'},
    matchers: [
      for (final p in ['SP??B*', 'XZHX*', 'CSY*', 'SP1??B*', 'ST*'])
        MatcherPattern(localName: p, serviceUuid: 'fff0'),
    ],
    create: SeplosBms.new,
  );

  static const _cmdRead = [0x01, 0x04];
  static const _headLen = 3;
  static const _crcLen = 2;
  static const _piaLen = 0x11;
  static const _pibLen = 0x1A;
  static const _eiaLen = _pibLen;
  static const _eibLen = 0x16;
  static const _eicLen = 0x5;
  static const _tempStart = _headLen + 32;
  static final _prbMask = BigInt.parse('FFFF00FF00FF0000FF', radix: 16);
  // fct, address, count
  static const _query = [
    (0x4, 0x2000, _eiaLen),
    (0x4, 0x2100, _eibLen),
    (0x1, 0x2200, _eicLen),
  ];
  static const _pquery = [(0x4, 0x1000, _piaLen), (0x4, 0x1100, _pibLen)];
  static final _fields = <BmsDp>[
    BmsDp('voltage', 0, 4, false, (x) => swap32(x) / 100, _eiaLen),
    BmsDp('current', 4, 4, true, (x) => swap32(x, signed: true) / 10, _eiaLen),
    BmsDp('cycle_charge', 8, 4, false, (x) => swap32(x) / 100, _eiaLen),
    BmsDp('design_capacity', 20, 4, false, (x) => swap32(x) ~/ 100, _eiaLen),
    BmsDp('pack_count', 44, 2, false, (x) => x, _eiaLen),
    BmsDp('cycles', 46, 2, false, (x) => x, _eiaLen),
    BmsDp('battery_level', 48, 2, false, (x) => x / 10, _eiaLen),
    BmsDp('battery_health', 50, 2, false, (x) => x / 10, _eiaLen),
    BmsDp('temperature', 20, 2, true, (x) => x / 10, _eibLen), // average cell
    BmsDp.bytes('problem_code', 1, 9, (b) {
      final v = BigInt.parse(b.hex, radix: 16) & _prbMask;
      return v.isValidInt ? v.toInt() : v;
    }, _eicLen),
    BmsDp('dischrg_mosfet', 7, 1, false, (x) => x & 1 != 0, _eicLen),
    BmsDp('chrg_mosfet', 7, 1, false, (x) => x & 2 != 0, _eicLen),
    BmsDp('heater', 7, 1, false, (x) => x & 8 != 0, _eicLen),
    BmsDp('balancer', 7, 1, false, (x) => x & 4 != 0, _eicLen), // limit FET
  ];
  static final _pfields = <BmsDp>[
    BmsDp('voltage', 0, 2, false, (x) => x / 100),
    BmsDp('current', 2, 2, true, (x) => x / 100),
    BmsDp('cycle_charge', 4, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 6, 2, false, (x) => x ~/ 100),
    BmsDp('battery_level', 10, 2, false, (x) => x / 10),
    BmsDp('battery_health', 12, 2, false, (x) => x / 10),
    BmsDp('cycles', 14, 2, false, (x) => x),
  ];
  static final _cmds = {for (final q in _query) q.$3};
  static final _pcmds = {for (final q in _pquery) q.$3};
  static final _validCmds = {..._cmds, ..._pcmds};

  final Map<int, List<int>> _msg = {};
  int _packCount = 0;
  int _pkglen = 0;

  SeplosBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'fff2';

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length > _headLen + _crcLen &&
        data[0] <= _packCount &&
        _cmdRead.contains(data[1] & 0x7F) && // read errors too
        data[2] >= _headLen + _crcLen) {
      frame.clear();
      _pkglen = data[2] + _headLen + _crcLen;
    } else if (data.length == _headLen + _crcLen &&
        data[0] <= _packCount &&
        data[1] & 0x80 != 0) {
      frame.clear(); // error message
      _pkglen = _headLen + _crcLen;
    }
    frame.extend(data);

    if (frame.length < _pkglen) return;
    if (!checkIntegrity(
      frame,
      crcModbus,
      (null, _pkglen - 2),
      (_pkglen - 2, _pkglen),
      little: true,
    )) {
      frame.clear();
      return;
    }
    if (!_validCmds.contains(frame[2] >> 1) || frame[1] & 0x80 != 0) {
      frame.clear();
      return;
    }
    _msg[frame[0] << 8 | frame[2] >> 1] = frame.bytes;
    frame.clear();
    msgEvent.set();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection();
    _packCount = 0;
    _pkglen = 0;
  }

  static Uint8List _cmd(int device, (int, int, int) q) {
    final (cmd, start, count) = q;
    final f = [
      device,
      cmd,
      ...intTo(start, 2),
      ...intTo(count * (cmd == 0x1 ? 0x10 : 0x1), 2),
    ];
    return Uint8List.fromList([...f, ...intTo(crcModbus(f), 2, little: true)]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    _msg.clear();
    for (final q in _query) {
      await awaitMsg(_cmd(0x0, q));
    }
    if (!_cmds.every(_msg.containsKey)) {
      throw const FormatException('BMS data incomplete.');
    }
    final data = BaseBms.decodeData(_fields, _msg, start: _headLen);
    final pc = (data['pack_count'] as int?) ?? 0;
    _packCount = pc < 0x10 ? pc : 0x10;

    for (var pack = 1; pack <= _packCount; pack++) {
      for (final q in _pquery) {
        await awaitMsg(_cmd(pack, q));
      }
      if (!_pcmds.every((c) => _msg.containsKey(pack << 8 | c))) {
        throw const FormatException('BMS data incomplete.');
      }
      final pib = _msg[pack << 8 | _pibLen]!;
      final sample = BaseBms.decodePack(
        _pfields,
        _msg[pack << 8 | _piaLen]!,
        start: _headLen,
      );
      sample['cell_voltages'] = BaseBms.cellVoltages(
        pib,
        cells: 16,
        start: _headLen,
      );
      // 4 cell temperatures, 4 reserved, then ambient and MOSFET
      sample['temp_values'] = [
        ...BaseBms.tempValues(
          pib,
          values: 4,
          start: _tempStart,
          signed: false,
          offset: 2731,
          divider: 10,
          types: const [
            TempType.cell,
            TempType.cell,
            TempType.cell,
            TempType.cell,
          ],
        ),
        ...BaseBms.tempValues(
          pib,
          values: 2,
          start: _tempStart + 16,
          signed: false,
          offset: 2731,
          divider: 10,
          types: const [TempType.ambient, TempType.mosfet],
        ),
      ];
      ((data['packs'] ??= <BmsSample>[]) as List<BmsSample>).add(sample);
    }
    return data;
  }
}
