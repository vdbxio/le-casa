// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../decoders/raw_advertisement.dart';

/// Kinds of secret kept per device.
enum SecretKind {
  /// 16-byte encryption key (Victron Instant Readout, BTHome bindkey).
  key,

  /// PIN or password a BMS wants (JBD, Saftkiste, ...).
  pin,
}

/// One key or PIN with what screen sync needs to merge it: when it last
/// changed, and the device's name and MAC so another screen, which may know
/// the device under a different id (iOS hides MACs), can find it. A null
/// [value] records a removal.
class KeyRecord {
  final SecretKind kind;
  final String id;
  final String? name;
  final String? mac;

  /// Manufacturer-data fingerprint, for a device another screen knows by
  /// neither id, MAC nor name (the Daly: a name on iOS, a MAC on Android).
  final String? fp;
  final String? value;

  /// Milliseconds since the epoch. 0 for entries saved before sync existed.
  final int at;

  const KeyRecord(
    this.kind,
    this.id, {
    this.name,
    this.mac,
    this.fp,
    this.value,
    this.at = 0,
  });

  Map<String, Object?> toJson() => {
    'k': kind.name,
    'id': id,
    'name': ?name,
    'mac': ?mac,
    'fp': ?fp,
    'v': value,
    'at': at,
  };

  static KeyRecord fromJson(Map<String, Object?> j) => KeyRecord(
    SecretKind.values.byName('${j['k']}'),
    '${j['id']}',
    name: j['name'] as String?,
    mac: j['mac'] as String?,
    fp: j['fp'] as String?,
    value: j['v'] as String?,
    at: (j['at'] as num?)?.toInt() ?? 0,
  );
}

/// Name, MAC and advert fingerprint of a device id, as far as this screen
/// knows them.
typedef DeviceLabel = ({String? name, String? mac, String? fp}) Function(
  String id,
);

/// Per-device encryption keys (Victron Instant Readout, BTHome bindkeys)
/// and battery PINs. Keyed by the device id the scanner reports. Screens in
/// one home share them over Bluetooth (see SyncService).
class KeyStore extends ChangeNotifier {
  static const _prefix = 'key:';
  static const _secretPrefix = 'secret:';
  static const _metaPrefix = 'keymeta:';
  final Map<String, Uint8List> _keys = {};
  final Map<String, String> _secrets = {};

  /// Sync bookkeeping by "kind:id", tombstones included.
  final Map<String, KeyRecord> _meta = {};
  SharedPreferences? _prefs;

