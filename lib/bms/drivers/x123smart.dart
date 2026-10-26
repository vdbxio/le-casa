// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// 123electric 123\SmartBMS gen3. Streams text lines once enabled.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class X123smartBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'x123smart_bms',
    info: {'manufacturer': '123electric', 'model': r'123\SmartBMS'},
    matchers: [
      MatcherPattern(
        localName: r'123\SmartBMS',
        serviceUuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      ),
    ],
    create: X123smartBms.new,
    acceptSecret: true,
    secretHint: 'The four digit PIN set in the 123\\SmartBMS app.',
  );

  /// Upstream pings every second while connected (the app every 330 ms).
  static const aliveInterval = 1.0;

  static const _cr = 0x0D;
  static const _sep = 0x5F; // _
  static const _vScale = 0.005;
  static const _lmsg = -1; // the last reply
  static const _maxHexLen = 8;
  static const _msgFmt = {
    'U': 5,
    'T': 5,
    'M': 4,
    'V': 6,
    'C': 6,
    'E': 5,
    'H': 7,
    'B': 5,
  };
  static const _ping = [0x24]; // $
  static final _replies = [
    for (final r in ['OK', 'NA', 'WRONG', 'KO']) ascii(r),
  ];
  static const _tOffs = 0x114;

  static int _key(String tag) => tag.codeUnitAt(0) << 8;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 1, 1, false, (x) => x * _vScale, _key('U')),
    BmsDp('current', 3, 1, false, (x) => x * 0.05, _key('U')),
    BmsDp('battery_level', 4, 1, false, (x) => x, _key('E')),
    BmsDp('battery_health', 1, 1, false, (x) => x, _key('H')),
  ];
  static final _resps = {for (final f in _fields) f.idx};

  /// Lines by tag (`tag << 8`) plus the last reply under [_lmsg].
  final Map<int, List<int>> _msg = {};

  /// "C" lines by cell number. Upstream keys them `ord("C") << 8 + n`,
  /// which Python reads as a shift by 8 + n.
  final Map<int, List<int>> _cells = {};
  int _cellCount = 0;

  X123smartBms(super.device, [super.config]);

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

  static String _strictAscii(List<int> b) {
    if (b.any((c) => c > 0x7F)) throw const FormatException('not ASCII');
    return String.fromCharCodes(b);
  }

  @override
  Future<BmsInfo> fetchDeviceInfo() async {
    await _cmdExpectOk(ascii('D!'));
    await awaitMsg([...ascii('V@'), _cr]);
    final ver = _strictAscii(_msg[_lmsg] ?? const []).split('_').first;
    if (ver.length < 3) throw const FormatException('BMS data incomplete.');
    final build = ver.substring(2);
    await _cmdExpectOk(ascii('E!'));
    return {
      'fw_version':
          '${pyInt(ver[0], 16)}.${pyInt(ver[1], 16)}.${pyInt(build, 16)}',
    };
  }

  static int _parseInt(String hexStr) {
    var s = hexStr;
    var num = 1;
    if (s.isNotEmpty && (s[0] == '+' || s[0] == '-')) {
      num = s[0] == '-' ? -1 : 1;
      s = s.substring(1);
    }
    if (s.length > _maxHexLen) return 0;
    try {
      return pyInt(s, 16) * num;
    } on FormatException {
      return 0;
    }
  }

  /// Keep-alive ping.
  Future<void> alive() => awaitMsg(_ping, waitForNotify: false);

  static bool _hexUpper(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46);
  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    frame.extend(data);
    int pos;
    while ((pos = frame.find(const [_cr])) != -1) {
      final line = frame.sl(0, pos);
      frame.del(0, pos + 1);
      if (line.isEmpty) continue;

      final msgT = String.fromCharCode(line[0]);
      final second = line.length > 1 ? line[1] : null;
      if (_replies.any((r) => bytesEq(r, line)) ||
          (second != _sep &&
              line.sl(-2).every(_hexUpper) &&
              line.every(
                (c) => _hexUpper(c) || c == 0x2B || c == 0x2D || c == _sep,
              ) &&
              _crcSum(line.sl(0, -2)) ==
                  pyInt(String.fromCharCodes(line.sl(-2)), 16))) {
        _msg[_lmsg] = line;
        msgEvent.set();
        return;
      }

      if (!_msgFmt.containsKey(msgT) || second != _sep) continue;
      if (line.where((c) => c == _sep).length + 1 < _msgFmt[msgT]!) continue;
      if (msgT == 'C') {
        final n1 = line.sl(2, 4), n2 = line.sl(5, 7);
        if (!(n1.isNotEmpty &&
            n1.every(_isDigit) &&
            n2.isNotEmpty &&
            n2.every(_isDigit))) {
          continue;
        }
        _cells[pyInt(String.fromCharCodes(n1))] = line;
        _cellCount = pyInt(String.fromCharCodes(n2));
      } else {
        _msg[line[0] << 8] = line;
      }
    }
    if (_resps.every(_msg.containsKey)) msgEvent.set();
  }

  Future<void> _cmdExpectOk(List<int> cmd) async {
    await awaitMsg([...cmd, _cr]);
    final reply = _msg[_lmsg] ?? const <int>[];
    if (!bytesEq(reply, ascii('OK'))) {
      throw BmsPermissionException(
        'command rejected (${String.fromCharCodes(reply)})',
      );
    }
    _msg.clear();
    _cells.clear();
    msgEvent.clear();
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    await super.initConnection(charNotify);
    if (cfg.secret.isNotEmpty) {
      // four digit PIN
      await _cmdExpectOk(ascii('PW${cfg.secret}!'));
    }
    // start live data (refused without the PIN) and ping once
    await _cmdExpectOk(ascii('E!'));
    await awaitMsg(_ping, waitForNotify: false);
  }

  static int _crcSum(List<int> data) =>
      (data.sum - data.where((c) => c == 0x5F).length * 0x5F) & 0xFF;

  @override
  Future<BmsSample> asyncUpdate() async {
    try {
      await msgEvent.wait().timeout(BaseBms.secs(timeout));
    } on TimeoutException {
      if (_msg.isNotEmpty || _cells.isNotEmpty) {
        throw const FormatException('BMS data incomplete.');
      }
      rethrow;
    }
    msgEvent.clear();

    final result = _decodeLines()
      ..addAll(_parseCells(_cellCount))
      ..['cell_count'] = _cellCount;
    _msg.clear();
    _cells.clear();
    return result;
  }

  BmsSample _decodeLines() {
    final result = <String, Object?>{};
    for (final f in _fields) {
      final line = _msg[f.idx]!;
      final elements = _split(line);
      if (f.pos < 0 || f.pos >= elements.length) continue;
      result[f.key] = f.fct(_parseInt(elements[f.pos]));
    }
    return result;
  }

  static List<String> _split(List<int> line) => line.asciiIgnore.split('_');

  BmsSample _parseCells(int cells) {
    final cellV = <double>[];
    final cellT = <TempSensor>[];
    var cellS = 0;
    for (var cell = 0; cell < cells; cell++) {
      final line = _cells[cell + 1];
      if (line == null) throw const FormatException('BMS data incomplete.');
      final e = _split(line);
      cellV.add(_parseInt(e[3]) * _vScale);
      cellT.add(TempSensor(_parseInt(e[4]) - _tOffs, TempType.cell));
      cellS |= _parseInt(e[5]);
      if (e.length >= 7) cellS |= _parseInt(e[6]) << 8;
    }
    return {
      'cell_voltages': cellV,
      'temp_values': cellT,
      'chrg_mosfet': cellS & 0x1 != 0,
      'dischrg_mosfet': cellS & 0x1 != 0,
      'problem_code': cellS & 0x0EFC,
    };
  }
}
