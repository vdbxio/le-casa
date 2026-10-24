// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A place for the weather card, picked in Settings.
class WeatherPlace {
  final String name;
  final double lat, lon;
  const WeatherPlace(this.name, this.lat, this.lon);
}

/// App-wide preferences, saved on the tablet.
class SettingsStore extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;

  /// Follow the ambient light sensor to dim the screen.
  bool autoDim = true;

  /// The darkest auto-dim goes, 0..1 of full brightness.
  double minBrightness = 0.15;

  /// Keep the screen on while the dashboard is showing (wall tablet).
  bool keepScreenOn = true;

  WeatherPlace? place;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    themeMode =
        ThemeMode.values.asNameMap()[p.getString('settings:theme')] ??
        ThemeMode.system;
    autoDim = p.getBool('settings:autoDim') ?? true;
    minBrightness = p.getDouble('settings:minBrightness') ?? 0.15;
    keepScreenOn = p.getBool('settings:keepScreenOn') ?? true;
    final name = p.getString('settings:placeName');
    final lat = p.getDouble('settings:placeLat');
    final lon = p.getDouble('settings:placeLon');
    place = (name != null && lat != null && lon != null)
        ? WeatherPlace(name, lat, lon)
        : null;
    notifyListeners();
  }

  Future<void> update({
    ThemeMode? themeMode,
    bool? autoDim,
    double? minBrightness,
    bool? keepScreenOn,
  }) async {
    this.themeMode = themeMode ?? this.themeMode;
    this.autoDim = autoDim ?? this.autoDim;
    this.minBrightness = minBrightness ?? this.minBrightness;
    this.keepScreenOn = keepScreenOn ?? this.keepScreenOn;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString('settings:theme', this.themeMode.name);
    await p.setBool('settings:autoDim', this.autoDim);
    await p.setDouble('settings:minBrightness', this.minBrightness);
    await p.setBool('settings:keepScreenOn', this.keepScreenOn);
  }

  Future<void> setPlace(WeatherPlace? place) async {
    this.place = place;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    if (place == null) {
      await p.remove('settings:placeName');
      await p.remove('settings:placeLat');
      await p.remove('settings:placeLon');
    } else {
      await p.setString('settings:placeName', place.name);
      await p.setDouble('settings:placeLat', place.lat);
      await p.setDouble('settings:placeLon', place.lon);
    }
  }
}
