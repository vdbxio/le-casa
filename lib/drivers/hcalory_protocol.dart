// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Hcalory's own Bluetooth module, the one its app calls "MVP2": service
// 0xBD39, commands written to 0xBDF7, replies notified on 0xBDF8. Usually
// no advertised name. Re-implemented from Spettacolo83/diesel-heater-ble,
// Spettacolo83/homeassistant-diesel-heater (MIT) and evanfoster/
// hcalory-control (LGPL-3.0, command values only); no code copied.
// Checked against Chloe's heater from a Mac on 2026-10-31.
//
// Every frame is a 2-byte kind (00 02 command, 00 03 reply, 00 01 pushed
// status), 00 01 00 01, a 2-byte data point id at bytes 7-8, 00 00, a
// payload length, the payload, and a sum of bytes 8 onwards. Nothing is
// answered until the 4-digit PIN has been sent (data point 0A0C); a wrong
// PIN gets a reply with 02 at byte 17 and silence after.

import 'dart:typed_data';

import 'heater_protocol.dart';

const hcaloryService = '0000bd39-0000-1000-8000-00805f9b34fb';
const hcaloryWrite = '0000bdf7-0000-1000-8000-00805f9b34fb';
const hcaloryNotify = '0000bdf8-0000-1000-8000-00805f9b34fb';

/// PINs to try, in order. Chloe's heater takes 0000 and refuses 1234; the
/// integrations' default is 1234.
const hcaloryPins = ['0000', '1234'];

abstract final class HcaloryDp {
  static const button = 0x0E04; // payload: 8 zero bytes, then a HcaloryButton
  static const setLevel = 0x0607; // payload: level
  static const setTarget = 0x0706; // payload: target, unit (0 °C, 1 °F)
  static const pin = 0x0A0C; // payload: 01, four digits
  static const status = 0x2303; // the pushed status
}

/// The heater's buttons, pressed through [HcaloryDp.button].
abstract final class HcaloryButton {
  static const query = 0x00;
  static const off = 0x01;
  static const on = 0x02;
  static const up = 0x03;
  static const down = 0x04;
  static const thermostat = 0x06;
  static const level = 0x07;
}

const hcaloryErrors = {
  1: 'E01 ignition failure',
  2: 'E02 flame out',
  3: 'E03 overheating',
  4: 'E04 fan fault',
  5: 'E05 fuel pump fault',
  6: 'E06 sensor fault',
  7: 'E07 low voltage',
  8: 'E08 high voltage',
  9: 'E09 communication fault',
  10: 'E10 carbon monoxide high',
  11: 'E11 carbon monoxide critical',
};

const hcaloryMinTemp = 0;
const hcaloryMaxTemp = 40;

Uint8List hcaloryFrame(int dp, List<int> payload) {
  final body = [dp & 0xFF, 0, 0, payload.length, ...payload];
  final sum = body.fold<int>(0, (a, b) => a + b) & 0xFF;
  return Uint8List.fromList([0, 2, 0, 1, 0, 1, 0, dp >> 8, ...body, sum]);
}

Uint8List hcaloryPress(int button) =>
    hcaloryFrame(HcaloryDp.button, [0, 0, 0, 0, 0, 0, 0, 0, button]);

Uint8List hcaloryPin(String pin) =>
    hcaloryFrame(HcaloryDp.pin, [1, for (final c in pin.codeUnits) c - 0x30]);

Uint8List hcaloryLevel(int level) => hcaloryFrame(HcaloryDp.setLevel, [level]);

Uint8List hcaloryTarget(int target, {bool fahrenheit = false}) =>
    hcaloryFrame(HcaloryDp.setTarget, [target, fahrenheit ? 1 : 0]);

int _dp(List<int> f) => f[7] << 8 | f[8];

bool hcaloryValid(List<int> f) {
  if (f.length < 13 || f[0] != 0 || f[1] > 3) return false;
  if (f.length != 13 + f[11]) return false;
  final sum = f.sublist(8, f.length - 1).fold<int>(0, (a, b) => a + b);
  return (sum & 0xFF) == f.last;
}

/// The PIN reply: true if accepted, false if refused, null if [f] is not
/// one.
bool? hcaloryPinAccepted(List<int> f) {
  if (!hcaloryValid(f) || _dp(f) != 0x0B0C || f.length < 18) return null;
  return f[17] == 1;
}

/// Parses a status frame; null if [f] is not one.
HeaterStatus? parseHcaloryStatus(List<int> f) {
  if (!hcaloryValid(f) || _dp(f) != HcaloryDp.status || f.length < 38) {
    return null;
  }
  final status = f[20] >> 4; // 0 off, 4 stopping, 8 heating, C fan, F fault
  // The fan runs first (1), then the glow plug (3), then the burner (5);
  // on the fan-only setting (status C) the fan is all there is.
  final step = switch (f[20] & 0x0F) {
    _ when status == 0x4 => 4,
    1 => status == 0xC ? 6 : 7,
    3 => 2,
    5 => 3,
    _ => 0,
  };
  final mode = switch (f[21]) {
    1 => HeaterMode.temperature,
    2 => HeaterMode.level,
    3 => HeaterMode.fan,
    _ => HeaterMode.manual,
  };
  // The set value means nothing while the heater is off or stopping, and
  // carries the fault code when it has one.
  final live = status == 0x8 || status == 0xC;
  final fahrenheit = f[37] == 1;
  return HeaterStatus(
    layout: 'Hcalory MVP2',
    on: live,
    step: step,
    error: status == 0xF ? f[22] : 0,
    mode: mode,
    level: live && mode != HeaterMode.temperature ? f[22] : null,
    target: live && mode == HeaterMode.temperature ? f[22] : null,
    voltage: (f[24] << 8 | f[25]) / 10,
    caseTemp: ((f[27] << 8 | f[28]) ~/ 10).toDouble(),
    cabinTemp: ((f[30] << 8 | f[31]) ~/ 10).toDouble(),
    fahrenheit: fahrenheit,
    errors: hcaloryErrors,
    minTarget: fahrenheit ? 32 : hcaloryMinTemp,
    maxTarget: fahrenheit ? 104 : hcaloryMaxTemp,
  );
}

/// Joins notifications into whole frames by the length byte, for links
/// whose MTU splits the 43-byte status.
class HcaloryFramer {
  final _buf = <int>[];

  List<Uint8List> add(List<int> chunk) {
    final starts =
        chunk.length >= 7 &&
        chunk[0] == 0 &&
        chunk[1] <= 3 &&
        chunk[2] == 0 &&
        chunk[3] == 1;
    if (starts) _buf.clear();
    if (_buf.isEmpty && !starts) return const [];
    _buf.addAll(chunk);
    if (_buf.length < 12) return const [];
    final total = 13 + _buf[11];
    if (_buf.length < total) return const [];
    final f = Uint8List.fromList(_buf.sublist(0, total));
    _buf.clear();
    return [f];
  }
}
