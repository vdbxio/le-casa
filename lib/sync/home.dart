// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto.dart';
import 'session.dart';

enum SyncRole {
  /// Not in a home: this screen works on its own.
  alone,

  /// Other screens connect to this one; it passes everything between them.
  hub,

  /// Connects to the hub.
  member,
}

/// Which home this screen belongs to, and as what. Kept on the screen;
/// there is no account anywhere.
class HomeStore extends ChangeNotifier {
  static const _p = 'sync:';
  SharedPreferences? _prefs;

  late String _id;
  String _name = '';
  SyncRole role = SyncRole.alone;
  Uint8List? key;
  String homeName = '';

  /// The hub's name, on a member.
  String hubName = '';

  ScreenId get me => ScreenId(_id, _name);

  String get tag => key == null ? '' : homeTag(key!);

  HomeStore();

  /// For tests: a store that is never saved.
  HomeStore.memory(String id, String name) : _id = id, _name = name;

  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();
    var id = p.getString('${_p}id');
    if (id == null) {
      id = _hex(randomBytes(8));
      await p.setString('${_p}id', id);
    }
    _id = id;
    _name = p.getString('${_p}name') ?? _defaultName(id);
    role =
        SyncRole.values.asNameMap()[p.getString('${_p}role')] ?? SyncRole.alone;
    final k = p.getString('${_p}key');
    key = k == null ? null : fromHexString(k);
    if (key == null) role = SyncRole.alone;
    homeName = p.getString('${_p}home') ?? '';
    hubName = p.getString('${_p}hub') ?? '';
    notifyListeners();
  }

  static String _defaultName(String id) {
    final kind = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iPad or iPhone',
      TargetPlatform.android => 'Android',
      _ => kIsWeb ? 'Browser' : Platform.operatingSystem,
    };
    return '$kind ${id.substring(0, 4).toUpperCase()}';
  }

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    _name = n;
    await _prefs?.setString('${_p}name', n);
    notifyListeners();
  }

  /// Makes this screen the hub of a new home.
  Future<void> startHome(String name) => _save(
    SyncRole.hub,
    randomBytes(32),
    name.trim().isEmpty ? 'Home' : name.trim(),
    '',
  );

  Future<void> joined(JoinedHome h) =>
      _save(SyncRole.member, h.key, h.name, h.hub.name);

  Future<void> setHubName(String name) async {
    if (name == hubName) return;
    hubName = name;
    await _prefs?.setString('${_p}hub', name);
    notifyListeners();
  }

  /// Leaves the home. Keys and readings already shared stay where they are.
  Future<void> leave() async {
    role = SyncRole.alone;
    key = null;
    homeName = '';
    hubName = '';
    for (final k in ['role', 'key', 'home', 'hub']) {
      await _prefs?.remove('$_p$k');
    }
    notifyListeners();
  }

  Future<void> _save(SyncRole r, Uint8List k, String home, String hub) async {
    role = r;
    key = k;
    homeName = home;
    hubName = hub;
    final p = _prefs;
    if (p != null) {
      await p.setString('${_p}role', r.name);
      await p.setString('${_p}key', _hex(k));
      await p.setString('${_p}home', home);
      await p.setString('${_p}hub', hub);
    }
    notifyListeners();
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHexString(String s) => Uint8List.fromList([
  for (var i = 0; i + 1 < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
