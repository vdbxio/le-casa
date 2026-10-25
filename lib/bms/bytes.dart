// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Byte and number helpers with Python semantics, so BMS drivers can be
// ported from aiobmsble without re-deriving every slice and division.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bms_types.dart';

/// Python `int.from_bytes`. Values wider than 63 bits wrap, like any Dart
/// int; only 64-bit alarm masks get that wide.
int intFrom(List<int> b, {bool little = false, bool signed = false}) {
  var v = 0;
  final n = b.length;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | (b[little ? n - 1 - i : i] & 0xFF);
  }
  if (signed && n > 0 && n < 8 && (b[little ? n - 1 : 0] & 0x80) != 0) {
    v -= 1 << (8 * n);
  }
  return v;
}

/// Python `int.to_bytes(size, byteorder)`.
Uint8List intTo(int v, int size, {bool little = false}) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    final b = (v >> (8 * i)) & 0xFF;
    out[little ? i : size - 1 - i] = b;
  }
  return out;
}

Uint8List bytesOf(Iterable<int> parts) => Uint8List.fromList(parts.toList());

/// Concatenates byte lists.
Uint8List cat(List<List<int>> parts) {
  final out = <int>[];
  for (final p in parts) {
    out.addAll(p);
  }
  return Uint8List.fromList(out);
}

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

