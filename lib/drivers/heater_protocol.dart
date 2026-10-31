// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Chinese diesel air heaters (Hcalory, Vevor, BYD and other rebadges) with
// the "BYD-<address>" Bluetooth module. Re-implemented from
// Spettacolo83/diesel-heater-ble and Spettacolo83/homeassistant-diesel-heater
// (both MIT); no code copied.
//
// Service 0xFFE0 with one characteristic, 0xFFE1, that takes commands
// (written without response) and notifies status. Commands are always
// eight plain bytes: AA 55, the passkey as two base-100 digits, command,
// a little-endian 16-bit argument, and a sum of bytes 2..6. Status comes
// back in one of four layouts: AA 55 (18 or 20 bytes) and AA 66 (20) in the
// clear, or either one padded to 48 bytes and XORed with "password".

import 'dart:typed_data';

const heaterService = '0000ffe0-0000-1000-8000-00805f9b34fb';
const heaterChar = '0000ffe1-0000-1000-8000-00805f9b34fb';

/// The passkey the heaters ship with. The controller's settings can change
/// it; a heater with a different one ignores every command.
const heaterDefaultPasskey = 1234;

abstract final class HeaterCmd {
  static const status = 1;
  static const mode = 2; // argument: HeaterMode.level or .temperature
  static const power = 3; // argument: 1 on, 0 off
  static const setValue = 4; // level 1..10 or target °C, per the mode
}

abstract final class HeaterMode {
  static const manual = 0;
  static const level = 1;
  static const temperature = 2;
}

/// The heater's running step: what it is doing right now.
const heaterSteps = {
  0: 'Standby',
  1: 'Self-test',
  2: 'Igniting',
  3: 'Running',
  4: 'Cooling down',
  6: 'Ventilating',
};

/// Fault codes the AA 55 / AA 66 heaters report.
const heaterErrors = {
  1: 'Startup failure',
  2: 'Out of fuel',
  3: 'Supply voltage out of range',
  4: 'Outlet sensor fault',
  5: 'Inlet sensor fault',
  6: 'Fuel pump fault',
  7: 'Fan fault',
  8: 'Glow plug fault',
  9: 'Overheating',
  10: 'Overheat sensor fault',
};

const heaterMinLevel = 1;
const heaterMaxLevel = 10;
const heaterMinTemp = 8;
const heaterMaxTemp = 36;

Uint8List heaterCommand(
  int cmd,
  int arg, {
  int passkey = heaterDefaultPasskey,
}) {
  final f = [
    0xAA,
    0x55,
    passkey ~/ 100 % 100,
    passkey % 100,
    cmd & 0xFF,
    arg & 0xFF,
    (arg >> 8) & 0xFF,
  ];
  final sum = f.skip(2).fold<int>(0, (a, b) => a + b) & 0xFF;
  return Uint8List.fromList([...f, sum]);
}

const _key = [0x70, 0x61, 0x73, 0x73, 0x77, 0x6F, 0x72, 0x64]; // "password"

/// XORs [data] with the key, repeated across the first 48 bytes. The same
/// call encrypts and decrypts.
Uint8List heaterXor(List<int> data) => Uint8List.fromList([
  for (final (i, b) in data.indexed) i < 48 ? b ^ _key[i % 8] : b,
]);

/// One status notification, decoded.
class HeaterStatus {
  /// Which of the four layouts it came in: AA55, AA66, AA55 encrypted or
  /// AA66 encrypted.
  final String layout;
  final bool on;

  /// Key into [heaterSteps].
  final int step;

  /// 0 for none, else a key into [heaterErrors].
  final int error;

  /// A [HeaterMode] value.
  final int mode;

  /// Power level 1..10, when the heater reports one.
  final int? level;

  /// Thermostat target, when the heater reports one.
  final int? target;
  final double voltage;

  /// The heat exchanger, which runs far hotter than the air.
  final double? caseTemp;

  /// The air at the heater's (or its controller's) sensor.
  final double? cabinTemp;
  final bool fahrenheit;

  /// Carbon monoxide, on the encrypted layouts when a sensor is fitted.
  final double? coPpm;

  const HeaterStatus({
    required this.layout,
    required this.on,
    required this.step,
    required this.error,
    required this.mode,
    required this.level,
    required this.target,
    required this.voltage,
    required this.caseTemp,
    required this.cabinTemp,
    this.fahrenheit = false,
    this.coPpm,
  });

