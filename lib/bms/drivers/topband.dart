// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Topband smart BMS. Pushes its data as upper-case hex text.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class TopbandBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'topband_bms',
    info: const {'manufacturer': 'Topband', 'model': 'smart BMS'},
    matchers: [
      for (final id in [0, 0xFFFF])
        MatcherPattern(serviceUuid: 'ffe0', manufacturerId: id),
    ],
    create: TopbandBms.new,
  );

  static const maxCells = 16;
  static const _infoLen = 113;
  static final topbandFields = <BmsDp>[
    BmsDp('voltage', 0, 4, false, (x) => x / 1000),
    BmsDp('current', 4, 4, true, (x) => x / 1000),
    BmsDp('battery_level', 14, 2, false),
    BmsDp('cycle_charge', 8, 4, false, (x) => x / 1000),
    BmsDp('cycles', 12, 2, false),
    BmsDp(
      'temp_values',
      16,
      2,
      false,
      (x) => [TempSensor(pyRound(x / 10 - 273.15, 3))],
    ),
    BmsDp('problem_code', 18, 1, false),
  ];

  Uint8List msg = Uint8List(0);

  List<BmsDp> get fields => topbandFields;

  TopbandBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe4';
  @override
  String get uuidTx => throw UnimplementedError('Topband only pushes data');

  static bool _hexUpper(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46);

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    // a byte that is not hex text starts a frame
    var start = -1;
    for (var i = data.length - 1; i >= 0; i--) {
      if (!_hexUpper(data[i])) {
        start = i;
        break;
      }
    }
    var d = data;
    if (start != -1 && (frame.length + start <= _infoLen || frame.isEmpty)) {
      d = data.sl(start);
      frame.clear();
    }
    frame.extend(d);

    if (frame.length < _infoLen) return;
    frame.del(_infoLen, frame.length);
    while (frame.isNotEmpty && !_hexUpper(frame[frame.length - 1])) {
      frame.del(frame.length - 1, frame.length);
    }

    // two headers in the final chunk
    final body = frame.sl(1);
    if (body.length.isOdd || !body.every(_hexUpper)) {
      frame.clear();
      return;
    }
    final dec = fromHexStr(String.fromCharCodes(body));
    if (!checkIntegrity(dec, (x) => crcSum(x, 2), (null, -2), (-2, null))) {
      frame.clear();
      return;
    }
    msg = dec;
    msgEvent.set();
    frame.clear();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await waitEventFor(timeout);
    return BaseBms.decodeData(fields, msg, little: true)
      ..['cell_voltages'] = BaseBms.cellVoltages(
        msg,
        cells: maxCells,
        start: 22,
        little: true,
      );
  }
}
