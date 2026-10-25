// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../decoders/raw_advertisement.dart';

/// Per-device encryption keys (Victron Instant Readout, BTHome bindkeys)
/// and battery PINs, kept on this tablet only. Keyed by the device id the
/// scanner reports.
class KeyStore extends ChangeNotifier {
  static const _prefix = 'key:';
  static const _secretPrefix = 'secret:';
  final Map<String, Uint8List> _keys = {};
  final Map<String, String> _secrets = {};
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    for (final k in _prefs!.getKeys()) {
      if (k.startsWith(_prefix)) {
        final v = _prefs!.getString(k);
        if (v != null) _keys[k.substring(_prefix.length)] = fromHex(v);
      } else if (k.startsWith(_secretPrefix)) {
        final v = _prefs!.getString(k);
        if (v != null) _secrets[k.substring(_secretPrefix.length)] = v;
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

  /// PIN or password a BMS wants before it answers (JBD, Saftkiste, ...).
  String? secretFor(String id) => _secrets[id];

  Future<void> setSecret(String id, String secret) async {
    final s = secret.trim();
    if (s.isEmpty) return removeSecret(id);
    _secrets[id] = s;
    await _prefs?.setString('$_secretPrefix$id', s);
    notifyListeners();
  }

  Future<void> removeSecret(String id) async {
    _secrets.remove(id);
    await _prefs?.remove('$_secretPrefix$id');
    notifyListeners();
  }
}
