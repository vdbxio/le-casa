// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/palette.dart';

/// The overall look, set in Settings › Design: the shape of cards, the
/// space around them, and colours that replace the standard ones. Light
/// and dark keep their own colours.
class DesignStore extends ChangeNotifier {
  static const prefsKey = 'design:v1';

  CardStyle style = CardStyle.standard;
  Map<String, int> light = {};
  Map<String, int> dark = {};

  Map<String, int> colorsFor(Brightness b) =>
      b == Brightness.dark ? dark : light;

  bool get isStandard =>
      _sameStyle(style, CardStyle.standard) && light.isEmpty && dark.isEmpty;

  ThemeData theme(Brightness b) =>
      leCasaTheme(b, colors: colorsFor(b), style: style);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(prefsKey);
      if (raw != null) _read((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (e) {
      debugPrint('Design could not be read, using the standard one: $e');
    }
    notifyListeners();
  }

  void setStyle(CardStyle s) {
    style = s;
    _changed();
  }

  /// Replaces one colour for [b], or puts the standard one back when
  /// [color] is null.
  void setColor(Brightness b, String name, Color? color) {
    final m = b == Brightness.dark ? dark : light;
    if (color == null) {
      m.remove(name);
    } else {
      m[name] = color.toARGB32();
    }
    _changed();
  }

  void reset() {
    style = CardStyle.standard;
    light = {};
    dark = {};
    _changed();
  }

  Timer? _save;

  void _changed() {
    notifyListeners();
    // Sliders move many times a second: save once they settle.
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), _write);
  }

  Map<String, Object?> toJson() => {
    'radius': style.radius,
    'border': style.border,
    'padding': style.padding,
    'gap': style.gap,
    'edge': style.edge,
    'title': style.titleSize,
    'light': light,
    'dark': dark,
  };

  void _read(Map<String, Object?> j) {
    double d(String k, double fallback) =>
        (j[k] as num?)?.toDouble() ?? fallback;
    const s = CardStyle.standard;
    style = CardStyle(
      radius: d('radius', s.radius),
      border: d('border', s.border),
      padding: d('padding', s.padding),
      gap: d('gap', s.gap),
      edge: d('edge', s.edge),
      titleSize: d('title', s.titleSize),
    );
    Map<String, int> colors(Object? m) => {
      for (final e in ((m as Map?) ?? const {}).entries)
        if (e.value is num && LeColors.editable.contains(e.key))
          '${e.key}': (e.value as num).toInt(),
    };
    light = colors(j['light']);
    dark = colors(j['dark']);
  }

  Future<void> _write() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(prefsKey, jsonEncode(toJson()));
    } catch (_) {}
  }

  @override
  void dispose() {
    _save?.cancel();
    super.dispose();
  }

  static bool _sameStyle(CardStyle a, CardStyle b) =>
      a.radius == b.radius &&
      a.border == b.border &&
      a.padding == b.padding &&
      a.gap == b.gap &&
      a.edge == b.edge &&
      a.titleSize == b.titleSize;
}
