// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Voltagen Power Solutions MyVolta. Pushes DLE framed messages.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

abstract final class _MsgT {
  static const metrics = 0x0;
  static const info = 0x1;
  static const cellVoltages = [0x11, 0x12, 0x13, 0x14];
  static const temps = [0x24, 0x25, 0x26];
}

class MyvoltaBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'myvolta_bms',
    info: {
      'manufacturer': 'Voltagen Power Solutions',
      'model': 'MyVolta BLE HW',
    },
    matchers: [
      MatcherPattern(
        localName: 'VPS-*',
        serviceUuid: '00035b03-58e6-07dd-021a-08123a000300',
      ),
    ],
    create: MyvoltaBms.new,
  );

  static const _prbMask = 0xFF00FFFF; // byte 3 is unused
  static final _fields = <BmsDp>[
    BmsDp('voltage', 0, 2, false, (x) => x / 1000, _MsgT.metrics),
    BmsDp('current', 2, 2, true, (x) => x / 100, _MsgT.metrics),
    BmsDp('battery_level', 6, 2, false, (x) => x / 10, _MsgT.metrics),
    BmsDp('heater', 2, 2, false, (x) => x & 0x8000 != 0, _MsgT.info),
    BmsDp('problem_code', 1, 4, false, (x) => x & _prbMask, _MsgT.info),
  ];
  static final _msgSet = {
    _MsgT.metrics,
    _MsgT.info,
    ..._MsgT.cellVoltages,
    ..._MsgT.temps,
  };

  final Map<int, List<int>> _msg = {};
  final _parser = StreamParser(dle: 0x05, stx: 0x55, etx: 0x04);

  MyvoltaBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['00035b03-58e6-07dd-021a-08123a000300'];
  @override
  String get uuidRx => '00035b03-58e6-07dd-021a-08123a000301';
  @override
  String get uuidTx => throw UnimplementedError('MyVolta only pushes data');

  static int _crc(List<int> data) => 0xFF ^ (data.sum % 256);

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    final f = _parser.feed(data);
    if (f == null || f.isEmpty) return;
    if (f.length < 9) return;
    // command ID, pack ID, data length
    if (f[0] != 0x1 || f[2] != 0x2 || f[6] != 0x8) return;
    if (!checkIntegrity(f, _crc, (1, -1), (-1, null))) return;

    _msg[f[1]] = f;
    if (_msgSet.every(_msg.containsKey)) msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await waitEventFor(timeout);
    final result = BaseBms.decodeData(_fields, _msg, little: true, start: 7);
    result['cell_voltages'] = [
      for (final t in _MsgT.cellVoltages)
        ...BaseBms.cellVoltages(_msg[t]!, cells: 4, start: 7, little: true),
    ];
    result['temp_values'] = [
      for (final t in _MsgT.temps)
        ...BaseBms.tempValues(
          _msg[t]!,
          values: 4,
          start: 7,
          divider: 10,
          little: true,
        ),
    ];
    _msg.clear();
    msgEvent.clear();
    return result;
  }
}
