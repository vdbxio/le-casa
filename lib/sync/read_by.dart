// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the person chose for one device, shared by every screen in a home:
/// which screen reads it over a connection (one they locked it to, or none
/// for automatic), whether screens may connect at all, and the name they
/// gave it. The choice and the name are merged separately, newest wins, so
/// a rename on one screen and a lock on another both stick.
class ReadByRecord {
  final String id;
  final String? name;
  final String? mac;

  /// Manufacturer-data fingerprint, to find the device on other screens.
  final String? fp;

  /// Screen id, or null for automatic.
  final String? screen;
  final String? screenName;

  /// Whether screens may connect to the device: the person added it to
  /// the home (true) or turned it off (false). Null when nobody has said.
  final bool? connect;

  /// The name the person gave the device, or null for the one Le'Casa
  /// makes up. Never used to find the device on another screen.
  final String? label;

  /// When [screen] and [connect] were last chosen, in milliseconds since
  /// the epoch.
  final int choiceAt;

  /// When [label] was last set (or cleared).
  final int labelAt;

  /// The newest of the two: what screens compare to see what is news.
  final int at;

  const ReadByRecord(
    this.id, {
    this.name,
    this.mac,
    this.fp,
    this.screen,
    this.screenName,
    this.connect,
    this.label,
    int? choiceAt,
    this.labelAt = 0,
    this.at = 0,
  }) : choiceAt = choiceAt ?? at;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': ?name,
    'mac': ?mac,
    'fp': ?fp,
    's': ?screen,
    'sn': ?screenName,
    'c': ?connect,
    'l': ?label,
    'ca': choiceAt,
    'la': labelAt,
    'at': at,
  };

  static ReadByRecord fromJson(Map<String, Object?> j) => ReadByRecord(
    '${j['id']}',
    name: j['name'] as String?,
    mac: j['mac'] as String?,
    fp: j['fp'] as String?,
    screen: j['s'] as String?,
    screenName: j['sn'] as String?,
    connect: j['c'] as bool?,
    label: j['l'] as String?,
    choiceAt: (j['ca'] as num?)?.toInt(),
    labelAt: (j['la'] as num?)?.toInt() ?? 0,
    at: (j['at'] as num?)?.toInt() ?? 0,
  );
}

class ReadByStore extends ChangeNotifier {
  static const _key = 'sync:readby';
  SharedPreferences? _prefs;
  final Map<String, ReadByRecord> _records = {};

  ReadByStore();

  /// For tests: never saved.
  ReadByStore.memory();

  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();
    try {
      for (final j in jsonDecode(p.getString(_key) ?? '[]') as List) {
        final r = ReadByRecord.fromJson((j as Map).cast());
        _records[r.id] = r;
      }
    } catch (_) {}
    notifyListeners();
  }

  List<ReadByRecord> get records => _records.values.toList();

  /// The screen [id] is locked to, or null for automatic.
  ReadByRecord? lockOf(String id) {
    final r = _records[id];
    return r?.screen == null ? null : r;
  }

  /// Whether the person said screens may connect to [id], or null.
  bool? connectOf(String id) => _records[id]?.connect;

  /// The name the person gave [id], or null.
  String? labelOf(String id) => _records[id]?.label;

  /// Names [id], or clears its name with null or an empty one. Keeps its
  /// lock and connect choice.
  Future<void> setLabel(
    String id,
    String? label, {
    String? name,
    String? mac,
    String? fp,
  }) {
    final r = _records[id];
    final now = DateTime.now().millisecondsSinceEpoch;
    final clean = label?.trim();
    return _put(
      ReadByRecord(
        id,
        name: name ?? r?.name,
        mac: mac ?? r?.mac,
        fp: fp ?? r?.fp,
        screen: r?.screen,
        screenName: r?.screenName,
        connect: r?.connect,
        choiceAt: r?.choiceAt ?? 0,
        label: clean == null || clean.isEmpty ? null : clean,
        labelAt: now,
        at: now,
      ),
    );
  }

  /// Locks [id] to a screen, or back to automatic with null. [connect]
  /// left out keeps what was chosen before, and so is its name.
  Future<void> set(
    String id, {
    String? screen,
    String? screenName,
    String? name,
    String? mac,
    String? fp,
    bool? connect,
  }) {
    final r = _records[id];
    final now = DateTime.now().millisecondsSinceEpoch;
    return _put(
      ReadByRecord(
        id,
        name: name ?? r?.name,
        mac: mac ?? r?.mac,
        fp: fp ?? r?.fp,
        screen: screen,
        screenName: screenName,
        connect: connect ?? r?.connect,
        choiceAt: now,
        label: r?.label,
        labelAt: r?.labelAt ?? 0,
        at: now,
      ),
    );
  }

  /// Lets screens connect to [id], or not, keeping its lock.
  Future<void> setConnect(
    String id,
    bool connect, {
    String? name,
    String? mac,
    String? fp,
  }) {
    final r = _records[id];
    return set(
      id,
      screen: r?.screen,
      screenName: r?.screenName,
      name: name ?? r?.name,
      mac: mac ?? r?.mac,
      fp: fp ?? r?.fp,
      connect: connect,
    );
  }

  /// Takes a record from another screen, stored under [asId] (this
  /// screen's id for the device). The choice and the name each come from
  /// whichever side set them last. Returns whether it changed anything.
  Future<bool> apply(ReadByRecord r, {String? asId}) async {
    final id = asId ?? r.id;
    final mine = _records[id];
    final choice = mine == null || r.choiceAt > mine.choiceAt ? r : mine;
    final named = mine == null || r.labelAt > mine.labelAt ? r : mine;
    if (identical(choice, mine) && identical(named, mine)) return false;
    final newer = mine == null || r.at > mine.at ? r : mine;
    await _put(
      ReadByRecord(
        id,
        name: newer.name ?? mine?.name ?? r.name,
        mac: newer.mac ?? mine?.mac ?? r.mac,
        fp: newer.fp ?? mine?.fp ?? r.fp,
        screen: choice.screen,
        screenName: choice.screenName,
        connect: choice.connect ?? mine?.connect,
        choiceAt: choice.choiceAt,
        label: named.label,
        labelAt: named.labelAt,
        at: newer.at,
      ),
    );
    return true;
  }

  /// Forgets [id]'s record on this screen only (one filed under the wrong
  /// device).
  Future<void> drop(String id) async {
    if (_records.remove(id) == null) return;
    await _prefs?.setString(
      _key,
      jsonEncode([for (final r in _records.values) r.toJson()]),
    );
    notifyListeners();
  }

  Future<void> _put(ReadByRecord r) async {
    _records[r.id] = r;
    await _prefs?.setString(
      _key,
      jsonEncode([for (final r in _records.values) r.toJson()]),
    );
    notifyListeners();
  }
}
