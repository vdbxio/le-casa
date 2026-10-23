// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
// See LICENSE and LICENSE-EXCEPTION.

import 'dart:typed_data';

/// One BLE advertisement as heard by the radio, stripped of any platform
/// types so the decoders stay pure Dart and unit-testable.
class RawAdvertisement {
  /// Stable id for the sender. On Android this is the MAC address in
  /// `AA:BB:CC:DD:EE:FF` form; on iOS it is the random UUID CoreBluetooth
  /// assigns, because iOS hides MAC addresses from apps.
  final String id;

  /// The MAC address if the platform exposes it (Android), else null.
  final Uint8List? mac;

  final String? name;
  final int rssi;
  final DateTime seenAt;

  /// Service data keyed by the 16-bit UUID (e.g. 0xFCD2 for BTHome).
  /// 128-bit service UUIDs are keyed by their 32-bit "short" prefix when
  /// they use the Bluetooth base UUID, otherwise they are dropped here.
  final Map<int, Uint8List> serviceData;

  /// Manufacturer specific data keyed by company id (e.g. 0x02E1 Victron).
  final Map<int, Uint8List> manufacturerData;

  /// 16-bit service UUIDs listed in the advertisement.
  final List<int> serviceUuids;

  /// 128-bit (vendor) service UUIDs, lowercase with dashes, e.g. Improv's
  /// `00467768-6228-2272-4663-277478268000`.
  final List<String> longServiceUuids;

  const RawAdvertisement({
    required this.id,
    required this.rssi,
    required this.seenAt,
    this.mac,
    this.name,
    this.serviceData = const {},
    this.manufacturerData = const {},
    this.serviceUuids = const [],
    this.longServiceUuids = const [],
  });

  /// MAC as `AA:BB:CC:DD:EE:FF`, or null when unknown.
  String? get macString => mac
      ?.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// Parses `AA:BB:CC:DD:EE:FF` (or without colons) into 6 bytes.
Uint8List? parseMac(String? text) {
  if (text == null) return null;
  final hex = text.replaceAll(':', '').replaceAll('-', '');
  if (hex.length != 12) return null;
  try {
    return Uint8List.fromList([
      for (var i = 0; i < 12; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  } on FormatException {
    return null;
  }
}

String hex(List<int> bytes, {String sep = ' '}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(sep);

Uint8List fromHex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  return Uint8List.fromList([
    for (var i = 0; i + 1 < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}
