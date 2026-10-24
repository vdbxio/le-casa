// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../decoders/raw_advertisement.dart';

/// Per-device encryption keys (Victron Instant Readout, BTHome bindkeys),
/// kept on this tablet only. Keyed by the device id the scanner reports.
class KeyStore extends ChangeNotifier {
  static const _prefix = 'key:';
  final Map<String, Uint8List> _keys = {};
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    for (final k in _prefs!.getKeys()) {
      if (k.startsWith(_prefix)) {
        final v = _prefs!.getString(k);
        if (v != null) _keys[k.substring(_prefix.length)] = fromHex(v);
      }
    }
    notifyListeners();
  }

  Uint8List? keyFor(String id) => _keys[id];

  bool has(String id) => _keys.containsKey(id);

  Future<void> set(String id, String hexKey) async {
    final bytes = fromHex(hexKey);
    if (bytes.length != 16) {
      throw const FormatException('Key must be 16 bytes (32 hex characters)');
    }
    _keys[id] = bytes;
    await _prefs?.setString('$_prefix$id', hex(bytes, sep: ''));
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _keys.remove(id);
    await _prefs?.remove('$_prefix$id');
    notifyListeners();
  }
}
