// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// E&J Technology BMS (LiTime, Lithtech, Volthium, Fliteboard, Chins,
// Metrisun). ASCII-hex frames `:...~`. Standard E&J uses two commands (RT
// and CAP); Metrisun/Chins answer RT with one 140-character frame.

import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class EjBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'ej_bms',
    info: const {'manufacturer': 'E&J Technology', 'model': 'smart BMS'},
    matchers: [
      // Lithtech Energy (2x), Volthium
      for (final p in ['L-12V???AH-*', 'LT-12V-*', 'V-12V???Ah-*'])
        MatcherPattern(localName: p),
      // Fliteboard, Electronix battery
      const MatcherPattern(localName: 'libatt*', manufacturerId: 21320),
      const MatcherPattern(localName: 'SV12V*', manufacturerId: 33384),
      // LiTime, by serial number
      for (final id in [33384, 22618])
        MatcherPattern(localName: 'LT-12???BG-A0[0-6]*', manufacturerId: id),
      const MatcherPattern(
        localName: 'LT-24???B-A00[0-2]*',
        manufacturerId: 22618,
      ),
      // Chins/MOBILEKTRO "G-{voltage}V{capacity}Ah-{serial}"
      const MatcherPattern(localName: 'G-[0-5][2-8]V[0-9]*A[Hh]-[0-9]*'),
    ],
    create: EjBms.new,
  );

  static const cmdRt = 0x2;
  static const cmdCap = 0x10;
  static const btModuleMsg = [0x41, 0x54, 0x0D, 0x0A]; // "AT\r\n"
  static const _ignoreCrc = 'libattU';
  static const head = [0x3A];
  static const tail = [0x7E];
  static const cellPos = 12;
  static const maxCells = 16;
  static final _fields = <BmsDp>[
    BmsDp(
      'current',
      44,
      4,
      false,
      (x) => ((x >> 16) - (x & 0xFFFF)) / 100,
      cmdRt,
    ),
    BmsDp('battery_level', 61, 1, false, (x) => x, cmdRt),
    BmsDp('cycle_charge', 7, 2, false, (x) => x / 10, cmdCap),
    // only the first sensor is relevant
    BmsDp('temp_values', 48, 1, false, (x) => [TempSensor(x - 40)], cmdRt),
    BmsDp('cycles', 57, 2, false, (x) => x, cmdRt),
    BmsDp('problem_code', 52, 2, false, (x) => x & 0x0FFC, cmdRt),
    BmsDp('dischrg_mosfet', 52, 1, false, (x) => x & 0x10 != 0, cmdRt),
    BmsDp('chrg_mosfet', 52, 1, false, (x) => x & 0x20 != 0, cmdRt),
    BmsDp('balancer', 55, 2, false, (x) => x, cmdRt),
    BmsDp('heater', 54, 1, false, (x) => x != 0, cmdRt),
    BmsDp('design_capacity', 66, 2, false, (x) => x ~/ 10, cmdRt),
  ];

  Uint8List msg = Uint8List(0);

  EjBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['6e400001-b5a3-f393-e0a9-e50e24dcca9e'];
  @override
  String get uuidRx => '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  @override
  String get uuidTx => '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  /// Strips the BLE module's "AT\r\n" and starts or extends [frame].
  /// Returns false when nothing is left to look at.
  bool collect(Uint8List data) {
    if (data.startsWithBytes(btModuleMsg)) {
      data = data.sl(btModuleMsg.length);
      if (data.isEmpty) return false;
    }
    if (data.startsWithBytes(head)) frame.clear();
    frame.extend(data);
    return true;
  }

  int expFrameLen() {
    final f = frame;
    if (f.length > 10 && isHexDigits(f.sl(7, 11))) {
      final n = hexInt(f.sl(7, 11));
      return n < BaseBms.maxMsgLen ? n : BaseBms.maxMsgLen;
    }
    return BaseBms.maxMsgLen;
  }

  /// Common frame checks; returns false (after clearing if broken) when
  /// [frame] does not hold a complete, well-formed frame yet.
  bool frameComplete(int expLen) {
    if (!frame.startsWithBytes(head) ||
        (!frame.endsWithBytes(tail) && frame.length < expLen)) {
      return false;
    }
    if (!frame.endsWithBytes(tail)) {
      frame.clear();
      return false;
    }
    if (frame.length.isOdd || !isHexDigits(frame.sl(1, -1))) {
      frame.clear();
      return false;
    }
    if (frame.length != expLen) {
      frame.clear();
      return false;
    }
    return true;
  }

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    if (!collect(data)) return;
    final expLen = expFrameLen();
    if (!frameComplete(expLen)) return;
    if (!name.startsWith(_ignoreCrc) &&
        !checkIntegrity(frame, (x) => crcSum(x) ^ 0xFF, (
          1,
          -3,
        ), hexInt(frame.sl(-3, -1)))) {
      frame.clear();
      return;
    }
    msg = fromHexStr(String.fromCharCodes(frame.sl(1, -1)));
    msgEvent.set();
  }

  Future<Map<int, List<int>>> _queryBms() async {
    final raw = <int, List<int>>{};
    for (final cmd in [':000250000E03~', ':001031000E05~']) {
      await awaitMsg(ascii(cmd));
      final rsp = msg[1] & 0x7F;
      raw[rsp] = msg;
      if (rsp == cmdRt && msg.length == 0x45) {
        // single-frame variants (Metrisun, Chins)
        raw[cmdCap] = [...Uint8List(7), ...msg.sl(62)];
        break;
      }
    }
    return raw;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    final raw = await _queryBms();
    if (raw.length != 2 ||
        !raw.containsKey(cmdRt) ||
        !raw.containsKey(cmdCap) ||
        raw.values.any((v) => v.isEmpty)) {
      return {};
    }
    return BaseBms.decodeData(_fields, raw)
      ..['cell_voltages'] = BaseBms.cellVoltages(
        raw[cmdRt]!,
        cells: maxCells,
        start: cellPos,
      );
  }
}
