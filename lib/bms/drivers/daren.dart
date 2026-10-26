// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Daren smart BMS (Docan batteries): JBD protocol with an extended frame.

import '../base_bms.dart';
import '../spec.dart';
import 'jbd.dart';

class DarenBms extends JbdBms {
  static final spec = BmsSpec(
    module: 'daren_bms',
    info: const {'manufacturer': 'Daren', 'model': 'smart BMS'},
    matchers: const [MatcherPattern(localName: 'DWF*', serviceUuid: 'ff00')],
    create: DarenBms.new,
  );

  static const _maxTempCount = 4;
  static const _validCmdD = {0x03, 0x04, 0x05, 0x08, 0xFF};
  static const _tempTypesD = [
    TempType.cell,
    TempType.cell,
    TempType.cell,
    TempType.cell,
    TempType.mosfet,
    TempType.ambient,
  ];
  static final _fieldsD = <BmsDp>[
    BmsDp('voltage', 4, 2, false, (x) => x / 100),
    BmsDp('current', 6, 2, true, (x) => x / 100),
    BmsDp('cycle_charge', 8, 2, false, (x) => x / 100),
    BmsDp('design_capacity', 10, 2, false, (x) => x ~/ 100),
    BmsDp('cycles', 12, 2, false),
    BmsDp('balancer', 16, 4, false, swap32),
    BmsDp('problem_code', 20, 2, false),
    BmsDp('battery_level', 23, 1, false),
    BmsDp('chrg_mosfet', 24, 1, false, (x) => x & 0x1 != 0),
    BmsDp('dischrg_mosfet', 24, 1, false, (x) => x & 0x2 != 0),
    BmsDp(
      'cell_count',
      25,
      1,
      false,
      (x) => x < JbdBms.maxCellCount ? x : JbdBms.maxCellCount,
    ),
    BmsDp(
      'temp_sensors',
      26,
      1,
      false,
      (x) => (x < _maxTempCount ? x : _maxTempCount) + 2,
    ),
    // extended frame fields overwrite the ones above
    BmsDp('battery_health', 39, 1, false),
    BmsDp('cycle_charge', 43, 2, false, (x) => x / 10),
    BmsDp('design_capacity', 45, 2, false, (x) => x / 10),
    BmsDp('current', 49, 2, true, (x) => x / 10),
  ];

  DarenBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  bool get acceptSecret => false;
  @override
  Set<int> get validCmd => _validCmdD;
  @override
  List<BmsDp> get fields => _fieldsD;
  @override
  List<TempType> get tempTypes => _tempTypesD;

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitCmdResp(0x08);
    return {
      'fw_version': b2str(msg.sl(177, 197)),
      'hw_version': b2str(msg.sl(117, 127)),
      'sw_version': b2str(msg.sl(127, 157)),
      'model': b2str(msg.sl(64, 94)),
    };
  }
}
