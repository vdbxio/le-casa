// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Allpowers / VOLIX portable power stations. They push status on their
// own; there is nothing to request.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class AllpowersBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'allpowers_bms',
    info: const {
      'manufacturer': 'Allpowers',
      'model': 'portable power station',
    },
    matchers: [
      for (final p in ['AP R*', 'VOLIX-*'])
        MatcherPattern(localName: p, serviceUuid: 'fff0'),
    ],
    create: AllpowersBms.new,
  );

  static const _sof = 0xA5;
  static const _statusMinLen = 15;
  static const _flagDc = 0x01;
  static const _flagAc = 0x02;
  static const _runtimeNone = 0xFFFF;
  static final _fields = <BmsDp>[
    BmsDp('chrg_mosfet', 7, 1, false, (x) => x & _flagAc != 0),
    BmsDp('dischrg_mosfet', 7, 1, false, (x) => x & _flagDc != 0),
    BmsDp('battery_level', 8, 1, false),
    BmsDp('power', 9, 4, false, (x) => ((x >> 16) - (x & 0xFFFF)).toDouble()),
    BmsDp('runtime', 13, 2, false, (x) => x * 60),
  ];

  Uint8List _msg = Uint8List(0);

  AllpowersBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => throw UnimplementedError('Allpowers takes no requests');

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length < _statusMinLen) return;
    if (data[0] != _sof) return;
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    msgEvent.clear();
    await waitEventFor(timeout);
    final result = BaseBms.decodeData(_fields, _msg);
    if (((result['power'] as num?) ?? 0) >= 0 ||
        result['runtime'] == _runtimeNone * 60) {
      result.remove('runtime');
    }
    return result;
  }
}
