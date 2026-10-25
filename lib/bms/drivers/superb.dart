// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Super-B Epsilon. Pushes one 20 byte frame.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class SuperbBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'superb_bms',
    info: {'manufacturer': 'Super-B', 'model': 'Epsilon'},
    matchers: [MatcherPattern(localName: 'Epsilon-*')],
    create: SuperbBms.new,
  );

  static const _infoLen = 20;
  static final _fields = <BmsDp>[
    BmsDp('battery_level', 2, 1, false),
    BmsDp('battery_health', 3, 1, false),
    BmsDp('runtime', 4, 4, false),
    BmsDp('problem_code', 1, 1, false, (x) => (x & 0x1) ^ 0x1),
    BmsDp('balancer', 1, 1, false, (x) => x & 0x80 != 0),
  ];

  Uint8List _msg = Uint8List(0);

  SuperbBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['74b9c2d1-dc6d-42cf-a2e9-7398b8fc2e70'];
  @override
  String get uuidRx => '6edadbe4-4f53-4a5a-96ed-02f93db93790';
  @override
  String get uuidTx => throw UnimplementedError('Epsilon only pushes data');

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length != _infoLen) return;
    _msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await waitEventFor(timeout);
    final result = BaseBms.decodeData(_fields, _msg);
    final bd = ByteData.sublistView(_msg);
    final current = pyRound(bd.getFloat32(8), 3);
    result['current'] = current;
    result['voltage'] = pyRound(bd.getFloat32(12), 3);
    // runtime only while discharging
    if (current >= 0) result.remove('runtime');
    return result;
  }
}
