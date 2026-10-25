// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Eleksol BMS: a JBD on different characteristics.

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';
import 'jbd.dart';

class EleksolBms extends JbdBms {
  static final spec = BmsSpec(
    module: 'eleksol_bms',
    info: const {'manufacturer': 'Jiabaida', 'model': 'Eleksol BMS'},
    matchers: [
      for (final oui in [
        'A4:C1:37',
        'A4:C1:38',
        'A5:C2:37',
        'A5:C2:39',
        'AA:C2:37',
      ])
        MatcherPattern(oui: oui, serviceUuid: 'ff06'),
    ],
    create: EleksolBms.new,
    acceptSecret: true,
  );

  EleksolBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFF06)];
  @override
  String get uuidRx => 'ff07';
  @override
  String get uuidTx => 'ff08';
}