  String get unit => fahrenheit ? '°F' : '°C';
  String get stepName => heaterSteps[step] ?? 'Step $step';
  String? get errorName =>
      error == 0 ? null : heaterErrors[error] ?? 'Fault $error';
}

int _s16(int v) => v >= 0x8000 ? v - 0x10000 : v;

/// Parses one whole status frame, encrypted or not; null if [f] is not one.
HeaterStatus? parseHeaterStatus(List<int> f) {
  if (f.length < 18) return null;
  if (f.length == 48) {
    final d = heaterXor(f);
    if (d[0] != 0xAA) return null;
    if (d[1] == 0x55) return _encrypted(d, aa66: false);
    if (d[1] == 0x66) return _encrypted(d, aa66: true);
    return null;
  }
  if (f[0] != 0xAA) return null;
  if (f[1] == 0x55 && (f.length == 18 || f.length == 20)) return _aa55(f);
  if (f[1] == 0x66 && f.length == 20) return _aa66(f);
  return null;
}

HeaterStatus _aa55(List<int> d) {
  final mode = d[8];
  return HeaterStatus(
    layout: 'AA55',
    on: d[3] != 0,
    step: d[5],
    error: d[4],
    mode: mode,
    level: switch (mode) {
      HeaterMode.level => d[9],
      _ => d[10] + 1,
    },
    target: mode == HeaterMode.temperature ? d[9] : null,
    voltage: (d[11] | d[12] << 8) / 10,
    caseTemp: _s16(d[13] | d[14] << 8).toDouble(),
    cabinTemp: _s16(d[15] | d[16] << 8).toDouble(),
  );
}

HeaterStatus _aa66(List<int> d) {
  final mode = d[8];
  // Most send the exchanger in whole degrees; some in tenths, which shows
  // as an implausible reading above 350.
  final rawCase = d[13] | d[14] << 8;
  return HeaterStatus(
    layout: 'AA66',
    on: d[3] != 0,
    step: d[5],
    error: d[17],
    mode: mode,
    level: (mode == HeaterMode.level ? d[9] : d[10] + 1).clamp(
      heaterMinLevel,
      heaterMaxLevel,
    ),
    target: mode == HeaterMode.temperature
        ? d[9].clamp(heaterMinTemp, heaterMaxTemp)
        : null,
    voltage: (d[11] | d[12] << 8) / 10,
    caseTemp: rawCase > 350 ? rawCase / 10 : rawCase.toDouble(),
    cabinTemp: _s16(d[15] | d[16] << 8).toDouble(),
  );
}

/// The two 48-byte layouts share everything but where the fault code and
/// the temperature unit sit. Their multi-byte fields are big-endian.
HeaterStatus _encrypted(Uint8List d, {required bool aa66}) {
  final fahrenheit = aa66 && d[27] == 1;
  return HeaterStatus(
    layout: aa66 ? 'AA66 encrypted' : 'AA55 encrypted',
    on: d[3] != 0,
    step: d[5],
    error: aa66 ? d[35] : d[4],
    mode: d[8],
    level: d[10].clamp(heaterMinLevel, heaterMaxLevel),
    target: d[9],
    voltage: (d[11] << 8 | d[12]) / 10,
    caseTemp: _s16(d[13] << 8 | d[14]).toDouble(),
    cabinTemp: _s16(d[32] << 8 | d[33]) / 10,
    fahrenheit: fahrenheit,
    coPpm: d[37] == 1 ? (d[38] << 8 | d[39]).toDouble() : null,
  );
}

/// Collects notifications into whole frames. The clear layouts fit one
/// notification; the 48-byte ones arrive in two or three on a small MTU.
class HeaterFramer {
  final _buf = <int>[];

  List<Uint8List> add(List<int> chunk) {
    // A clear frame always starts a notification of its own.
    if (chunk.length >= 2 &&
        chunk[0] == 0xAA &&
        (chunk[1] == 0x55 || chunk[1] == 0x66)) {
      _buf.clear();
      return [Uint8List.fromList(chunk)];
    }
    // "AA 55" and "AA 66" encrypted with the key's first two bytes.
    final starts =
        chunk.length >= 2 &&
        chunk[0] == 0xDA &&
        (chunk[1] == 0x34 || chunk[1] == 0x07);
    if (starts) _buf.clear();
    if (_buf.isEmpty && !starts) return const [];
    _buf.addAll(chunk);
    if (_buf.length < 48) return const [];
    final f = Uint8List.fromList(_buf.sublist(0, 48));
    _buf.clear();
    return [f];
  }
}
