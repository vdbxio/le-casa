// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Offgridtec LiFePo4 Smart Pro. Text registers, scrambled with a key that
// comes from the device name.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class OgtBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'ogt_bms',
    info: {'manufacturer': 'Offgridtec', 'model': 'LiFePo4 Smart Pro'},
    matchers: [
      MatcherPattern(localName: 'SmartBat-[AB]*', serviceUuid: 'fff0'),
    ],
    create: OgtBms.new,
  );

  static const _crySeq = [2, 5, 4, 3, 1, 4, 1, 6, 8, 3, 7, 2, 5, 8, 9, 3];
  static List<double> _kelvin(int x) => [pyRound(x / 10 - 273.15, 3)];
  static final _fieldsA = <BmsDp>[
    BmsDp('battery_level', 0, 1, false, (x) => x, 2),
    BmsDp('cycle_charge', 0, 3, false, (x) => x / 1000, 4),
    BmsDp('voltage', 0, 2, false, (x) => x / 1000, 8),
    BmsDp('temp_values', 0, 2, false, _kelvin, 12),
    BmsDp('current', 0, 3, false, (x) => x / 100, 16),
    BmsDp('runtime', 0, 2, false, (x) => x * 60, 24),
    BmsDp('cycles', 0, 2, false, (x) => x, 44),
    BmsDp('design_capacity', 0, 3, false, (x) => x ~/ 1000, 60),
  ];
  static final _fieldsB = <BmsDp>[
    BmsDp('temp_values', 0, 2, false, _kelvin, 8),
    BmsDp('voltage', 0, 2, false, (x) => x / 1000, 9),
    BmsDp('current', 0, 3, false, (x) => x / 1000, 10),
    BmsDp('battery_level', 0, 1, false, (x) => x, 13),
    BmsDp('cycle_charge', 0, 3, false, (x) => x / 1000, 15),
    BmsDp('runtime', 0, 2, false, (x) => x * 60, 18),
    BmsDp('cycles', 0, 2, false, (x) => x, 23),
    BmsDp('design_capacity', 0, 3, false, (x) => x ~/ 1000, 24),
  ];

  late final String _type;
  late final int _key;
  late final List<BmsDp> _fields;
  late final String _header;
  int _expReply = 0x0;
  (int, int) _response = (0, 0); // (register; 0 error, -1 undecodable), value

  OgtBms(super.device, [super.config]) {
    final id = name.length > 10 ? name.substring(10) : '';
    _type = name.length > 10 && RegExp(r'^[0-9]+$').hasMatch(id)
        ? name[9]
        : '?';
    final ab = _type == 'A' || _type == 'B';
    _key =
        (ab
            ? int.parse(id)
                  .toRadixString(16)
                  .toUpperCase()
                  .padLeft(4, '0')
                  .split('')
                  .map((c) => _crySeq[int.parse(c, radix: 16)])
                  .fold(0, (a, b) => a + b)
            : 0) +
        (_type == 'A' ? 5 : 8);
    _fields = _type == 'A' ? _fieldsA : (_type == 'B' ? _fieldsB : const []);
    _header = _type == 'A' ? '+RAA' : (_type == 'B' ? '+R16' : '');
    if (_fields.isEmpty) debugPrint('bms: $name: unknown device type $_type');
  }

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff4';
  @override
  String get uuidTx => 'fff6';

  // characteristic 180a holds garbage
  @override
  Future<BmsInfo> fetchDeviceInfo() async => {
    'serial_number': name.length > 10 ? name.substring(10) : '',
  };

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    _response = _ogtResponse(data);
    if (_response.$1 == -1) return;
    if (_response.$1 != 0 && _response.$1 != _expReply) return;
    _expReply = -1;
    msgEvent.set();
  }

  static final _hex = RegExp(r'^[0-9a-fA-F]*$');

  (int, int) _ogtResponse(Uint8List resp) {
    final b = [for (final x in resp) x ^ _key];
    if (b.any((c) => c > 0x7F)) return (-1, 0);
    final msg = String.fromCharCodes(b);

    if (msg.length < 8 || !msg.startsWith('+RD,')) return (-1, 0);
    if (msg.substring(4, 7) == 'Err') return (0, 0);
    if (msg.length.isOdd ||
        !msg.endsWith('\r\n') ||
        !_hex.hasMatch(msg.substring(4, msg.length - 2))) {
      return (-1, 0);
    }
    // 16-bit value in network order, times an optional multiplier for
    // 24-bit values (at least 1, for the A type's current)
    final signed = msg.length > 12;
    final raw = fromHexStr(msg.substring(6, msg.length < 10 ? msg.length : 10));
    var value = intFrom(raw, little: true, signed: signed);
    if (signed) {
      final m = int.parse(msg.substring(10, 12), radix: 16);
      value *= m > 1 ? m : 1;
    }
    return (int.parse(msg.substring(4, 6), radix: 16), value);
  }

  Uint8List _ogtCommand(int reg, int length) {
    String h(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');
    final cmd = '$_header${h(reg)}${h(length)}';
    return Uint8List.fromList([for (final c in cmd.codeUnits) c ^ _key]);
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    final result = <String, Object?>{};
    for (final f in _fields) {
      _expReply = f.idx;
      await awaitMsg(_ogtCommand(f.idx, f.size));
      if (_response.$1 <= 0) throw TimeoutException('no register ${f.idx}');
      result[f.key] = f.fct(_response.$2);
    }

    if (_type == 'B') {
      for (var cellReg = 0; cellReg < 16; cellReg++) {
        _expReply = 63 - cellReg;
        await awaitMsg(_ogtCommand(63 - cellReg, 2));
        if (_response.$1 <= 0) break;
        ((result['cell_voltages'] ??= <double>[]) as List<double>).add(
          _response.$2 / 1000,
        );
      }
    }

    // no remaining runtime while charging
    if (result['runtime'] == 0xFFFF * 60) result.remove('runtime');
    return result;
  }
}
