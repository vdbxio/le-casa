// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Powerboozt batteries: E&J-style ASCII-hex framing, one status command.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';
import 'ej.dart';

class PwrbooztBms extends EjBms {
  static final spec = BmsSpec(
    module: 'pwrboozt_bms',
    info: const {'manufacturer': 'Powerboozt', 'model': 'battery'},
    matchers: const [
      MatcherPattern(
        localName: 'BT-Battery*',
        manufacturerId: 32516,
        serviceUuid: 'fff0',
      ),
    ],
    create: PwrbooztBms.new,
  );

  static final _fields = <BmsDp>[
    BmsDp('battery_level', 69, 1, false),
    BmsDp('current', 54, 4, true, (x) => x / 1000),
    BmsDp('cycles', 67, 2, false),
    BmsDp('design_capacity', 70, 4, false, (x) => x ~/ 1000),
    BmsDp('voltage', 62, 2, false, (x) => x / 1000),
  ];

  PwrbooztBms(super.device, [super.config]);

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
    if (!collect(data)) return;
    final expLen = expFrameLen();
    frame.setAll_(frame.where((b) => b != 0).toList());
    if (!frameComplete(expLen)) return;
    final m = fromHexStr(String.fromCharCodes(frame.sl(1, -1)));
    if (!checkIntegrity(m, (x) => crcSum(x) ^ 0xFF, (1, -1), m.at(-1))) {
      frame.clear();
      return;
    }
    msg = m;
    msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitMsg(ascii(':015150000EFE~'));
    return BaseBms.decodeData(_fields, msg)
      ..['cell_voltages'] = BaseBms.cellVoltages(
        msg,
        cells: EjBms.maxCells,
        start: EjBms.cellPos,
      )
      ..['temp_values'] = BaseBms.tempValues(
        msg,
        start: 48,
        values: 4,
        size: 1,
        signed: false,
        offset: 40,
      );
  }
}
