// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// The data model shared by every battery management system driver. It
// mirrors aiobmsble's BMSSample dictionary on purpose: drivers are ported
// line by line, so keeping the same keys keeps the ports reviewable against
// upstream. Le'Casa's own Reading/Decoded model is built from it at the
// edge (bms_driver.dart).

/// Where a temperature reading comes from.
enum TempType {
  generic,
  cell,
  cellMax,
  cellMin,
  mosfet,
  pcb,
  heater,
  balancer,
  ambient,
}

class TempSensor {
  final double value;
  final TempType type;

  const TempSensor(num value, [this.type = TempType.generic])
    : value = value + 0.0;

  @override
  bool operator ==(Object other) =>
      other is TempSensor && other.value == value && other.type == type;

  @override
  int get hashCode => Object.hash(value, type);

  @override
  String toString() => 'TempSensor($value, ${type.name})';
}

/// Charging mode some BMSs report.
enum BmsMode {
  unknown(-1),
  bulk(0),
  absorption(1),
  float(2);

  final int code;
  const BmsMode(this.code);
}

/// One sample, keyed like aiobmsble: `voltage` (V), `current` (A, positive
/// is charging), `battery_level` (%), `cycle_charge` (Ah), `cell_voltages`
/// (List<double>, V), `temp_values` (List<TempSensor>), `problem_code`
/// (int), `packs` (List<BmsSample>) and so on. See [BmsKeys].
typedef BmsSample = Map<String, Object?>;

/// Static and fetched information about a BMS: manufacturer, model,
/// sw_version, hw_version, serial_number, ...
typedef BmsInfo = Map<String, String>;

abstract final class BmsKeys {
  static const batteryHealth = 'battery_health';
  static const batteryLevel = 'battery_level';
  static const cellCount = 'cell_count';
  static const cellVoltages = 'cell_voltages';
  static const current = 'current';
  static const cycleCapacity = 'cycle_capacity';
  static const cycleCharge = 'cycle_charge';
  static const cycles = 'cycles';
  static const deltaVoltage = 'delta_voltage';
  static const designCapacity = 'design_capacity';
  static const tempSensors = 'temp_sensors';
  static const tempValues = 'temp_values';
  static const voltage = 'voltage';
  static const batteryCharging = 'battery_charging';
  static const batteryMode = 'battery_mode';
  static const power = 'power';
  static const temperature = 'temperature';
  static const totalCharge = 'total_charge';
  static const problem = 'problem';
  static const runtime = 'runtime';
  static const balancer = 'balancer';
  static const balanceCurrent = 'balance_current';
  static const heaterCurrent = 'heater_current';
  static const packCount = 'pack_count';
  static const problemCode = 'problem_code';
  static const chrgMosfet = 'chrg_mosfet';
  static const dischrgMosfet = 'dischrg_mosfet';
  static const heater = 'heater';
  static const packs = 'packs';
}

/// A field in a frame: where it sits, how wide it is, and how to turn the
/// raw integer into a value. [idx] picks one message out of a map of
/// messages when a driver collects several.
class BmsDp {
  final String key;
  final int pos;
  final int size;
  final bool signed;
  final Object? Function(int) fct;
  final int idx;

  /// Converts the raw bytes (message order) instead of an int; for fields
  /// wider than 64 bits.
  final Object? Function(List<int>)? fctBytes;

  const BmsDp(
    this.key,
    this.pos,
    this.size,
    this.signed, [
    this.fct = _identity,
    this.idx = -1,
  ]) : fctBytes = null;

  const BmsDp.bytes(this.key, this.pos, this.size, this.fctBytes, [this.idx = -1])
    : signed = false,
      fct = _identity;
}

Object? _identity(int x) => x;

/// Advertisement patterns that identify a BMS, as in Home Assistant's
/// bluetooth matchers. Every field that is set must match.
class MatcherPattern {
  /// Shell-style wildcards: `*`, `?`, `[...]`.
  final String? localName;
  final List<int>? manufacturerDataStart;
  final int? manufacturerId;

  /// First bytes of the MAC address, `AA:BB:CC`. Never matches on iOS,
  /// which hides MAC addresses.
  final String? oui;
  final String? serviceDataUuid;

  /// 128-bit service UUID the advertisement must list.
  final String? serviceUuid;
  final bool connectable;

  const MatcherPattern({
    this.localName,
    this.manufacturerDataStart,
    this.manufacturerId,
    this.oui,
    this.serviceDataUuid,
    this.serviceUuid,
    this.connectable = true,
  });
}

class BmsConfig {
  /// Application-level secret (PIN or password) for BMSs that need one.
  final String secret;

  const BmsConfig({this.secret = ''});
}

/// Thrown when a BMS rejects the configured secret.
class BmsPermissionException implements Exception {
  final String message;
  const BmsPermissionException(this.message);
  @override
  String toString() => message;
}

/// Thrown when a frame buffer would exceed its bound (Python BufferError).
class BufferException implements Exception {
  final String message;
  const BufferException(this.message);
  @override
  String toString() => message;
}
