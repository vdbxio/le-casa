// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Asks for a slow connection interval on links that carry little, so the
// radio spends its time scanning instead. Android only: the Bluetooth
// plugin has no call for it, so MainActivity does it.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LinkTuning {
  static const _channel = MethodChannel('io.vdbx.lecasa/ble');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Asks for a 100 to 125 ms interval on the link to [mac], in either
  /// role. A link at the usual 30 ms or less keeps the M10's radio busy
  /// even when nothing is sent, and its scan hears a tenth of what it
  /// should. False when it could not ask.
  static Future<bool> relax(String mac) async {
    if (!_android) return false;
    try {
      final ok = await _channel
          .invokeMethod<bool>('relaxLink', mac)
          .timeout(const Duration(seconds: 10));
      debugPrint(
        'ble: slow interval on $mac ${ok == true ? 'asked' : 'not asked'}',
      );
      return ok == true;
    } catch (e) {
      debugPrint('ble: slow interval on $mac failed: $e');
      return false;
    }
  }

  /// Lets go of what [relax] holds for [mac].
  static Future<void> release(String mac) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('releaseLink', mac);
    } catch (_) {}
  }
}
