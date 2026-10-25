// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// ECO-WORTHY BW 02/0B. Pushes two frames (A1, A2) on its own once started.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class EcoworthyBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'ecoworthy_bms',
    info: const {'manufacturer': 'ECO-WORTHY', 'model': 'BW 02/0B'},
    matchers: [
      const MatcherPattern(localName: 'ECO-WORTHY 02_*'),
      for (final p in ['DCHOUSE*', 'ECO-WORTHY*'])
        MatcherPattern(localName: p, serviceUuid: 'fff0'),
    ],
    create: EcoworthyBms.new,
  );

  static const _heads = [
    [0xA1],
    [0xA2],
  ];
  static const _cellPos = 14;
  static const _tempPos = 80;
  static final _fieldsV1 = <BmsDp>[
    BmsDp('battery_level', 16, 2, false, (x) => x, 0xA1),
    BmsDp('battery_health', 18, 2, false, (x) => x, 0xA1),
    BmsDp('voltage', 20, 2, false, (x) => x / 100, 0xA1),
    BmsDp('current', 22, 2, true, (x) => x / 100, 0xA1),
    BmsDp('problem_code', 51, 2, false, (x) => x, 0xA1),
    BmsDp('design_capacity', 26, 2, false, (x) => x ~/ 100, 0xA1),
    BmsDp('cell_count', _cellPos, 2, false, (x) => x, 0xA2),
    BmsDp('temp_sensors', _tempPos, 2, false, (x) => x, 0xA2),
  ];
  static final _fieldsV2 = [
    for (final f in _fieldsV1)
      BmsDp(
        f.key,
        f.pos,
        f.size,
        f.signed,
        f.key == 'current' ? (x) => x / 10 : f.fct,
        f.idx,
      ),
  ];
  static final _initCmds = [
    fromHexStr('ff0802000b010064 01ffffffffffffff002d'),
    fromHexStr('ff0802000b010014 01ffffffffffffff65ef'),
  ];
  static const _cmds = {0xA1, 0xA2};

  late final List<List<int>> _macHead = [
    for (final h in _heads)
      [...intTo(int.parse(device.address.replaceAll(':', ''), radix: 16), 6), ...h],
  ];
  final Map<int, List<int>> _msg = {};

  EcoworthyBms(super.device, [super.config]);

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
    if (![..._heads, ..._macHead].any(data.startsWithBytes)) return;
    if (!checkIntegrity(data, crcModbus, (null, -2), (-2, null), little: true)) {
      return;
    }
    // drop the MAC prefix and align both protocol versions
    final shift = _macHead.any(data.startsWithBytes);
    _msg[data[shift ? 6 : 0]] = [...Uint8List(shift ? 2 : 0), ...data];
    if (_cmds.every(_msg.containsKey)) msgEvent.set();
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    if (!msgEvent.isSet) {
      // empty entries: wait for any BMS message
      _msg.addAll({0xA1: const [], 0xA2: const []});
      for (final cmd in _initCmds) {
        await awaitMsg(cmd);
      }
      _msg.clear();
      msgEvent.clear();
    }
    await waitEventFor(timeout);

    final a1 = _msg[0xA1]!;
    final result = BaseBms.decodeData(
      _heads.any(a1.startsWithBytes) ? _fieldsV1 : _fieldsV2,
      _msg,
    );
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg[0xA2]!,
      cells: (result['cell_count'] as int?) ?? 0,
      start: _cellPos + 2,
    );
    result['temp_values'] = BaseBms.tempValues(
      _msg[0xA2]!,
      values: (result['temp_sensors'] as int?) ?? 0,
      start: _tempPos + 2,
      divider: 10,
    );
    _msg.clear();
    msgEvent.clear(); // make sure the next update gets fresh data
    return result;
  }
}
