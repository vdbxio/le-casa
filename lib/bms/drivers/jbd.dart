// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// JBD (Jiabaida) smart BMS, sold under many battery brands.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class JbdBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'jbd_bms',
    info: {'manufacturer': 'Jiabaida', 'model': 'smart BMS'},
    matchers: [
      for (final n in [
        '@KsM:*', // RVPOWER
        'JBD-*',
        'LSG-*', // Lossigy battery
        'N-?????BL*', // Nordström battery
        'SJ-???-*', // Supervolt Jumbo
        'SX1*', // Supervolt v3
        'SX60*', // Supervolt Ultra
        'SBL-*', // SBL
        'OGR-*', // OGRPHY
        'TZ-H*', // CERRNSS battery
        '12???BL*', // SBL connect battery
        '24???BL*', // SBL connect battery
      ])
        MatcherPattern(localName: n, serviceUuid: 'ff00'),
      for (final oui in [
        '10:A5:62', // CHINS
        'A2:C2:37',
        'A4:C1:37',
        'A4:C1:38',
        'A5:C2:37',
        'A5:C2:39',
        'A5:C2:3A',
        'AA:C2:37',
        '70:3E:97',
      ])
        MatcherPattern(oui: oui, serviceUuid: 'ff00'),
    ],
    create: JbdBms.new,
    acceptSecret: true,
    secretHint:
        'Only if you set a password in the battery app. JBD and Xiaoxiang '
        'apps default to 000000 when one is turned on.',
  );

  static const _headInit = [0xFF, 0xAA];
  static const _headRsp = [0xDD];
  static const _headCmd = [0xDD, 0xA5];
  static const _validCmd = {0x03, 0x04, 0x05};
  static const _tail = 0x77;
  static const _initLen = 5;
  static const _infoLen = 7;
  static const maxCellCount = 32;
  static const _posSwver = 22;
  static const _tempTypes = [
    TempType.cell,
    TempType.cell,
    TempType.cell,
    TempType.cell,
  ];
  static final _fields = <BmsDp>[
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
      (x) => x < maxCellCount ? x : maxCellCount,
    ),
    BmsDp('temp_sensors', 26, 1, false),
  ];

  int _validReply = 0x00;
  Uint8List msg = Uint8List(0);

  Set<int> get validCmd => _validCmd;
  List<BmsDp> get fields => _fields;
  List<TempType> get tempTypes => _tempTypes;

  JbdBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  bool get acceptSecret => true;
  @override
  List<String> get uuidServices => [uuid16(0xFF00)];
  @override
  String get uuidRx => 'ff01';
  @override
  String get uuidTx => 'ff02';

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await awaitCmdResp(0x03);
    if (msg.length <= _posSwver) {
      throw const FormatException('BMS data incomplete.');
    }
    final sw = msg[_posSwver];
    final result = <String, String>{'sw_version': '${sw >> 4}.${sw & 0xF}'};
    try {
      await awaitCmdResp(0x05);
      result['hw_version'] = b2str(msg.sl(4, msg[3] + 4));
    } on TimeoutException {
      // no hardware version
    }
    return result;
  }

  void _notifyInitHandler(GattChar sender, Uint8List data) {
    if (!data.startsWithBytes(_headInit)) return;
    if (data.length < _initLen || data.length < _initLen + data[3]) return;
    if (!checkIntegrity(data, crcSum, (2, -1), (-1, null))) return;
    if (data[2] != 0x15 || data[3] != 0x01) return;
    msg = Uint8List.fromList(data);
    msgEvent.set();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    if (cfg.secret.isNotEmpty) {
      await startNotify(uuidRx, _notifyInitHandler);
      final data = ascii(cfg.secret);
      await awaitMsg([
        ..._headInit,
        0x15,
        cfg.secret.length & 0xFF,
        ...data,
        (0x15 + cfg.secret.length + data.sum) & 0xFF,
      ]);
      if (msg[4] != 0x00) {
        throw const BmsPermissionException('Incorrect secret.');
      }
      await stopNotify(uuidRx);
    }
    await super.initConnection(charNotify);
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (data.length >= 3 &&
        data.startsWithBytes(_headRsp) &&
        validCmd.contains(data[1]) &&
        (data[2] == 0x00 || data[2] == 0x80) &&
        frame.length > _infoLen &&
        frame.length >= _infoLen + frame[3]) {
      frame.clear();
    }

    frame.extend(data);

    if (frame.length < _infoLen || frame.length < _infoLen + frame[3]) return;

    final frameEnd = _infoLen + frame[3] - 1;
    if (frame[frameEnd] != _tail) return;

    if (!checkIntegrity(
      frame,
      _crc,
      (2, frameEnd - 2),
      (frameEnd - 2, frameEnd),
    )) {
      return;
    }

    if (frame[1] != _validReply || frame[2] & 0x80 != 0) return;

    msg = frame.sl(0, frameEnd - 2);
    msgEvent.set();
  }

  static int _crc(List<int> frame) => 0x10000 - frame.sum;

  static Uint8List _cmd(int cmd, [List<int> data = const []]) {
    final f = [..._headCmd, cmd, data.length, ...data];
    final crc = _crc(f.sublist(2));
    return Uint8List.fromList([...f, ...intTo(crc, 2), _tail]);
  }

  Future<void> awaitCmdResp(int cmd, [List<int> data = const []]) async {
    final msg = _cmd(cmd, data);
    _validReply = msg[2];
    await awaitMsg(msg);
    _validReply = 0x00;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    await awaitCmdResp(0x03);
    final result = BaseBms.decodeData(fields, msg);
    result['temp_values'] = BaseBms.tempValues(
      msg,
      values: (result['temp_sensors'] as int?) ?? 0,
      start: 27,
      signed: false,
      offset: 2731,
      divider: 10,
      types: tempTypes,
    );

    await awaitCmdResp(0x04);
    result['cell_voltages'] = BaseBms.cellVoltages(
      msg,
      cells: (result['cell_count'] as int?) ?? 0,
      start: 4,
    );
    return result;
  }
}
