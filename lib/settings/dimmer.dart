// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;

import '../platform/tablet.dart';
import 'settings_store.dart';

/// Maps ambient light to screen brightness. Pure so it can be tested:
/// dark room -> [min], ~500 lux (bright indoor) and above -> full.
double brightnessForLux(double lux, double min) {
  final t = (math.log(lux.clamp(0, 100000) + 1) / math.log(501)).clamp(
    0.0,
    1.0,
  );
  return min + (1 - min) * t;
}

/// Applies auto-dim and keep-screen-on from [SettingsStore] using the
/// tablet's light sensor. Smooths the reading so a hand passing over the
/// sensor does not flash the screen.
class Dimmer {
  final SettingsStore settings;
  final TabletSensors tablet;
  double? _smoothed;
  double? _applied;

  Dimmer(this.settings, this.tablet) {
    settings.addListener(_apply);
    tablet.addListener(_apply);
    _apply();
  }

  void _apply() {
    tablet.keepScreenOn(settings.keepScreenOn);
    final lux = tablet.lux;
    if (!settings.autoDim || lux == null) {
      if (_applied != null) {
        _applied = null;
        _smoothed = null;
        tablet.setBrightness(null);
      }
      return;
    }
    final target = brightnessForLux(lux, settings.minBrightness);
    _smoothed = _smoothed == null ? target : _smoothed! * 0.7 + target * 0.3;
    if (_applied == null || (_smoothed! - _applied!).abs() > 0.03) {
      _applied = _smoothed;
      tablet.setBrightness(_applied);
    }
  }

  void dispose() {
    settings.removeListener(_apply);
    tablet.removeListener(_apply);
  }
}
