// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

/// A single value read from a device, in the shape the dashboard will
/// eventually render as an entity: a label, a number (or text), a unit.
class Reading {
  final String label;
  final Object? value; // num, String, bool, or null for "not available"
  final String unit;

  const Reading(this.label, this.value, [this.unit = '']);

  String get display {
    final v = value;
    if (v == null) return 'n/a';
    if (v is bool) return v ? 'on' : 'off';
    if (v is double) {
      // Trim float noise: 25.06 not 25.060000000000002
      final s = v.toStringAsFixed(3);
      final trimmed = s.contains('.')
          ? s.replaceFirst(RegExp(r'\.?0+$'), '')
          : s;
      return unit.isEmpty ? trimmed : '$trimmed $unit';
    }
    return unit.isEmpty ? '$v' : '$v $unit';
  }

  @override
  String toString() => '$label: $display';
}

/// A momentary event, e.g. a Le'Fob button press. Not state, so it is kept
/// separately from readings and shown as a short-lived log line.
class DeviceEvent {
  final String label; // e.g. "button 2"
  final String kind; // e.g. "press", "long_press"
  const DeviceEvent(this.label, this.kind);

  @override
  String toString() => '$label $kind';
}

/// What a decoder figured out about one advertisement.
class Decoded {
  /// Short protocol tag: "BTHome", "Victron", "Xiaomi (stock)", ...
  final String protocol;

  /// Best human name for the device model/kind: "SmartSolar Charger MPPT
  /// 100/50", "Temperature/Humidity sensor", "Le'Fob", ...
  final String model;

  final List<Reading> readings;
  final List<DeviceEvent> events;

  /// Set when the decoder knows what it is but cannot read it yet, e.g.
  /// "Needs the encryption key from VictronConnect".
  final String? needs;

  /// Extra notes for the detail screen (packet counter, flags...).
  final Map<String, String> info;

  const Decoded({
    required this.protocol,
    required this.model,
    this.readings = const [],
    this.events = const [],
    this.needs,
    this.info = const {},
  });

  bool get isReadable => needs == null;
}
