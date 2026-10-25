// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Generic C4S100 smart BMS (RC6621A): Vatrer-style Modbus, one big read.

import '../base_bms.dart';
import '../spec.dart';
import 'vatrer.dart';

class C4sBms extends VatrerBms {
  static final spec = BmsSpec(
    module: 'c4s_bms',
    info: const {
      'manufacturer': 'Generic',
      'model': 'C4S100 Smart BMS (RC6621A)',
    },
    matchers: const [
      MatcherPattern(
        localName: 'C4S100IE?????',
        serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      ),
    ],
    create: C4sBms.new,
  );

  static const _temps = 2; // MOS_T, ENV_T
  static const _regCount = 0x46;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 3, 2, false, (x) => x / 100),
    BmsDp('current', 5, 4, true, (x) => x / 100),
    BmsDp('battery_level', 9, 2, false),
    BmsDp('cycle_charge', 11, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 13, 2, false, (x) => pyRoundInt(x / 100)),
    BmsDp('cycles', 15, 2, false),
    BmsDp('battery_health', 17, 2, false),
    BmsDp('delta_voltage', 29, 2, false, (x) => x / 1000),
    BmsDp('cell_count', 45, 2, false),
  ];

  C4sBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;

  @override
  Future<BmsSample> asyncUpdate() async {
    msg.clear();
    await awaitMsg(BaseBms.cmdModbus(devId: 0x2, addr: 0x0, count: _regCount));
    final m = msg[_regCount * 2];
    if (m == null) throw const FormatException('BMS data incomplete.');
    final result = BaseBms.decodeData(_fields, m);
    result['cell_voltages'] = BaseBms.cellVoltages(
      m,
      cells: (result['cell_count'] as int?) ?? 0,
      start: 47,
    );
    result['temp_values'] = BaseBms.tempValues(
      m,
      start: 35,
      values: _temps,
      types: const [TempType.mosfet, TempType.ambient],
    );
    return result;
  }
}
