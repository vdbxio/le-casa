// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Super-B Epsilon v2.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class SuperbV2Bms extends BaseBms {
  static final spec = BmsSpec(
    module: 'superb_v2_bms',
    info: const {'manufacturer': 'Super-B', 'model': 'Epsilon v2'},
    matchers: [
      MatcherPattern(
        localName: 'Epsilon*',
        manufacturerId: 0x50BE,
        manufacturerDataStart: ascii('Epsilon V2'),
      ),
    ],
    create: SuperbV2Bms.new,
  );

  static const _notifyChar = 'e0fef452-9d2b-4005-a1e3-69fe1102b436';
  static const _frameLen = 24;
  static final _fields = <BmsDp>[
    BmsDp('current', 6, 4, true, (x) => x / 1000, 0x2),
    BmsDp('voltage', 10, 2, false, (x) => x / 1000, 0x2),
    BmsDp('battery_level', 1, 1, false, (x) => x, 0x0),
    BmsDp('battery_health', 19, 1, false, (x) => x, 0x0),
    BmsDp('runtime', 20, 4, false, (x) => x, 0x0),
    BmsDp('cycles', 18, 1, false, (x) => x, 0x0),
  ];
  static final _cmds = {for (final f in _fields) f.idx};

  final Map<int, List<int>> _msg = {};

  SuperbV2Bms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['cf9ccdf7-eee9-43ce-87a5-82b54af5324e'];
  @override
  String get uuidRx => 'cf9ccdfa-eee9-43ce-87a5-82b54af5324e';
  @override
  String get uuidTx => 'cf9ccdfa-eee9-43ce-87a5-82b54af5324e';
  @override
  Set<String> get rawValues => const {'runtime'}; // never calculated

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    // the second notify characteristic
    await startNotify(_notifyChar, notificationHandler);
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length != _frameLen) return;
    _msg[data[0]] = Uint8List.fromList(data);
    if (_cmds.every(_msg.containsKey)) msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(const [0x21, 0x54, 0x00]);
    final result = BaseBms.decodeData(_fields, _msg);
    // runtime only while discharging
    if (result['runtime'] == 0xFFFFFFFF) result.remove('runtime');
    _msg.clear();
    return result;
  }
}
