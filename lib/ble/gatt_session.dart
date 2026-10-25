// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// The small slice of GATT a driver needs, with no platform types in it so
// drivers can be driven from unit tests with a fake session.

import 'dart:typed_data';

/// A characteristic, identified by its 128-bit UUID in lowercase dashed
/// form. 16-bit UUIDs are expanded onto the Bluetooth base UUID so
/// `0xFFF1` and `0000fff1-0000-1000-8000-00805f9b34fb` are the same thing.
class GattChar {
  final String uuid;
  final bool canRead;
  final bool canWrite;
  final bool canWriteWithoutResponse;
  final bool canNotify;

  /// UUID of the service it belongs to, when known. A few devices repeat a
  /// characteristic UUID in two services.
  final String? service;

  const GattChar(
    this.uuid, {
    this.service,
    this.canRead = false,
    this.canWrite = false,
    this.canWriteWithoutResponse = false,
    this.canNotify = false,
  });

  @override
  String toString() => uuid;
}

/// Expands a 16-bit UUID to the canonical 128-bit string.
String uuid16(int short) =>
    '0000${short.toRadixString(16).padLeft(4, '0')}-0000-1000-8000-00805f9b34fb';

/// Lowercases and expands a UUID string so lookups do not depend on how a
/// platform happens to print them.
String normalizeUuid(String u) {
  final s = u.trim().toLowerCase();
  if (s.length == 4) return uuid16(int.parse(s, radix: 16));
  if (s.length == 8) {
    return '$s-0000-1000-8000-00805f9b34fb';
  }
  return s;
}

/// An open connection to one peripheral. Services have already been
/// discovered when a driver gets one of these; it goes away when the
/// driver returns.
abstract interface class GattSession {
  /// All characteristics on the device, in discovery order.
  List<GattChar> get characteristics;

  Future<Uint8List> read(GattChar c);

  Future<void> write(GattChar c, Uint8List data, {bool withResponse = true});

  /// Turns notifications on for [c] and returns a broadcast stream of its
  /// values. Calling it twice for the same characteristic is fine.
  Future<Stream<Uint8List>> subscribe(GattChar c);
}

/// A session the connection manager can also close.
abstract interface class ClosableSession implements GattSession {
  Future<void> close();

  /// True once the device or the radio ended the link by itself, rather
  /// than through [close].
  bool get droppedByDevice;

  /// Completes when the link drops by itself; never completes otherwise.
  Future<void> get onDisconnected;
}

extension GattSessionLookup on GattSession {
  /// Finds a characteristic by UUID (any accepted form), or null.
  GattChar? find(String uuid) {
    final want = normalizeUuid(uuid);
    for (final c in characteristics) {
      if (c.uuid == want) return c;
    }
    return null;
  }

  /// Like [find], but throws [UnsupportedDeviceException] when missing.
  GattChar require(String uuid, String what) =>
      find(uuid) ??
      (throw UnsupportedDeviceException('No $what characteristic ($uuid)'));
}

/// Thrown when a device does not expose what a driver needs, so the
/// manager knows not to keep retrying with the same driver.
class UnsupportedDeviceException implements Exception {
  final String message;
  const UnsupportedDeviceException(this.message);
  @override
  String toString() => message;
}
