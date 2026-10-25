// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Renogy Pro batteries (RNGRBP, RNGC). Same protocol as the BT-TH module,
// but the characteristics have to be picked by service.

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';
import 'renogy.dart';

class RenogyProBms extends RenogyBms {
  static final spec = BmsSpec(
    module: 'renogy_pro_bms',
    info: const {'manufacturer': 'Renogy', 'model': 'BT battery pro'},
    matchers: [
      for (final p in ['RNGRBP*', 'RNGC*'])
        MatcherPattern(localName: p, manufacturerId: 0xE14C),
    ],
    create: RenogyProBms.new,
  );

  static final _fields = <BmsDp>[
    BmsDp('voltage', 5, 2, false, (x) => x / 10),
    BmsDp('current', 3, 2, true, (x) => x / 10),
    BmsDp('design_capacity', 11, 4, false, (x) => x ~/ 1000),
    BmsDp('cycle_charge', 7, 4, false, (x) => x / 1000),
    // RNGC types seem to send cycles in the other byte order
    // (patman15/BMS_BLE-HA#596)
    BmsDp('cycles', 15, 2, false),
  ];

  GattChar? _writeChar;

  RenogyProBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<BmsDp> get fields => _fields;

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    assert(charNotify == null, 'char_notify is not used for Renogy Pro');
    GattChar? notifyChar;
    _writeChar = null;
    final svcWrite = uuidServices[0], svcNotify = uuidServices[1];
    for (final c in client.characteristics) {
      if (c.service == svcWrite &&
          c.uuid == normalizeUuid(uuidTx) &&
          (c.canWrite || c.canWriteWithoutResponse)) {
        _writeChar = c;
      }
      if (c.service == svcNotify &&
          c.uuid == normalizeUuid(uuidRx) &&
          c.canNotify) {
        notifyChar = c;
      }
    }
    if (notifyChar == null || _writeChar == null) {
      await disconnect();
      throw UnsupportedDeviceException(
        'Failed to detect characteristics from $name.',
      );
    }
    await super.initConnection(notifyChar);
  }

  @override
  Future<void> awaitMsg(
    List<int> data, {
    CharSpec? char,
    bool waitForNotify = true,
    int maxSize = 0,
  }) => super.awaitMsg(
    data,
    char: _writeChar,
    waitForNotify: waitForNotify,
    maxSize: maxSize,
  );
}
