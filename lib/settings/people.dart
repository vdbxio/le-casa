// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../ble/device_tracker.dart';
import '../dashboard/catalog.dart' show deviceName;
import '../dashboard/fob_log.dart';
import '../decoders/decoded.dart';
import '../ui/format.dart';

/// What can tell that someone is home: a Le'Fob (or another remote that
/// chirps) they carry, or their phone running Le'Casa in this home.
enum TrackerKind { fob, phone }

/// One thing a person carries. [name] is remembered so a tracker that is
/// out of range still shows what it is.
@immutable
class Tracker {
  final TrackerKind kind;

  /// The device id of a fob, or the screen id of a phone.
  final String id;
  final String name;

  const Tracker(this.kind, this.id, this.name);

  Map<String, Object?> toJson() => {'k': kind.name, 'id': id, 'n': name};

  static Tracker? fromJson(Map<String, Object?> j) {
    final kind = TrackerKind.values.asNameMap()[j['k']];
    if (kind == null) return null;
    return Tracker(kind, '${j['id']}', '${j['n'] ?? ''}');
  }

  @override
  bool operator ==(Object other) =>
      other is Tracker && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

class Person {
  final String id;
  String name;
  final List<Tracker> trackers;

  Person(this.id, this.name, [List<Tracker>? trackers])
    : trackers = trackers ?? [];

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    't': [for (final t in trackers) t.toJson()],
  };

  static Person fromJson(Map<String, Object?> j) =>
      Person('${j['id']}', '${j['name'] ?? 'Someone'}', [
        for (final t in (j['t'] as List? ?? const []))
          ?Tracker.fromJson((t as Map).cast()),
      ]);
}

/// The people of this home and what each one carries. Kept on this
/// screen for now.
class PeopleStore extends ChangeNotifier {
  static const prefsKey = 'people:v1';
  final List<Person> people = [];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(prefsKey);
      if (raw != null) {
        people
          ..clear()
          ..addAll([
            for (final j in jsonDecode(raw) as List)
              Person.fromJson((j as Map).cast()),
          ]);
      }
    } catch (e) {
      debugPrint('People could not be read: $e');
    }
    notifyListeners();
  }

  Person? byId(String id) => people.where((p) => p.id == id).firstOrNull;

  Person add(String name) {
    final r = math.Random();
    final id = List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
    final p = Person(id, name.trim().isEmpty ? 'Someone' : name.trim());
    people.add(p);
    _changed();
    return p;
  }

  void rename(Person p, String name) {
    if (name.trim().isEmpty) return;
    p.name = name.trim();
    _changed();
  }

  void remove(Person p) {
    people.remove(p);
    _changed();
  }

  /// Gives [t] to [p], or takes it away. A tracker belongs to one person:
  /// giving it to someone takes it from whoever had it.
  void assign(Person p, Tracker t, bool on) {
    for (final other in people) {
      other.trackers.remove(t);
    }
    if (on) p.trackers.add(t);
    _changed();
  }

  /// Who carries [t], if anyone.
  Person? ownerOf(Tracker t) =>
      people.where((p) => p.trackers.contains(t)).firstOrNull;

  void _changed() {
    notifyListeners();
    SharedPreferences.getInstance().then(
      (p) => p.setString(
        prefsKey,
        jsonEncode([for (final x in people) x.toJson()]),
      ),
    );
  }
}

/// Where a tracker is: home true, away false, null when it cannot tell.
typedef TrackerState = ({bool? home, String detail});

/// Remotes that can say whether they are home: Le'Fobs, and other button
/// remotes heard nearby.
List<TrackedDevice> fobCandidates(AppServices s) => [
  for (final d in s.tracker.devices)
    if (d.view case final v?
        when v.kind == DeviceKind.buttons || v.model == "Le'Fob")
      d,
];

/// Phones in this home, this one included when it is a phone.
List<Tracker> phoneCandidates(AppServices s) {
  if (!s.home.inHome) {
    return [
      if (s.home.phone)
        Tracker(TrackerKind.phone, s.home.me.id, s.home.me.name),
    ];
  }
  return [
    for (final m in s.sync.screens)
      if (m == s.home.me ? s.home.phone : s.sync.peer(m.id)?.phone ?? false)
        Tracker(TrackerKind.phone, m.id, m.name),
  ];
}

TrackerState trackerState(Tracker t, AppServices s, [DateTime? now]) {
  final at = now ?? DateTime.now();
  switch (t.kind) {
    case TrackerKind.fob:
      final logged = s.history.fob(t.id, at);
      if (logged == null) {
        final d = s.tracker.find(t.id);
        return (
          home: null,
          detail: d == null ? 'Not heard yet' : 'Heard ${ago(d.lastSeen, at)}',
        );
      }
      final p = presenceOf(logged.$1.bursts, logged.$2, at);
      final heard = p.lastHeard;
      return (
        home: p.home,
        detail: switch (p.home) {
          true => heard == null ? 'Home' : 'Home · heard ${ago(heard, at)}',
          false =>
            p.since == null ? 'Away' : 'Away · left ${ago(p.since!, at)}',
          null => 'Checking…',
        },
      );
    case TrackerKind.phone:
      if (t.id == s.home.me.id) return (home: true, detail: 'This phone');
      final here = s.sync.screens.any((m) => m.id == t.id);
      if (here) return (home: true, detail: 'In touch with this home');
      final p = s.sync.peer(t.id);
      return (
        home: s.home.inHome ? false : null,
        detail: p == null
            ? 'Not heard lately'
            : 'Last heard ${ago(p.heard, at)}',
      );
  }
}

/// Whether [p] is home: any tracker home says yes; otherwise any away says
/// no; null when nothing can tell.
bool? personHome(Person p, AppServices s, [DateTime? now]) {
  var away = false;
  for (final t in p.trackers) {
    final st = trackerState(t, s, now);
    if (st.home == true) return true;
    if (st.home == false) away = true;
  }
  return away ? false : null;
}

/// The name to remember for a fob.
String fobName(TrackedDevice d) => deviceName(d);
