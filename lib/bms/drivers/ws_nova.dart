// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Wattstunde Nova Core. Hex text, XOR scrambled.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class WsNovaBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'ws_nova_bms',
    info: const {'manufacturer': 'Wattstunde', 'model': 'Nova Core'},
    matchers: [
      for (final oui in ['60:6E:41', '10:23:81'])
        MatcherPattern(oui: oui, serviceUuid: 'fff0'),
    ],
    create: WsNovaBms.new,
  );

  static const _head = 0x3A;
  static const _tail = 0x7E;
  static const _minLen = 238; // up to the heater, plus the tail
  static final _fields = <BmsDp>[
    BmsDp(
      'current',
      10,
      4,
      false,
      (x) => (x & 0x7FFF) / 1000 * (x >> 15 != 0 ? -1 : 1),
    ),
    BmsDp('voltage', 18, 2, false, (x) => x / 1000),
    BmsDp('cycles', 23, 2, false),
    BmsDp('battery_level', 25, 1, false),
    BmsDp('design_capacity', 26, 4, false, (x) => x ~/ 1000),
    BmsDp('cycle_charge', 30, 4, false, (x) => x / 1000),
    BmsDp('heater', 64, 4, false, (x) => x != 0),
    BmsDp('problem_code', 0, 2, false, (x) => x & 0x0FFC),
  ];
  static final _cmdRead = _cmd(ascii('015150000EFE'));

  Uint8List _msg = Uint8List(0);

  WsNovaBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFF0)];
  @override
  String get uuidRx => 'fff1';
  @override
  String get uuidTx => 'fff1';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitMsg(_cmdRead);
    msgEvent.clear();
    return {'serial_number': b2str(_msg.sl(91, 107))};
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.isNotEmpty && data[0] == _head) frame.clear();
    frame.extend(data);

    if (frame.isEmpty || frame[0] != _head || frame.length > BaseBms.bleMaxAttrSize) {
      frame.clear();
      return;
    }
    if (frame[frame.length - 1] != _tail) return;
    if (frame.length.isOdd || frame.length < _minLen) return;

    final body = frame.sl(1, -1);
    if (!isHexDigits(body)) {
      frame.clear();
      return;
    }
    final key = int.parse(String.fromCharCodes(frame.sl(7, 9)), radix: 16);
    final dec = Uint8List.fromList([
      for (final b in fromHexStr(String.fromCharCodes(frame.sl(1, -3)))) b ^ key,
    ]);
    // incoming frames seem to carry an invalid checksum, so none is checked
    if (!dec.startsWithBytes(const [0x01, 0x54])) {
      frame.clear();
      return;
    }
    _msg = dec;
    msgEvent.set();
  }

  static Uint8List _cmd(List<int> cmd) =>
      Uint8List.fromList([_head, ...cmd, _tail]);

  @override
  Future<BmsSample> asyncUpdate() async {
    if (!msgEvent.isSet) await awaitMsg(_cmdRead);
    final result = BaseBms.decodeData(_fields, _msg, start: 44);
    result['cell_voltages'] = BaseBms.cellVoltages(_msg, cells: 16, start: 12);
    result['temp_values'] = BaseBms.tempValues(
      _msg,
      values: 4,
      start: 48,
      size: 1,
      signed: false,
      offset: 40,
    );
    msgEvent.clear();
    return result;
  }
}
