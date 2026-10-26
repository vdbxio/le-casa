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

  /// The latest reading taken over a GATT connection, for devices that do
  /// not broadcast their values (Daly BMS, stock Xiaomi). Survives new
  /// advertisements; [view] prefers it over [decoded] until the broadcasts
  /// can be read.
  Decoded? polled;
  DateTime? polledAt;

  /// The screen that took [polled], when it was not this one: another
  /// tablet or phone in the home that holds the connection and shares
  /// what it reads.
  String? polledBy;

  /// True for a device this screen only knows from another screen.
  bool remoteOnly = false;

  /// The name the person gave it, shared by every screen in the home.
  String? label;
  final DateTime firstSeen;
  int packets = 1;
  String? lastPacketId;
  final List<LoggedEvent> events = [];
  final List<RawAdvertisement> recent = [];

  TrackedDevice(this.latest) : id = latest.id, firstSeen = latest.seenAt;

  /// What to show: the broadcast readings once they can be read (a stock
  /// Xiaomi after its bindkey is entered, when nothing connects to it any
  /// more), else the connected reading, else whatever the broadcast
  /// decoder made of the device.
  Decoded? get view =>
      (decoded?.isReadable ?? false) ? decoded : polled ?? decoded;

  /// Whether readings come from the device's broadcasts rather than a
  /// connection.
  bool get readsBroadcasts => polled != null && (decoded?.isReadable ?? false);

  /// The device's MAC: from the radio (Android), or from inside its
  /// broadcast when it carries one (iOS hides MACs; stock Xiaomi and pvvx
  /// send theirs).
  String? get mac =>
      latest.macString ??
      decoded?.info['mac'] ??
      polled?.info['mac'] ??
      learnedMac;

  /// The MAC another screen (Android) knows this device by, once a reading
  /// from it matched this device. Lets iOS name and match it the same way.
  String? learnedMac;

  String get title => view?.model ?? latest.name ?? 'Unknown device';

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

  /// The name the person gave a device, from whoever keeps the names.
  String? Function(String id) labelFor = (_) => null;

  /// The name a device advertised before, as this screen or another one
  /// saved it (with its key, PIN or Read by choice). For a device whose
  /// adverts carry no name until a scan response comes, or never while it
  /// is held open, so its automatic name does not change.
  String? Function(String id) nameFor = (_) => null;

  DeviceTracker(this.registry);

  /// Picks up renamed devices after [labelFor] changed, and names learnt
  /// through [nameFor].
  void relabel() {
    var changed = false;
    for (final d in _devices.values) {
      if (d.latest.name == null) {
        final n = nameFor(d.id);
        if (n != null) {
          d.latest = d.latest.withName(n);
          changed = true;
        }
      }
      final l = labelFor(d.id);
      if (l == d.label) continue;
      d.label = l;
      changed = true;
    }
    if (changed) notifyListeners();
  }

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
          if (d.view?.kind == k) d,
      ];
      if (list.isNotEmpty) out[k] = list;
    }
    return out;
  }

  /// Devices no decoder recognised, in first-heard order.
  List<TrackedDevice> get unknown => [
    for (final d in _devices.values)
      if (d.view == null) d,
  ];

  /// Stores a reading taken over a connection.
  void setPolled(String id, Decoded decoded) {
    final d = _devices[id];
    if (d == null) return;
    d.polled = decoded;
    d.polledAt = DateTime.now();
    d.polledBy = null;
    notifyListeners();
  }

  /// Stores a reading another screen took over its connection. Creates the
  /// device when this screen has never heard it (out of range, or iOS and
  /// Android know it under different ids). Ignored when this screen has a
  /// newer reading of its own.
  void setRemote(
    String id, {
    required Decoded decoded,
    required DateTime at,
    required String by,
    String? name,
    Uint8List? mac,
  }) {
    var d = _devices[id];
    if (d == null) {
      d =
          TrackedDevice(
              RawAdvertisement(
                id: id,
                rssi: 0,
                seenAt: at,
                name: name,
                mac: mac,
              ),
            )
            ..remoteOnly = true
            ..label = labelFor(id);
      _devices[id] = d;
    } else if (d.polledAt != null && !at.isAfter(d.polledAt!)) {
      return;
    }
    if (d.remoteOnly) d.latest = d.latest.withSeenAt(at);
    d.polled = decoded;
    d.polledAt = at;
    d.polledBy = by;
    notifyListeners();
  }

  /// Remembers the MAC another screen knows [id] by, when this screen does
  /// not know one itself.
  void learnMac(String id, String mac) {
    final d = _devices[id];
    if (d == null || d.mac != null) return;
    d.learnedMac = mac;
    notifyListeners();
  }

  /// Forgets a device that only another screen told us about, once it
  /// turns out to be one this screen hears under its own id.
  void removeRemote(String id) {
    if (_devices[id]?.remoteOnly ?? false) {
      _devices.remove(id);
      notifyListeners();
    }
  }

  TrackedDevice? operator [](String id) => _devices[id];

  void onAdvertisement(RawAdvertisement raw) {
    totalPackets++;
    var d = _devices[raw.id];
    // Keep the last known name: many devices only send it in every other
    // packet, and a name that flickers makes the list unreadable.
    // A device heard for the first time since the app started may send
    // its name later, or not at all while it is held open.
    final name = raw.name ?? (d == null ? nameFor(raw.id) : d.latest.name);
    final adv = name == raw.name ? raw : raw.withName(name);
    final decoded = registry.decode(adv);
    if (d == null) {
      _devices[adv.id] = TrackedDevice(adv)
        ..label = labelFor(adv.id)
        ..decoded = decoded
        ..lastRecognised = decoded == null ? null : adv
        ..recent.add(adv)
        .._logEvents(decoded);
    } else {
      d.latest = adv;
      d.remoteOnly = false;
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