  /// Fills in a device's name and MAC when a key is saved. Set by the app.
  DeviceLabel? label;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    for (final k in _prefs!.getKeys()) {
      if (k.startsWith(_prefix)) {
        final v = _prefs!.getString(k);
        if (v != null) _keys[k.substring(_prefix.length)] = fromHex(v);
      } else if (k.startsWith(_secretPrefix)) {
        final v = _prefs!.getString(k);
        if (v != null) _secrets[k.substring(_secretPrefix.length)] = v;
      } else if (k.startsWith(_metaPrefix)) {
        try {
          final j = jsonDecode(_prefs!.getString(k) ?? '');
          final r = KeyRecord.fromJson((j as Map).cast());
          _meta[_slot(r.kind, r.id)] = r;
        } catch (_) {}
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
    await _put(_local(SecretKind.key, id, hex(bytes, sep: '')));
  }

  Future<void> remove(String id) => _put(_local(SecretKind.key, id, null));

  /// PIN or password a BMS wants before it answers (JBD, Saftkiste, ...).
  String? secretFor(String id) => _secrets[id];

  Future<void> setSecret(String id, String secret) async {
    final s = secret.trim();
    if (s.isEmpty) return removeSecret(id);
    await _put(_local(SecretKind.pin, id, s));
  }

  Future<void> removeSecret(String id) =>
      _put(_local(SecretKind.pin, id, null));

  /// Forgets an entry on this screen only, leaving no removal behind for
  /// other screens to copy: for one filed under the wrong device.
  Future<void> drop(SecretKind kind, String id) async {
    switch (kind) {
      case SecretKind.key:
        _keys.remove(id);
        await _prefs?.remove('$_prefix$id');
      case SecretKind.pin:
        _secrets.remove(id);
        await _prefs?.remove('$_secretPrefix$id');
    }
    _meta.remove(_slot(kind, id));
    await _prefs?.remove('$_metaPrefix${_slot(kind, id)}');
    notifyListeners();
  }

  /// Every key and PIN with its sync bookkeeping, removals included.
  List<KeyRecord> get records {
    final out = <String, KeyRecord>{..._meta};
    for (final e in _keys.entries) {
      out.putIfAbsent(
        _slot(SecretKind.key, e.key),
        () => _withLabel(
          KeyRecord(SecretKind.key, e.key, value: hex(e.value, sep: '')),
        ),
      );
    }
    for (final e in _secrets.entries) {
      out.putIfAbsent(
        _slot(SecretKind.pin, e.key),
        () => _withLabel(KeyRecord(SecretKind.pin, e.key, value: e.value)),
      );
    }
    // Fill values in from the live maps; meta only holds bookkeeping.
    return [
      for (final r in out.values)
        KeyRecord(
          r.kind,
          r.id,
          name: r.name,
          mac: r.mac,
          fp: r.fp,
          at: r.at,
          value: r.value == null
              ? null
              : switch (r.kind) {
                  SecretKind.key =>
                    _keys[r.id] == null ? null : hex(_keys[r.id]!, sep: ''),
                  SecretKind.pin => _secrets[r.id],
                },
        ),
    ];
  }

  KeyRecord? recordFor(SecretKind kind, String id) =>
      records.where((r) => r.kind == kind && r.id == id).firstOrNull;

  /// Takes a key or PIN from another screen, stored under [asId] (this
  /// screen's id for the device) when given. Returns whether it changed
  /// anything: only news wins, and a screen that has no entry at all takes
  /// whatever comes.
  Future<bool> apply(KeyRecord r, {String? asId}) async {
    final id = asId ?? r.id;
    final mine = recordFor(r.kind, id);
    if (mine != null && r.at <= mine.at) return false;
    // A removal of something we never had is still recorded, so an old
    // copy on a third screen does not bring it back.
    final v = r.value;
    if (r.kind == SecretKind.key && v != null) {
      try {
        if (fromHex(v).length != 16) return false;
      } catch (_) {
        return false;
      }
    }
    await _put(
      KeyRecord(
        r.kind,
        id,
        name: r.name,
        mac: r.mac,
        fp: r.fp,
        value: v,
        at: r.at,
      ),
    );
    return true;
  }

  KeyRecord _local(SecretKind kind, String id, String? value) => _withLabel(
    KeyRecord(
      kind,
      id,
      value: value,
      at: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  KeyRecord _withLabel(KeyRecord r) {
    final l = label?.call(r.id);
    if (l == null) return r;
    return KeyRecord(
      r.kind,
      r.id,
      name: r.name ?? l.name,
      mac: r.mac ?? l.mac,
      fp: r.fp ?? l.fp,
      value: r.value,
      at: r.at,
    );
  }

  Future<void> _put(KeyRecord r) async {
    final v = r.value;
    switch (r.kind) {
      case SecretKind.key:
        if (v == null) {
          _keys.remove(r.id);
          await _prefs?.remove('$_prefix${r.id}');
        } else {
          _keys[r.id] = fromHex(v);
          await _prefs?.setString('$_prefix${r.id}', v);
        }
      case SecretKind.pin:
        if (v == null) {
          _secrets.remove(r.id);
          await _prefs?.remove('$_secretPrefix${r.id}');
        } else {
          _secrets[r.id] = v;
          await _prefs?.setString('$_secretPrefix${r.id}', v);
        }
    }
    final meta = KeyRecord(
      r.kind,
      r.id,
      name: r.name,
      mac: r.mac,
      fp: r.fp,
      at: r.at,
      value: v == null ? null : '',
    );
    _meta[_slot(r.kind, r.id)] = meta;
    await _prefs?.setString(
      '$_metaPrefix${_slot(r.kind, r.id)}',
      jsonEncode(meta.toJson()),
    );
    notifyListeners();
  }

  static String _slot(SecretKind k, String id) => '${k.name}:$id';
}
