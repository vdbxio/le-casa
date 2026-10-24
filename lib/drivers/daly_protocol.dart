// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Daly smart BMS Bluetooth protocol: pure parsing, no radio. The modules
// speak a Modbus-RTU-like dialect over two GATT characteristics (write
// 0xFFF2, notify 0xFFF1). Two generations exist:
//
//  * "D2": request `D2 03 <reg hi> <reg lo> <count hi> <count lo> <crc>`,
//    response `D2 03 <len> <len bytes> <crc>`. Status is registers
//    0x0000..0x003D (62 registers, 124 bytes); newer firmware also answers
//    80 registers with balancing and MOS temperature appended.
//  * "0x81": request starts with 0x81, response with 0x51. Cells and
//    summary live at 0x0000 (64 registers), the rest at 0x0041 (62).
//
// Register values are big-endian uint16; the CRC is Modbus CRC-16, little-
// endian. Layouts follow the community documentation in
// https://github.com/syssi/esphome-daly-bms (daly_bms_ble) and
// https://github.com/patman15/aiobmsble (both independently reverse
// engineered, both agree).

import 'dart:typed_data';

import '../decoders/decoded.dart';

/// Modbus CRC-16 (poly 0xA001 reflected, init 0xFFFF).
int crc16Modbus(List<int> data, [int length = -1]) {
  final n = length < 0 ? data.length : length;
  var crc = 0xFFFF;
  for (var i = 0; i < n; i++) {
    crc ^= data[i];
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc;
}

enum DalyProtocol {
  /// Request 0xD2, response 0xD2.
  d2(0xD2, 0xD2),

  /// Request 0x81, response 0x51.
  p81(0x81, 0x51);

  final int request;
  final int response;
  const DalyProtocol(this.request, this.response);
}

/// Builds a read-holding-registers request.
Uint8List dalyReadRequest(DalyProtocol p, int register, int count) {
  final f = Uint8List(8);
  f[0] = p.request;
  f[1] = 0x03;
  f[2] = register >> 8;
  f[3] = register & 0xFF;
  f[4] = count >> 8;
  f[5] = count & 0xFF;
  final crc = crc16Modbus(f, 6);
  f[6] = crc & 0xFF;
  f[7] = crc >> 8;
  return f;
}

/// Reassembles one response frame out of the 20..244-byte notification
/// chunks BLE delivers it in. Feed every notification to [add]; it returns
/// the complete, CRC-checked frame when one is ready, else null. Garbage
/// (bad CRC, wrong start byte) is dropped and reassembly restarts.
class DalyFrameAssembler {
  final DalyProtocol protocol;
  final _buf = <int>[];

  DalyFrameAssembler(this.protocol);

  Uint8List? add(List<int> chunk) {
    if (_buf.isEmpty) {
      // Skip to a plausible frame start.
      final start = chunk.indexOf(protocol.response);
      if (start < 0) return null;
      _buf.addAll(chunk.sublist(start));
    } else {
      _buf.addAll(chunk);
    }
    if (_buf.length < 3) return null;
    if (_buf[1] != 0x03 && _buf[1] != 0x06) {
      _buf.clear();
      return null;
    }
    final total = 3 + _buf[2] + 2;
    if (_buf.length < total) return null;
    final frame = Uint8List.fromList(_buf.sublist(0, total));
    _buf.clear();
    final want = frame[total - 2] | (frame[total - 1] << 8);
    if (crc16Modbus(frame, total - 2) != want) return null;
    return frame;
  }

  void reset() => _buf.clear();
}

/// Alarm bit meanings for the 64-bit mask in D2 status registers
/// 0x3A..0x3D, bit 0 = least significant bit of register 0x3D.
const List<String> dalyAlarmNames = [
  // Register 0x3D (reserved)
  '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
  // Register 0x3C low byte
  'Charging MOS over-temperature warning',
  'Discharging MOS over-temperature warning',
  'Charging MOS temperature sensor failure',
  'Discharging MOS temperature sensor failure',
  'Charging MOS adhesion failure',
  'Discharging MOS adhesion failure',
  'Charging MOS circuit fault',
  'Discharging MOS circuit fault',
  // Register 0x3C high byte
  'AFE acquisition chip failure',
  'Single unit collection is offline',
  'Single temperature sensor failure',
  'EEPROM storage failure',
  'RTC clock failure',
  'Precharge failed',
  'Vehicle communication failed',
  'Internal network communication module failure',
  // Register 0x3B low byte
  'Warning: charging current too high',
  'Critical: charging current too high',
  'Warning: discharging current too high',
  'Critical: discharging current too high',
  'Warning: SOC too high',
  'Critical: SOC too high',
  'Warning: SOC too low',
  'Critical: SOC too low',
  // Register 0x3B high byte
  'Warning: voltage difference too high',
  'Critical: voltage difference too high',
  'Warning: temperature difference too high',
  'Critical: temperature difference too high',
  '', '', '', '',
  // Register 0x3A low byte
  'Warning: cell voltage too high',
  'Critical: cell voltage too high',
  'Warning: cell voltage too low',
  'Critical: cell voltage too low',
  'Warning: total voltage too high',
  'Critical: total voltage too high',
  'Warning: total voltage too low',
  'Critical: total voltage too low',
  // Register 0x3A high byte
  'Warning: charging temperature too high',
  'Critical: charging temperature too high',
  'Warning: charging temperature too low',
  'Critical: charging temperature too low',
  'Warning: discharging temperature too high',
  'Critical: discharging temperature too high',
  'Warning: discharging temperature too low',
  'Critical: discharging temperature too low',
];

/// Everything one status poll tells us about the battery.
class DalyStatus {
  final DalyProtocol protocol;
  final double voltage; // V
  final double current; // A, positive = charging
  final double soc; // %
  final List<double> cellVoltages; // V
  final List<double> temperatures; // °C
  final double? remainingAh;
  final int? cycles;
  final int? chargeState; // 0 idle, 1 charging, 2 discharging
  final bool? balancing;
  final bool? chargeMos;
  final bool? dischargeMos;
  final double? mosTemperature; // °C
  final BigInt alarmBits;

  DalyStatus({
    required this.protocol,
    required this.voltage,
    required this.current,
    required this.soc,
    required this.cellVoltages,
    required this.temperatures,
    this.remainingAh,
    this.cycles,
    this.chargeState,
    this.balancing,
    this.chargeMos,
    this.dischargeMos,
    this.mosTemperature,
    BigInt? alarmBits,
  }) : alarmBits = alarmBits ?? BigInt.zero;

  double get power => voltage * current;

  double? get minCell => cellVoltages.isEmpty
      ? null
      : cellVoltages.reduce((a, b) => a < b ? a : b);
  double? get maxCell => cellVoltages.isEmpty
      ? null
      : cellVoltages.reduce((a, b) => a > b ? a : b);

  /// Cell spread in mV, or null without cells.
  int? get deltaMv {
    final lo = minCell, hi = maxCell;
    if (lo == null || hi == null) return null;
    return ((hi - lo) * 1000).round();
  }

  /// Human alarm names. Only the D2 bit layout is documented; for 0x81
  /// modules a non-zero mask is reported as a raw code.
  List<String> get alarms {
    if (alarmBits == BigInt.zero) return const [];
    if (protocol != DalyProtocol.d2) {
      return ['code 0x${alarmBits.toRadixString(16)}'];
    }
    return [
      for (var i = 0; i < dalyAlarmNames.length; i++)
        if ((alarmBits >> i).isOdd && dalyAlarmNames[i].isNotEmpty)
          dalyAlarmNames[i],
    ];
  }

  String get chargeStateText => switch (chargeState) {
    0 => 'idle',
    1 => 'charging',
    2 => 'discharging',
    _ =>
      current > 0.05
          ? 'charging'
          : current < -0.05
          ? 'discharging'
          : 'idle',
  };

  Decoded toDecoded(String moduleName) {
    final readings = <Reading>[
      Reading('state of charge', soc, '%'),
      Reading('voltage', voltage, 'V'),
      Reading('current', current, 'A'),
      Reading('power', double.parse(power.toStringAsFixed(1)), 'W'),
      Reading('state', chargeStateText),
      if (remainingAh != null) Reading('remaining', remainingAh, 'Ah'),
      for (var i = 0; i < temperatures.length; i++)
        Reading(
          temperatures.length == 1 ? 'temperature' : 'temperature ${i + 1}',
          temperatures[i],
          '°C',
        ),
      if (mosTemperature != null)
        Reading('MOSFET temperature', mosTemperature, '°C'),
      for (var i = 0; i < cellVoltages.length; i++)
        Reading('cell ${i + 1}', cellVoltages[i], 'V'),
      if (deltaMv != null) Reading('cell spread', deltaMv, 'mV'),
      if (cycles != null) Reading('cycles', cycles),
      if (chargeMos != null) Reading('charge MOSFET', chargeMos),
      if (dischargeMos != null) Reading('discharge MOSFET', dischargeMos),
      if (balancing != null) Reading('balancing', balancing),
      if (alarms.isNotEmpty) Reading('alarm', alarms.join('; ')),
    ];
    return Decoded(
      protocol: 'Daly BMS',
      kind: DeviceKind.battery,
      model: 'Daly smart BMS (${cellVoltages.length}S)',
      readings: readings,
      info: {
        'module': moduleName,
        'protocol': protocol == DalyProtocol.d2 ? 'D2' : '0x81',
        'source': 'connection',
      },
    );
  }
}

int _u16(Uint8List d, int i) => (d[i] << 8) | d[i + 1];

/// Parses a D2 status response (62 or 80 registers). Returns null when the
/// frame is not a status frame of a known size.
DalyStatus? parseDalyD2Status(Uint8List f) {
  if (f.length != 62 * 2 + 5 && f.length != 80 * 2 + 5) return null;
  if (f[0] != 0xD2 || f[1] != 0x03) return null;
  final cells = _u16(f, 101).clamp(0, 32);
  final temps = _u16(f, 103).clamp(0, 8);
  var alarm = BigInt.zero;
  for (var i = 119; i < 127; i++) {
    alarm = (alarm << 8) | BigInt.from(f[i]);
  }
  final extended = f.length == 80 * 2 + 5;
  return DalyStatus(
    protocol: DalyProtocol.d2,
    cellVoltages: [for (var i = 0; i < cells; i++) _u16(f, 3 + i * 2) / 1000],
    temperatures: [
      for (var i = 0; i < temps; i++) (_u16(f, 67 + i * 2) - 40).toDouble(),
    ],
    voltage: _u16(f, 83) / 10,
    current: (_u16(f, 85) - 30000) / 10,
    soc: _u16(f, 87) / 10,
    chargeState: _u16(f, 97),
    remainingAh: _u16(f, 99) / 10,
    cycles: _u16(f, 105),
    balancing: _u16(f, 107) != 0,
    chargeMos: _u16(f, 109) != 0,
    dischargeMos: _u16(f, 111) != 0,
    alarmBits: alarm,
    mosTemperature: extended && _u16(f, 135) != 0 && _u16(f, 135) != 0xFFFF
        ? (_u16(f, 135) - 40).toDouble()
        : null,
  );
}

/// Parses the D2 "MOS info" response (registers 0x3E.., 9 registers) into
/// a MOSFET temperature, or null when the module reports none.
double? parseDalyD2MosTemperature(Uint8List f) {
  if (f.length < 3 + 10 + 2 || f[0] != 0xD2) return null;
  final raw = _u16(f, 3 + 8);
  if (raw == 0 || raw == 0xFFFF) return null;
  return (raw - 40).toDouble();
}

/// Parses the 0x81-protocol pair of frames: [cells] is the 64-register
/// answer to 0x0000, [status] the 62-register answer to 0x0041 (optional).
DalyStatus? parseDalyP81Status(Uint8List cells, Uint8List? status) {
  if (cells.length != 64 * 2 + 5 || cells[0] != 0x51) return null;
  int reg(int r) => _u16(cells, 3 + r * 2);
  final n = reg(0x3C).clamp(0, 48);
  final temps = reg(0x3D).clamp(0, 8);
  int? sreg(int r) {
    if (status == null || status.length != 62 * 2 + 5) return null;
    return _u16(status, 3 + (r - 0x41) * 2);
  }

  var alarm = BigInt.zero;
  final a0 = sreg(0x6D), a1 = sreg(0x6E);
  if (a0 != null && a1 != null) {
    alarm = (BigInt.from(a0) << 16) | BigInt.from(a1);
  }
  final chg = sreg(0x52), dis = sreg(0x53), bal = sreg(0x4D);
  return DalyStatus(
    protocol: DalyProtocol.p81,
    cellVoltages: [for (var i = 0; i < n; i++) reg(i) / 1000],
    temperatures: [
      for (var i = 0; i < temps; i++) (reg(0x30 + i) - 40).toDouble(),
    ],
    voltage: reg(0x38) / 10,
    current: (reg(0x39) - 30000) / 10,
    soc: reg(0x3A) / 10,
    chargeState: sreg(0x48),
    remainingAh: sreg(0x4B) == null ? null : sreg(0x4B)! / 10,
    cycles: sreg(0x4C),
    balancing: bal == null ? null : bal != 0,
    chargeMos: chg == null ? null : chg != 0,
    dischargeMos: dis == null ? null : dis != 0,
    alarmBits: alarm,
  );
}
