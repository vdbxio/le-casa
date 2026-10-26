// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// JSON shapes for what screens share: readings, and which device they
// belong to.

import '../decoders/decoded.dart';

Map<String, Object?> decodedToJson(Decoded d) => {
  'p': d.protocol,
  'k': d.kind.name,
  'm': d.model,
  'r': [
    for (final r in d.readings) [r.label, r.value, r.unit],
  ],
  'n': ?d.needs,
  if (d.info.isNotEmpty) 'i': d.info,
};

Decoded decodedFromJson(Map<String, Object?> j) => Decoded(
  protocol: '${j['p']}',
  kind: DeviceKind.values.asNameMap()['${j['k']}'] ?? DeviceKind.sensor,
  model: '${j['m']}',
  readings: [
    for (final r in (j['r'] as List? ?? const []))
      if (r is List && r.length == 3)
        Reading('${r[0]}', _value(r[1]), '${r[2]}'),
  ],
  needs: j['n'] as String?,
  info: {
    for (final e in ((j['i'] as Map?) ?? const {}).entries)
      '${e.key}': '${e.value}',
  },
);

Object? _value(Object? v) => switch (v) {
  num() || String() || bool() || null => v,
  _ => '$v',
};

/// One device reading another screen took, as it travels.
class SharedReading {
  /// The device's id on the screen that read it.
  final String id;
  final String? name;

  /// `AA:BB:CC:DD:EE:FF` when the owner knows it (Android).
  final String? mac;

  /// The screen that holds the connection.
  final String ownerId;
  final String ownerName;

  /// When it was read, on this screen's clock.
  final DateTime at;

  /// How often the owner reads it, so others can tell when it went quiet.
  final Duration every;

  /// Whether the owner can change settings on it.
  final bool controllable;
  final Decoded decoded;

  const SharedReading({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.at,
    required this.decoded,
    this.name,
    this.mac,
    this.every = const Duration(minutes: 1),
    this.controllable = false,
  });

  String get slot => '$ownerId|$id';

  /// Still the owner's: a few missed reads are fine, then others take over.
  bool freshAt(DateTime now) =>
      now.difference(at) < every * 3 + const Duration(seconds: 30);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': ?name,
    'mac': ?mac,
    'o': ownerId,
    'on': ownerName,
    // An age, not a time: screen clocks drift apart in a van with no
    // internet, so each side counts from its own clock.
    'age': DateTime.now().difference(at).inMilliseconds,
    'every': every.inSeconds,
    if (controllable) 'ctl': true,
    'd': decodedToJson(decoded),
  };

  static SharedReading fromJson(Map<String, Object?> j) => SharedReading(
    id: '${j['id']}',
    name: j['name'] as String?,
    mac: j['mac'] as String?,
    ownerId: '${j['o']}',
    ownerName: '${j['on'] ?? 'Another screen'}',
    at: DateTime.now().subtract(
      Duration(
        milliseconds: ((j['age'] as num?)?.toInt() ?? 0).clamp(0, 1 << 40),
      ),
    ),
    every: Duration(seconds: (j['every'] as num?)?.toInt() ?? 60),
    controllable: j['ctl'] == true,
    decoded: decodedFromJson((j['d'] as Map).cast()),
  );
}
