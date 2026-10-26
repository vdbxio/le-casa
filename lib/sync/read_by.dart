// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which screen reads one device over a connection: a screen that the
/// person locked it to, or none (automatic). Shared by every screen in a
/// home, merged like keys: the newest choice wins.
class ReadByRecord {
  final String id;
  final String? name;
  final String? mac;

  /// Manufacturer-data fingerprint, to find the device on other screens.
  final String? fp;

  /// Screen id, or null for automatic.
  final String? screen;
  final String? screenName;

  /// Milliseconds since the epoch.
  final int at;

  const ReadByRecord(
    this.id, {
    this.name,
    this.mac,
    this.fp,
    this.screen,
    this.screenName,
    this.at = 0,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': ?name,
    'mac': ?mac,
    'fp': ?fp,
    's': ?screen,
    'sn': ?screenName,
    'at': at,
  };

  static ReadByRecord fromJson(Map<String, Object?> j) => ReadByRecord(
    '${j['id']}',
    name: j['name'] as String?,
    mac: j['mac'] as String?,
    fp: j['fp'] as String?,
    screen: j['s'] as String?,
    screenName: j['sn'] as String?,
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

  /// Locks [id] to a screen, or back to automatic with null.
  Future<void> set(
    String id, {
    String? screen,
    String? screenName,
    String? name,
    String? mac,
    String? fp,
  }) => _put(
    ReadByRecord(
      id,
      name: name,
      mac: mac,
      fp: fp,
      screen: screen,
      screenName: screenName,
      at: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  /// Takes a choice made on another screen, stored under [asId] (this
  /// screen's id for the device). Returns whether it changed anything.
  Future<bool> apply(ReadByRecord r, {String? asId}) async {
    final id = asId ?? r.id;
    final mine = _records[id];
    if (mine != null && r.at <= mine.at) return false;
    await _put(
      ReadByRecord(
        id,
        name: r.name,
        mac: r.mac,
        fp: r.fp,
        screen: r.screen,
        screenName: r.screenName,
        at: r.at,
      ),
    );
    return true;
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
