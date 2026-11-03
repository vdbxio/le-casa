// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'layout.dart';

/// Holds the dashboard document, the edit-mode state, and saves changes.
class DashboardController extends ChangeNotifier {
  static const prefsKey = 'dashboard:v1';

  DashboardDoc? _doc;
  bool _loaded = false;
  bool editing = false;

  /// The slot selected in edit mode.
  NodePath? selected;

  /// The page on screen. Always 0 until swiping between pages lands.
  int pageIndex = 0;

  bool get loaded => _loaded;

  /// False until the first-run layout has been generated (or loaded).
  bool get hasLayout => _doc != null;

  DashboardLayout get page => _doc!.pages[pageIndex];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(prefsKey);
      if (raw != null) {
        _doc = DashboardDoc.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
      }
    } catch (e) {
      debugPrint('Dashboard layout could not be read, starting fresh: $e');
      _doc = null;
    }
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_heardKey);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as Map).entries) {
          heard['${e.key}'] = DateTime.fromMillisecondsSinceEpoch(
            (e.value as num).toInt(),
          );
        }
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  /// Replaces the page (first run, or "rebuild from devices" in Settings).
  void setLayout(DashboardLayout layout) {
    _doc = DashboardDoc([layout]);
    pageIndex = 0;
    selected = null;
    changed();
  }

  /// Wipes the saved layout; the dashboard builds a new one from devices.
  Future<void> reset() async {
    _doc = null;
    selected = null;
    editing = false;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(prefsKey);
  }

  /// When each device on the dashboard was last heard, kept over a
  /// restart so a card can say "Not heard for 5h" before the device is
  /// heard again.
  final Map<String, DateTime> heard = {};
  static const _heardKey = 'dashboard:heard';

  /// Remembers [times], saving only when one moved by a minute or more.
  Future<void> rememberHeard(Map<String, DateTime> times) async {
    var moved = false;
    for (final e in times.entries) {
      final was = heard[e.key];
      if (was != null && e.value.difference(was).inMinutes < 1) continue;
      heard[e.key] = e.value;
      moved = true;
    }
    if (!moved) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _heardKey,
        jsonEncode({
          for (final e in heard.entries) e.key: e.value.millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  /// A card on its way onto the dashboard, from Settings › Devices. The
  /// dashboard shows a + in every empty slot and between slots until one
  /// is tapped.
  CardSpec? placing;

  void startPlacing(CardSpec spec) {
    placing = spec;
    editing = false;
    selected = null;
    notifyListeners();
  }

  void stopPlacing() {
    if (placing == null) return;
    placing = null;
    notifyListeners();
  }

  /// Puts the card being placed into the empty slot at [path], taking it
  /// off wherever else it was.
  void place(NodePath path) {
    final spec = placing;
    if (spec == null || !hasLayout) return;
    final slot = page.at(path);
    if (slot is! Slot) return;
    page.take(spec.key);
    slot.card = spec;
    placing = null;
    changed();
  }

  /// Makes a new slot before child [index] of the split at [splitPath] and
  /// puts the card being placed into it.
  void placeNew(NodePath splitPath, int index) {
    if (placing == null || !hasLayout) return;
    place(page.insertSlot(splitPath, index));
  }

  void setEditing(bool on) {
    placing = null;
    editing = on;
    selected = null;
    notifyListeners();
  }

  void select(NodePath? path) {
    selected = path;
    notifyListeners();
  }

  /// Call after mutating [page]: tidies, repaints and saves (debounced, so
  /// dragging a handle does not hammer storage).
  void changed({bool tidy = false}) {
    if (tidy) page.normalize();
    notifyListeners();
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 600), _write);
  }

  Timer? _save;

  Future<void> _write() async {
    final doc = _doc;
    if (doc == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(prefsKey, jsonEncode(doc.toJson()));
  }

  @override
  void dispose() {
    _save?.cancel();
    super.dispose();
  }
}
