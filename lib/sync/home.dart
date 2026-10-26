// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/tablet.dart';
import 'crypto.dart';
import 'session.dart';

/// Which home this screen belongs to. Kept on the screen; there is no
/// account anywhere. Every screen in a home is equal: none is in charge.
class HomeStore extends ChangeNotifier {
  static const _p = 'sync:';
  SharedPreferences? _prefs;

  late String _id;
  String _name = '';
  Uint8List? key;
  String homeName = '';

  /// A phone. Phones come and go and have batteries to save, so they only
  /// read a device over a connection when it is locked to them.
  bool phone = false;

  ScreenId get me => ScreenId(_id, _name);

  bool get inHome => key != null;

  String get tag => key == null ? '' : homeTag(key!);

  HomeStore();

  /// For tests: a store that is never saved.
  HomeStore.memory(String id, String name, {this.phone = false})
    : _id = id,
      _name = name;

  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();
    var id = p.getString('${_p}id');
    if (id == null) {
      id = _hex(randomBytes(8));
      await p.setString('${_p}id', id);
    }
    _id = id;
    final device = await TabletSensors.deviceName();
    _name = p.getString('${_p}name') ?? _defaultName(id, device);
    final k = p.getString('${_p}key');
    key = k == null ? null : fromHexString(k);
    homeName = p.getString('${_p}home') ?? '';
    phone = device?.startsWith('iPhone') ?? false;
    notifyListeners();
  }

  /// "iPad" or "M10", with a short id so two alike screens differ.
  static String _defaultName(String id, String? device) {
    final short = id.substring(0, 4).toUpperCase();
    final name = device?.trim();
    if (name != null && name.isNotEmpty) return '$name $short';
    final kind = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iPad or iPhone',
      TargetPlatform.android => 'Android',
      _ => kIsWeb ? 'Browser' : Platform.operatingSystem,
    };
    return '$kind $short';
  }

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    _name = n;
    await _prefs?.setString('${_p}name', n);
    notifyListeners();
  }

  /// Starts a new home with this screen in it.
  Future<void> startHome(String name) =>
      _save(randomBytes(32), name.trim().isEmpty ? 'Home' : name.trim());

  Future<void> joined(JoinedHome h) => _save(h.key, h.name);

  /// Leaves the home. Keys and readings already shared stay where they are.
  Future<void> leave() async {
    key = null;
    homeName = '';
    for (final k in ['role', 'key', 'home', 'hub']) {
      await _prefs?.remove('$_p$k');
    }
    notifyListeners();
  }

  Future<void> _save(Uint8List k, String home) async {
    key = k;
    homeName = home;
    final p = _prefs;
    if (p != null) {
      await p.setString('${_p}key', _hex(k));
      await p.setString('${_p}home', home);
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
