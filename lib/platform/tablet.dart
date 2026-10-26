// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The tablet's own sensors and screen controls, over a small platform
/// channel implemented in MainActivity.kt (Android) and AppDelegate.swift
/// (iPad). Everything degrades to "not available" where the platform side
/// is missing (tests) or has no such sensor.
class TabletSensors extends ChangeNotifier {
  static const _methods = MethodChannel('io.vdbx.lecasa/tablet');
  static const _light = EventChannel('io.vdbx.lecasa/light');

  int? batteryPercent;
  bool? charging;

  /// Ambient light in lux, or null when there is no light sensor.
  double? lux;

  bool available = true;

  StreamSubscription? _lightSub;
  Timer? _poll;

  void start() {
    _readBattery();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _readBattery());
    _lightSub = _light.receiveBroadcastStream().listen(
      (v) {
        lux = (v as num).toDouble();
        notifyListeners();
      },
      onError: (Object e) => debugPrint('No light sensor: $e'),
      cancelOnError: true,
    );
  }

  Future<void> _readBattery() async {
    try {
      final m = await _methods.invokeMapMethod<String, Object?>('battery');
      batteryPercent = (m?['level'] as num?)?.toInt();
      charging = m?['charging'] as bool?;
      notifyListeners();
    } on MissingPluginException {
      available = false;
      _poll?.cancel();
    } on PlatformException catch (e) {
      debugPrint('Battery read failed: $e');
    }
  }

  /// 0..1 overrides the screen brightness for this app; null hands it back
  /// to the system setting.
  Future<void> setBrightness(double? value) async {
    try {
      await _methods.invokeMethod('setBrightness', value);
    } on MissingPluginException {
      // Not on this platform.
    }
  }

  /// What the system calls this device: "iPad", "iPhone", or an Android
  /// tablet's name or model. Null when the platform does not say.
  static Future<String?> deviceName() async {
    try {
      return await _methods.invokeMethod<String>('deviceName');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> keepScreenOn(bool on) async {
    try {
      await _methods.invokeMethod('keepScreenOn', on);
    } on MissingPluginException {
      // Not on this platform.
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lightSub?.cancel();
    super.dispose();
  }
}

/// Full screen with no status bar, and on Android no navigation bar
/// either. Swiping in from an edge shows them for a moment.
void hideSystemBars() =>
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

/// Hides the system bars now, and again whenever something other than an
/// edge swipe (the keyboard, a system dialog) brings them back.
void keepSystemBarsHidden() {
  hideSystemBars();
  SystemChrome.setSystemUIChangeCallback((visible) async {
    if (!visible) return;
    await Future<void>.delayed(const Duration(seconds: 3));
    hideSystemBars();
  });
}
