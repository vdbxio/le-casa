// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Alpicool-style 12 V compressor fridges (Alpicool, Brass Monkey, Vevor,
// and other rebadges of the same controller). Re-implemented from the
// protocol notes in jgalea/fridgekit (PROTOCOL.md) and
// klightspeed/BrassMonkeyFridgeMonitor, both MIT; no code copied.
//
// Service 0x1234, write 0x1235, notify 0x1236, no pairing or key. Every
// frame is FE FE, a length (command + data + checksum), the command, the
// data, and a big-endian 16-bit sum of everything before it. Temperatures
// are signed bytes in whatever unit the fridge is set to.

import 'dart:typed_data';

const alpicoolService = '00001234-0000-1000-8000-00805f9b34fb';
const alpicoolWrite = '00001235-0000-1000-8000-00805f9b34fb';
const alpicoolNotify = '00001236-0000-1000-8000-00805f9b34fb';

abstract final class AlpicoolCmd {
  static const bind = 0x00;
  static const query = 0x01;
  static const set = 0x02;
  static const reset = 0x04;
  static const setZone1 = 0x05;
  static const setZone2 = 0x06;
}

/// Battery protection levels: the compressor stops below the first voltage
/// and starts again above the second (12 V system; 24 V in the docs).
const alpicoolBatteryProtection = ['Low', 'Mid', 'High'];

Uint8List alpicoolFrame(int cmd, [List<int> data = const []]) {
  final f = [0xFE, 0xFE, data.length + 3, cmd, ...data];
  final sum = f.fold<int>(0, (a, b) => a + b) & 0xFFFF;
  return Uint8List.fromList([...f, sum >> 8, sum & 0xFF]);
}

Uint8List alpicoolQuery() => alpicoolFrame(AlpicoolCmd.query);

/// Sets one zone's target directly, without touching anything else.
Uint8List alpicoolSetTarget(int zone, int target) => alpicoolFrame(
  zone == 2 ? AlpicoolCmd.setZone2 : AlpicoolCmd.setZone1,
  [target & 0xFF],
);

int _s8(int b) => b >= 0x80 ? b - 0x100 : b;

/// One zone of the fridge.
class AlpicoolZone {
  final int target;
  final int current;
  final int hysteresis;

  /// Panel E6..E8 plus one undocumented byte; kept for writing back.
  final List<int> calibration;

  const AlpicoolZone({
    required this.target,
    required this.current,
    required this.hysteresis,
    required this.calibration,
  });
}

/// The query response.
class AlpicoolStatus {
  final bool locked;
  final bool on;
  final bool eco;

  /// Index into [alpicoolBatteryProtection].
  final int batteryProtection;
  final int maxTemp;
  final int minTemp;
  final int startDelay; // minutes
  final bool fahrenheit;
  final AlpicoolZone zone1;
  final AlpicoolZone? zone2;

  /// Percent, or null when the fridge does not know (it reports 0x7F).
  final int? batteryPercent;
  final double batteryVoltage;

  /// The raw data block, for anything not decoded above.
  final Uint8List raw;

  const AlpicoolStatus({
    required this.locked,
    required this.on,
    required this.eco,
    required this.batteryProtection,
    required this.maxTemp,
    required this.minTemp,
    required this.startDelay,
    required this.fahrenheit,
    required this.zone1,
    required this.zone2,
    required this.batteryPercent,
    required this.batteryVoltage,
    required this.raw,
  });

  String get unit => fahrenheit ? '°F' : '°C';

  /// The Set (0x02) data block with [change] applied. The fridge takes the
  /// whole settings block at once, so everything else is written back as
  /// it was read.
  Uint8List settings({
    bool? locked,
    bool? on,
    bool? eco,
    int? batteryProtection,
  }) {
    final z1 = zone1;
    // A fridge that sends the long status frame gets the long settings
    // block back, its second-zone bytes as read (zeros on one-zone units).
    final long = raw.length >= 28;
    return Uint8List.fromList([
      (locked ?? this.locked) ? 1 : 0,
      (on ?? this.on) ? 1 : 0,
      (eco ?? this.eco) ? 1 : 0,
      batteryProtection ?? this.batteryProtection,
      z1.target & 0xFF,
      maxTemp & 0xFF,
      minTemp & 0xFF,
      z1.hysteresis,
      startDelay,
      fahrenheit ? 1 : 0,
      ...z1.calibration,
      if (long) ...[
        // The zone 2 target goes before its two pad bytes; after them the
        // fridge silently reads zero.
        raw[18],
        0,
        0,
        raw[21],
        ...raw.sublist(22, 26),
        0,
        0,
        0,
      ],
    ]);
  }
}

/// Collects notification chunks into whole frames. A frame can arrive in
/// pieces, and stray bytes before FE FE are dropped.
class AlpicoolFramer {
  final _buf = <int>[];

  /// Adds a chunk; returns the complete frames it finished, in order.
  List<Uint8List> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Uint8List>[];
    while (true) {
      final start = _indexOfHeader();
      if (start < 0) {
        // keep a lone trailing FE, it may be half a header
        final keep = _buf.isNotEmpty && _buf.last == 0xFE;
        _buf.clear();
        if (keep) _buf.add(0xFE);
        return out;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < 3) return out;
      final total = _buf[2] + 3;
      if (_buf.length < total) return out;
      out.add(Uint8List.fromList(_buf.sublist(0, total)));
      _buf.removeRange(0, total);
    }
  }

  int _indexOfHeader() {
    for (var i = 0; i + 1 < _buf.length; i++) {
      if (_buf[i] == 0xFE && _buf[i + 1] == 0xFE) return i;
    }
    return -1;
  }
}

/// Checks the frame's checksum. Some units send twice the sum, so both are
/// accepted.
bool alpicoolValid(Uint8List f) {
  if (f.length < 6 || f[0] != 0xFE || f[1] != 0xFE) return false;
  if (f[2] + 3 != f.length) return false;
  final sum = f.sublist(0, f.length - 2).fold<int>(0, (a, b) => a + b);
  final got = (f[f.length - 2] << 8) | f[f.length - 1];
  return got == (sum & 0xFFFF) || got == ((sum * 2) & 0xFFFF);
}

int alpicoolCommandOf(Uint8List f) => f[3];

/// Parses a query response; null if [f] is not one.
AlpicoolStatus? parseAlpicoolStatus(Uint8List f) {
  if (!alpicoolValid(f) || f[3] != AlpicoolCmd.query) return null;
  final d = Uint8List.sublistView(f, 4, f.length - 2);
  if (d.length < 18) return null;
  // Single-zone fridges can send the long frame too, with the second zone
  // all zero. A real zone always has a hysteresis of at least 1.
  final dual = d.length >= 28 && d[21] != 0;
  return AlpicoolStatus(
    locked: d[0] != 0,
    on: d[1] != 0,
    eco: d[2] != 0,
    batteryProtection: d[3].clamp(0, 2),
    maxTemp: _s8(d[5]),
    minTemp: _s8(d[6]),
    startDelay: d[8],
    fahrenheit: d[9] == 1,
    zone1: AlpicoolZone(
      target: _s8(d[4]),
      current: _s8(d[14]),
      hysteresis: d[7],
      calibration: d.sublist(10, 14),
    ),
    zone2: dual
        ? AlpicoolZone(
            target: _s8(d[18]),
            current: _s8(d[26]),
            hysteresis: d[21],
            calibration: d.sublist(22, 26),
          )
        : null,
    batteryPercent: d[15] > 100 ? null : d[15],
    batteryVoltage: d[16] + d[17] / 10,
    raw: Uint8List.fromList(d),
  );
}