bool bytesEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Python floor division for ints (Dart's `~/` truncates toward zero).
int floorDiv(int a, int b) {
  final q = a ~/ b;
  return (q * b != a && (a < 0) != (b < 0)) ? q - 1 : q;
}

/// Python `round(x, n)`: correctly rounded, half-to-even on exact ties.
double pyRound(num x, [int n = 0]) {
  if (x.isNaN || x.isInfinite) return x.toDouble();
  if (n < 0) {
    final p = math.pow(10, -n).toDouble();
    return pyRound(x / p) * p;
  }
  // toStringAsFixed rounds the exact binary value correctly, but resolves
  // exact ties upwards; Python resolves them to even.
  final exact = x.abs().toStringAsFixed(20);
  final dot = exact.indexOf('.');
  final tail = exact.substring(dot + 1 + n);
  if (n <= 19 && tail.startsWith('5') && tail.substring(1).replaceAll('0', '').isEmpty) {
    final lastKept = n == 0 ? exact[dot - 1] : exact[dot + n];
    final down = double.parse(exact.substring(0, dot + 1 + n).replaceAll(RegExp(r'\.$'), ''));
    final m = math.pow(10, n).toDouble();
    final r = int.parse(lastKept).isEven ? down : down + 1 / m;
    final v = double.parse(r.toStringAsFixed(n));
    return x < 0 ? -v : v;
  }
  return double.parse(x.toStringAsFixed(n));
}

/// Python `int(round(x))` for the few places that want an int back.
int pyRoundInt(num x) => pyRound(x).toInt();

extension PyBytes on List<int> {
  int _ix(int i) => i < 0 ? length + i : i;

  /// Index with Python negative indexing.
  int at(int i) => this[_ix(i)];

  /// Python slice `[start:end]`, clamped, negative indices allowed.
  Uint8List sl([int? start, int? end]) {
    var s = start ?? 0;
    var e = end ?? length;
    if (s < 0) s = math.max(0, length + s);
    if (e < 0) e = math.max(0, length + e);
    if (s > length) s = length;
    if (e > length) e = length;
    if (e <= s) return Uint8List(0);
    return Uint8List.fromList(sublist(s, e));
  }

  /// Integer from a slice, `int.from_bytes(self[start:end], ...)`.
  int u(
    int start,
    int size, {
    bool little = false,
    bool signed = false,
  }) => intFrom(sl(start, start + size), little: little, signed: signed);

  bool startsWithBytes(List<int> prefix, [int start = 0]) {
    if (start < 0) start = math.max(0, length + start);
    if (length - start < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (this[start + i] != prefix[i]) return false;
    }
    return true;
  }

  bool endsWithBytes(List<int> suffix) {
    if (length < suffix.length) return false;
    final o = length - suffix.length;
    for (var i = 0; i < suffix.length; i++) {
      if (this[o + i] != suffix[i]) return false;
    }
    return true;
  }

  /// Python `find`: first index of [sub] at or after [start], or -1.
  int find(List<int> sub, [int start = 0, int? end]) {
    var s = start < 0 ? math.max(0, length + start) : start;
    var e = end ?? length;
    if (e < 0) e = math.max(0, length + e);
    if (e > length) e = length;
    for (var i = s; i + sub.length <= e; i++) {
      var ok = true;
      for (var j = 0; j < sub.length; j++) {
        if (this[i + j] != sub[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  Uint8List get bytes => Uint8List.fromList(this);

  String get hex =>
      map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();

  /// Python `bytes.decode("ascii", errors="ignore")`.
  String get asciiIgnore =>
      String.fromCharCodes(where((b) => b >= 0 && b < 0x80));

  int get sum => fold(0, (a, b) => a + b);
}

/// Python `bytes.fromhex` for ASCII hex text (spaces allowed). Throws
/// [FormatException] on anything else, like Python's ValueError.
Uint8List fromHexStr(String s) {
  final t = s.replaceAll(RegExp(r'[ \t\n\r\x0b\x0c]'), '');
  if (t.length.isOdd) throw const FormatException('odd-length hex string');
  final out = Uint8List(t.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(t.substring(2 * i, 2 * i + 2), radix: 16);
    if (v == null || t.substring(2 * i, 2 * i + 2).contains(RegExp(r'[^0-9a-fA-F]'))) {
      throw FormatException('non-hex digit in "$s"');
    }
    out[i] = v;
  }
  return out;
}

/// Python `int(text, 16)` on bytes holding ASCII hex digits.
int hexInt(List<int> asciiHex) {
  final s = String.fromCharCodes(asciiHex).trim();
  if (s.isEmpty || s.contains(RegExp(r'[^0-9a-fA-F]'))) {
    throw FormatException('invalid hex number "$s"');
  }
  return int.parse(s, radix: 16);
}

bool isHexDigits(List<int> b) => b.every(
  (c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66),
);

/// A growable byte buffer with a size bound, like aiobmsble's
/// BoundedByteArray. Every mutation that would exceed [maxlen] throws
/// [BufferException] and leaves the contents unchanged.
class ByteBuf extends ListBase<int> {
  final int maxlen;
  final List<int> _d;

  ByteBuf(this.maxlen, [Iterable<int> initial = const []])
    : _d = List<int>.of(initial) {
    if (_d.length > maxlen) {
      throw BufferException('maximum length is $maxlen, got ${_d.length}');
    }
  }

  @override
  int get length => _d.length;

  @override
  set length(int n) {
    if (n > maxlen) throw BufferException('maximum length is $maxlen');
    if (n < _d.length) {
      _d.removeRange(n, _d.length);
    } else {
      _d.addAll(List.filled(n - _d.length, 0));
    }
  }

  @override
  int operator [](int i) => _d[i < 0 ? _d.length + i : i];

  @override
  void operator []=(int i, int v) => _d[i < 0 ? _d.length + i : i] = v & 0xFF;

  @override
  void add(int element) {
    if (_d.length + 1 > maxlen) {
      throw BufferException('maximum length is $maxlen, got ${_d.length + 1}');
    }
    _d.add(element & 0xFF);
  }

  @override
  void addAll(Iterable<int> iterable) => extend(iterable);

  void extend(Iterable<int> values) {
    final v = values.toList();
    if (_d.length + v.length > maxlen) {
      throw BufferException(
        'maximum length is $maxlen, got ${_d.length + v.length}',
      );
    }
    _d.addAll(v);
  }

  @override
  void clear() => _d.clear();

  /// Python `del buf[start:end]`.
  void del([int? start, int? end]) {
    var s = start ?? 0;
    var e = end ?? _d.length;
    if (s < 0) s = math.max(0, _d.length + s);
    if (e < 0) e = math.max(0, _d.length + e);
    if (e > _d.length) e = _d.length;
    if (e > s) _d.removeRange(s, e);
  }

  /// Python `buf[:] = data`.
  void setAll_(Iterable<int> data) {
    final v = data.toList();
    if (v.length > maxlen) throw BufferException('maximum length is $maxlen');
    _d
      ..clear()
      ..addAll(v);
  }
}

/// Splits a stream of bytes into frames framed by DLE/STX ... DLE/ETX with
/// DLE escaping. Port of aiobmsble's StreamParser.
class StreamParser {
  static const maxSize = 1024;
  final int dle;
  final int stx;
  final int etx;
  bool _inFrame = false;
  bool _escaped = false;
  final List<int> _buffer = [];

  StreamParser({this.dle = 0x10, this.stx = 0x02, this.etx = 0x03});

  Uint8List? feed(List<int> data) {
    Uint8List? result;
    for (final b in data) {
      if (!_inFrame) {
        if (_escaped && b == stx) {
          _inFrame = true;
          _buffer.clear();
          _escaped = false;
          continue;
        }
        _escaped = b == dle || b == stx || b == etx;
        continue;
      }
      if (_escaped) {
        _escaped = false;
        if (b == dle || b == stx) _buffer.add(b);
        if (b == etx) {
          _inFrame = false;
          result = Uint8List.fromList(_buffer);
          _buffer.clear();
        }
        continue;
      }
      if (b == dle || b == etx) {
        _escaped = true;
        continue;
      }
      _buffer.add(b);
      if (_buffer.length > maxSize) {
        _inFrame = false;
        _buffer.clear();
        continue;
      }
    }
    return result;
  }
}

/// Decodes bytes as ASCII, stopping at the first non-printable character,
/// then trims. Port of aiobmsble's b2str.
String b2str(List<int> b) {
  final s = b.asciiIgnore;
  for (var i = 0; i < s.length; i++) {
    if (!_printable(s.codeUnitAt(i))) return s.substring(0, i).trim();
  }
  return s.trim();
}

bool _printable(int c) => c >= 0x20 && c < 0x7F;

/// Leading digits of a string as an int (aiobmsble lstr2int). Throws
/// [FormatException] when there are none.
int lstr2int(String s) {
  final m = RegExp(r'^\d+').firstMatch(s);
  if (m == null) throw FormatException('no digits in "$s"');
  return int.parse(m.group(0)!);
}

/// Swaps the high and low 16-bit halves of a 32-bit value.
int swap32(int value, {bool signed = false}) {
  var v = ((value >> 16) & 0xFFFF) | ((value & 0xFFFF) << 16);
  if (signed && (v & 0x80000000) != 0) v -= 0x100000000;
  return v;
}

/// CRC-16 MODBUS.
int crcModbus(List<int> data) {
  var crc = 0xFFFF;
  for (final i in data) {
    crc ^= i & 0xFF;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

/// MODBUS LRC.
int lrcModbus(List<int> data) => ((data.sum ^ 0xFFFF) + 1) & 0xFFFF;

/// CRC-16-CCITT XMODEM.
int crcXmodem(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    crc ^= (byte & 0xFF) << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
    }
  }
  return crc & 0xFFFF;
}

/// CRC-8/MAXIM-DOW.
int crc8(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    crc ^= byte & 0xFF;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1;
    }
  }
  return crc & 0xFF;
}

/// Sum of the bytes, truncated to [size] bytes.
int crcSum(List<int> frame, [int size = 1]) =>
    frame.sum & ((1 << (8 * size)) - 1);

/// Mean of numbers or temperature sensors (Python statistics.fmean).
double fmean(Iterable<Object?> values) {
  var s = 0.0;
  var n = 0;
  for (final v in values) {
    s += v is TempSensor ? v.value : (v as num).toDouble();
    n++;
  }
  if (n == 0) throw StateError('fmean of empty data');
  return s / n;
}

/// Numeric view of a value that may be a TempSensor.
double numOf(Object? v) => v is TempSensor ? v.value : (v as num).toDouble();

final _pyIntRe = RegExp(r'^\s*([+-]?)([0-9a-zA-Z]+(?:_[0-9a-zA-Z]+)*)\s*$');

/// Python `int(text, radix)`: surrounding whitespace, a sign and single
/// underscores between digits are allowed. Throws [FormatException].
int pyInt(String s, [int radix = 10]) {
  final m = _pyIntRe.firstMatch(s);
  if (m == null) throw FormatException('invalid literal for int(): $s');
  final v = int.parse(m[2]!.replaceAll('_', ''), radix: radix);
  return m[1] == '-' ? -v : v;
}

final _pyFloatSpecial = RegExp(r'^([+-]?)(inf|infinity|nan)$', caseSensitive: false);

/// Python `float(text)`. Throws [FormatException].
double pyFloat(String s) {
  final t = s.trim();
  final m = _pyFloatSpecial.firstMatch(t);
  if (m != null) {
    final v = m[2]!.toLowerCase() == 'nan' ? double.nan : double.infinity;
    return m[1] == '-' ? -v : v;
  }
  if (!RegExp(r'^[+-]?(\d(_?\d)*)?(\.(\d(_?\d)*)?)?([eE][+-]?\d(_?\d)*)?$').hasMatch(t) ||
      !RegExp(r'\d').hasMatch(t.split(RegExp('[eE]')).first)) {
    throw FormatException('could not convert string to float: $s');
  }
  return double.parse(t.replaceAll('_', ''));
}

final List<int> _crc32Table = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// zlib.crc32
int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crc32Table[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
