// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Android only: asks for link parameters right after connecting, through
// GattTuning.kt. The PRITOM M10 drops every link to a Daly BMS module one
// supervision timeout after the module requests new connection
// parameters; asking first, at high priority and on the 1M PHY, is what an
// app can do about it. Harmless for other devices: Le'Casa only holds a
// link for the few seconds a read takes.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LinkTuning {
  static const _channel = MethodChannel('io.vdbx.lecasa/gatt');

  /// Whether to tune at all; tests and other platforms skip it.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// [address] is the MAC address, which is the device id on Android.
  static Future<void> tune(
    String address, {
    String? priority = 'high',
    bool phy1m = true,
  }) async {
    if (!supported) return;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('tuneLink', {
        'address': address.toUpperCase(),
        'priority': priority,
        'phy1m': phy1m,
      });
      debugPrint('gatt: tuned $address: $r');
    } on MissingPluginException {
      // not on this platform build
    } on PlatformException catch (e) {
      debugPrint('gatt: tuning $address failed: $e');
    }
  }
}
