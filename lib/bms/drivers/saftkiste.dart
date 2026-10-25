// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Batterieschmiede Saftkiste BMS. Takes a six character password.

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class SaftkisteBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'saftkiste_bms',
    info: const {'manufacturer': 'Batterieschmiede', 'model': 'Saftkiste BMS'},
    matchers: [
      MatcherPattern(
        manufacturerId: 4660,
        manufacturerDataStart: [for (var i = 1; i < 8; i++) i],
      ),
    ],
    create: SaftkisteBms.new,
    acceptSecret: true,
    secretHint:
        'The six character password from the Saftkiste app: upper-case '
        'letters and digits.',
  );

  /// Seconds since the epoch, sent with the password. Replaceable in tests.
  @visibleForTesting
  static int Function() epochSeconds = () =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static const _head = [0xF0, 0xFF];
  static const _maxCells = 4;
  static const _minLen = 5;
  static const _validRsp = {0x0, 0x2, 0x3, 0x10, 0x43};
  static final _fields = <BmsDp>[
    BmsDp('cycle_charge', 7, 4, false, (x) => x / 1000, 0x2),
    BmsDp('design_capacity', 11, 2, false, (x) => x, 0x2),
    BmsDp('voltage', 13, 2, false, (x) => x / 1000, 0x2),
    BmsDp('current', 15, 2, true, (x) => x / 100, 0x2),
    BmsDp('cycles', 25, 2, false, (x) => x, 0x2),
    BmsDp('heater', 31, 1, false, (x) => x != 0, 0x2),
    BmsDp('balancer', 33, 1, false, (x) => x != 0, 0x2),
    BmsDp('problem_code', 38, 2, false, (x) => x, 0x2),
  ];

  final Map<int, List<int>> _msg = {};

  SaftkisteBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  bool get acceptSecret => true;
  @override
  List<String> get uuidServices => ['6e400001-b5a3-f393-e0a9-e50e24dcca9e'];
  @override
  String get uuidRx => '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  @override
  String get uuidTx => '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  static final _secretRe = RegExp(r'^[A-Z0-9]{6}$');

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    final secret = cfg.secret;
    if (secret.isNotEmpty) {
      if (!_secretRe.hasMatch(secret)) {
        throw const FormatException('Invalid secret');
      }
      final auth = [
        ..._cmd(0x10),
        ...ascii(secret),
        ...intTo(epochSeconds(), 4, little: true),
      ];
      await awaitMsg([...auth, crc32(auth) & 0xFF]);
      if (!_msg.containsKey(0x0)) {
        throw const BmsPermissionException('authentication failed');
      }
    } else {
      debugPrint('bms: $name: no password provided');
    }
    await awaitMsg([..._cmd(0x43), 0x01, 0x01, 0xE7, 0x80, 0x69, 0x96]);
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (!data.startsWithBytes(_head) ||
        data.length < _minLen ||
        !_validRsp.contains(data[2])) {
      return;
    }
    if (!checkIntegrity(data, (x) => crc32(x) & 0xFF, (null, -1), (-1, null))) {
      return;
    }
    _msg[data[2]] = Uint8List.fromList(data);
    msgEvent.set();
  }

  static List<int> _cmd(int cmd) => [..._head, cmd];

  @override
  Future<BmsSample> asyncUpdate() async {
    for (final cmd in [0x2, 0x3]) {
      await awaitMsg(_cmd(cmd));
    }
    final result = BaseBms.decodeData(_fields, _msg, little: true);
    result['cell_voltages'] = BaseBms.cellVoltages(
      _msg[0x2]!,
      cells: _maxCells,
      start: 17,
      little: true,
    );
    result['temp_values'] = BaseBms.tempValues(
      _msg[0x2]!,
      start: 27,
      values: 2,
      little: true,
      divider: 100,
      types: const [TempType.cell, TempType.pcb],
    );
    return result;
  }
}
