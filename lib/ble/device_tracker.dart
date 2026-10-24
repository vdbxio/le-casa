// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/foundation.dart';

import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import '../decoders/registry.dart';

class LoggedEvent {
  final DateTime at;
  final DeviceEvent event;
  LoggedEvent(this.at, this.event);
}

/// Everything we know about one broadcaster.
class TrackedDevice {
  final String id;
  RawAdvertisement latest;

  /// The newest packet a decoder recognised. Devices interleave data
  /// packets with name-only or housekeeping ones, so re-decoding after a
  /// key change must use this, not [latest].
  RawAdvertisement? lastRecognised;
  Decoded? decoded;
  final DateTime firstSeen;
  int packets = 1;
  String? lastPacketId;
  final List<LoggedEvent> events = [];
  final List<RawAdvertisement> recent = [];

  TrackedDevice(this.latest) : id = latest.id, firstSeen = latest.seenAt;

  String get title => decoded?.model ?? latest.name ?? 'Unknown device';

  DateTime get lastSeen => latest.seenAt;

  /// Packets per minute over the last minute.
  double get rate {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    final n = recent.where((a) => a.seenAt.isAfter(cutoff)).length;
    final span = DateTime.now().difference(firstSeen);
    final mins = span.inMilliseconds / 60000.0;
    return mins < 1 ? (mins <= 0 ? 0 : n / mins) : n.toDouble();
  }
}

/// Keeps the device list up to date from the advertisement stream and runs
/// the decoders. Re-decodes everything when keys change.
class DeviceTracker extends ChangeNotifier {
  DecoderRegistry registry;
  final Map<String, TrackedDevice> _devices = {};
  int totalPackets = 0;

  DeviceTracker(this.registry);

  /// All devices in the order they were first heard. Insertion order of the
  /// map, so a device never moves once it is on screen.
  List<TrackedDevice> get devices => _devices.values.toList();

  /// Recognised devices grouped by kind, groups in [DeviceKind] order and
  /// devices in first-heard order.
  Map<DeviceKind, List<TrackedDevice>> get groups {
    final out = <DeviceKind, List<TrackedDevice>>{};
    for (final k in DeviceKind.values) {
      final list = [
        for (final d in _devices.values)
          if (d.decoded?.kind == k) d,
      ];
      if (list.isNotEmpty) out[k] = list;
    }
    return out;
  }

  /// Devices no decoder recognised, in first-heard order.
  List<TrackedDevice> get unknown => [
    for (final d in _devices.values)
      if (d.decoded == null) d,
  ];

  TrackedDevice? operator [](String id) => _devices[id];

  void onAdvertisement(RawAdvertisement raw) {
    totalPackets++;
    var d = _devices[raw.id];
    // Keep the last known name: many devices only send it in every other
    // packet, and a name that flickers makes the list unreadable.
    final adv = (raw.name == null && d?.latest.name != null)
        ? raw.withName(d!.latest.name)
        : raw;
    final decoded = registry.decode(adv);
    if (d == null) {
      _devices[adv.id] = TrackedDevice(adv)
        ..decoded = decoded
        ..lastRecognised = decoded == null ? null : adv
        ..recent.add(adv)
        .._logEvents(decoded);
    } else {
      d.latest = adv;
      d.packets++;
      if (decoded != null) {
        d.decoded = decoded;
        d.lastRecognised = adv;
      }
      d.recent.add(adv);
      if (d.recent.length > 120) d.recent.removeAt(0);
      d._logEvents(decoded);
    }
    notifyListeners();
  }

  void redecodeAll() {
    for (final d in _devices.values) {
      d.decoded = registry.decode(d.lastRecognised ?? d.latest) ?? d.decoded;
    }
    notifyListeners();
  }

  void clear() {
    _devices.clear();
    totalPackets = 0;
    notifyListeners();
  }
}

extension on TrackedDevice {
  void _logEvents(Decoded? decoded) {
    if (decoded == null || decoded.events.isEmpty) return;
    // Trigger-based devices repeat the same packet several times; only log
    // when the packet id changes (or there is none).
    final pid = decoded.info['packet id'];
    if (pid != null && pid == lastPacketId) return;
    lastPacketId = pid;
    for (final e in decoded.events) {
      events.insert(0, LoggedEvent(latest.seenAt, e));
    }
    if (events.length > 50) events.removeRange(50, events.length);
  }
}
