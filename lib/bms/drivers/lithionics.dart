// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Lithionics NeverDie smart BMS. Pushes comma separated text lines.

import 'dart:convert';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class LithionicsBms extends BaseBms {
  static const spec = BmsSpec(
    module: 'lithionics_bms',
    info: {'manufacturer': 'Lithionics', 'model': 'NeverDie smart BMS'},
    matchers: [
      MatcherPattern(
        localName: 'Li[0-9]-*',
        serviceUuid: 'ffe0',
        manufacturerId: 19784,
      ),
    ],
    create: LithionicsBms.new,
  );

  static const _prim = 1;
  static const _stat = 2;
  static const _headStat = [0x26, 0x2C]; // "&,"
  static const _minFieldsPrim = 10;
  static const _minFieldsStat = 3;
  static const _minFieldsMod = 13;
  static const _fixedLenPrim = 46;
  static const _problemMask = 0x68CEFD;
  static const _maxDigits = 9;
  static const _maxModule = 9;

  static double _fToC(int x) => pyRound((x - 32) * 5 / 9, 3);
  static int _hexProblem(int x) => pyInt('$x', 16) & _problemMask;

  static final _fields = <BmsDp>[
    BmsDp('voltage', 0, 1, false, (x) => x / 100, _prim),
    BmsDp('cell_voltages', 1, 4, false, (x) => x / 100, _prim),
    BmsDp('temp_values', 5, 2, false, _fToC, _prim),
    BmsDp('current', 7, 1, false, (x) => x.toDouble(), _prim),
    BmsDp('battery_level', 8, 1, false, (x) => x, _prim),
    BmsDp('problem_code', 9, 1, false, _hexProblem, _prim),
    BmsDp('cycle_charge', 2, 1, false, (x) => x, _stat),
    BmsDp('total_charge', 3, 1, false, (x) => x, _stat),
  ];
  static final _fieldsFixed = <BmsDp>[
    BmsDp('voltage', 2, 1, false, (x) => x / 10, _prim),
    BmsDp('battery_level', 3, 1, false, (x) => x, _prim),
    BmsDp('cycle_charge', 1, 1, false, (x) => x / 10, _prim),
    BmsDp('current', 6, 1, false, (x) => x / 10, _prim),
    BmsDp('power', 7, 1, false, (x) => x, _prim),
    BmsDp('battery_charging', 5, 1, false, (x) => x == 1, _prim),
    BmsDp('temp_values', 8, 1, false, _fToC, _prim),
    BmsDp('problem_code', 9, 1, false, _hexProblem, _prim),
  ];

  final Map<int, List<int>> _msg = {};

  LithionicsBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => [uuid16(0xFFE0)];
  @override
  String get uuidRx => 'ffe1';
  @override
  String get uuidTx => throw UnimplementedError('Lithionics only pushes data');

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  @override
  void notificationHandler(GattChar sender, Uint8List data) {
    frame.extend(data);

    int idx;
    while ((idx = frame.find(const [0x0D, 0x0A])) >= 0) {
      final line = frame.sl(0, idx);
      frame.del(0, idx + 2);
      if (line.isEmpty) continue;
      if (bytesEq(line, ascii('ERROR'))) continue;

      final fields = line.where((c) => c == 0x2C).length + 1;
      if (line.startsWithBytes(const [0x23, 0x2C]) && fields >= _minFieldsMod) {
        final parts = _split(line, 3);
        final moduleId = parts[2];
        if (moduleId.isEmpty ||
            !moduleId.every(_isDigit) ||
            pyInt(String.fromCharCodes(moduleId)) > _maxModule) {
          continue;
        }
        _msg[pyInt(String.fromCharCodes(moduleId)) << 8] = line;
      } else if (line.startsWithBytes(_headStat) && fields >= _minFieldsStat) {
        _msg[_stat] = line;
      } else if (_isDigit(line[0]) && fields >= _minFieldsPrim) {
        _msg[_prim] = line;
      }
    }

    if (_msg.containsKey(_prim) && _msg.containsKey(_stat)) msgEvent.set();
    if (frame.length > BaseBms.bleMaxAttrSize) frame.clear();
  }

  /// bytes.split(b",", maxsplit)
  static List<List<int>> _split(List<int> line, int maxsplit) {
    final out = <List<int>>[];
    var start = 0;
    for (var i = 0; i < line.length && out.length < maxsplit; i++) {
      if (line[i] == 0x2C) {
        out.add(line.sublist(start, i));
        start = i + 1;
      }
    }
    out.add(line.sublist(start));
    return out;
  }

  static bool _isFixedLength(List<int> msg) =>
      msg.length == _fixedLenPrim && msg.find(const [0x2C]) == 1;

  static int _int(String value) {
    if (value.length > _maxDigits) {
      throw FormatException('numeric field too long: $value');
    }
    return pyInt(value);
  }

  /// ASCII decode; Python raises UnicodeDecodeError (a ValueError).
  static String _ascii(List<int> raw) {
    if (raw.any((c) => c > 0x7F)) throw const FormatException('not ASCII');
    return const AsciiDecoder().convert(raw);
  }

  static BmsSample _decodeModule(List<int> data) {
    final fields = _ascii(data).split(',');
    List<String> slice(int pos, int size) => fields.sublist(
      pos.clamp(0, fields.length),
      (pos + size).clamp(0, fields.length),
    );
    final result = <String, Object?>{};
    result['cell_count'] = _int(slice(5, 1)[0]);
    result['temp_values'] = [
      for (final v in slice(6, 2)) TempSensor(pyFloat(v)),
    ];
    final dv = slice(8, 2);
    result['delta_voltage'] = (_int(dv[1]) - _int(dv[0])) / 100;
    final cellCount = result['cell_count'] as int;
    final cellValues = slice(13, cellCount < 0 ? 0 : cellCount);
    if (cellValues.length == cellCount) {
      result['cell_voltages'] = [for (final v in cellValues) _int(v) / 100];
    }
    return result;
  }

  static BmsSample _decodeLines(List<BmsDp> fields, Map<int, List<int>> data) {
    final lines = {
      for (final e in data.entries) e.key: _ascii(e.value).trim().split(','),
    };
    final result = <String, Object?>{};
    for (final f in fields) {
      final end = f.pos + f.size;
      final msg = lines[f.idx]!;
      if (end > msg.length) continue;
      if (f.key == 'cell_voltages') {
        result[f.key] = [for (var i = f.pos; i < end; i++) f.fct(_int(msg[i]))];
      } else if (f.key == 'temp_values') {
        result[f.key] = [
          for (var i = f.pos; i < end; i++)
            TempSensor(f.fct(_int(msg[i])) as num),
        ];
      } else {
        result[f.key] = f.fct(_int(msg[f.pos]));
      }
    }
    return result;
  }

  @override
  Future<BmsSample> asyncUpdate() async {
    try {
      await waitEventFor(timeout);
      final fields = _isFixedLength(_msg[_prim]!) ? _fieldsFixed : _fields;
      final result = _decodeLines(fields, _msg);
      final moduleKeys = _msg.keys.where((k) => k >= 0x100).toList()..sort();
      if (moduleKeys.isNotEmpty) {
        result['packs'] = [for (final k in moduleKeys) _decodeModule(_msg[k]!)];
      }
      return result;
    } on FormatException {
      throw const FormatException('BMS data incomplete.');
    } on RangeError {
      throw const FormatException('BMS data incomplete.');
    } finally {
      _msg.clear(); // never keep lines across updates
      msgEvent.clear();
    }
  }
}
