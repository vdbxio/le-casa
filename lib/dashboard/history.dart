// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';

/// A short memory of numeric readings for the sparklines: one sample every
/// two minutes, the last 24 hours. Saved on the tablet every few samples
/// and when the app goes to the background, so a restart keeps the lines.
class History {
  static const interval = Duration(minutes: 2);
  static const keep = 24 * 30; // 24 h at 2 min
  static const prefsKey = 'history:v1';

  /// Save every this many samples (and on pause), not on every sample.
  static const saveEvery = 5;

  final DeviceTracker tracker;
  final Map<String, List<double>> _series = {};
  Timer? _timer;
  int _unsaved = 0;
  DateTime? _lastSample;

  History(this.tracker);

  /// Key for the sum of every solar charger's power.
  static const solarTotal = 'solar|total';

  static String key(String deviceId, String label) => '$deviceId|$label';

  Future<void> start() async {
    await load();
    // A first sample soon after launch, so sparklines start filling.
    Timer(const Duration(seconds: 20), sample);
    _timer = Timer.periodic(interval, (_) => sample());
  }

  /// Reads saved series, dropping the samples that fell out of the 24 h
  /// window while the app was not running.
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(prefsKey);
      if (raw == null) return;
      restore((jsonDecode(raw) as Map).cast<String, Object?>(), DateTime.now());
    } catch (e) {
      debugPrint('History could not be read, starting empty: $e');
    }
  }

  @visibleForTesting
  void restore(Map<String, Object?> j, DateTime now) {
    final at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt());
    final missed = now.difference(at).inSeconds ~/ interval.inSeconds;
    if (missed >= keep || missed < 0) return;
    final series = (j['series'] as Map).cast<String, Object?>();
    for (final e in series.entries) {
      final l = [for (final v in e.value as List) (v as num).toDouble()];
      final drop = (l.length + missed - keep).clamp(0, l.length);
      final kept = l.sublist(drop);
      // Samples taken since launch go after the saved ones.
      _series[e.key] = [...kept, ...?_series[e.key]];
    }
    _lastSample = at;
  }

  @visibleForTesting
  Map<String, Object?> toJson() => {
    'at': (_lastSample ?? DateTime.now()).millisecondsSinceEpoch,
    'series': {
      for (final e in _series.entries)
        e.key: [for (final v in e.value) _round(v)],
    },
  };

  /// Three significant decimals is plenty for a sparkline and keeps the
  /// saved text small.
  static num _round(double v) {
    final r = (v * 1000).roundToDouble() / 1000;
    return r == r.truncateToDouble() ? r.toInt() : r;
  }

  Future<void> save() async {
    if (_series.isEmpty) return;
    _unsaved = 0;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(prefsKey, jsonEncode(toJson()));
    } catch (e) {
      debugPrint('History could not be saved: $e');
    }
  }

  void sample() {
    _lastSample = DateTime.now();
    double solar = 0;
    var anySolar = false;
    for (final d in tracker.devices) {
      final v = d.view;
      if (v == null) continue;
      for (final r in v.readings) {
        final x = r.value;
        if (x is num) _add(key(d.id, r.label), x.toDouble());
      }
      if (v.kind == DeviceKind.solar) {
        final p = v.readings
            .where((r) => r.label == 'solar power')
            .firstOrNull
            ?.value;
        if (p is num) {
          solar += p;
          anySolar = true;
        }
      }
    }
    if (anySolar) _add(solarTotal, solar);
    if (++_unsaved >= saveEvery) save();
  }

  void _add(String k, double v) {
    final l = _series.putIfAbsent(k, () => []);
    l.add(v);
    if (l.length > keep) l.removeRange(0, l.length - keep);
  }

  /// The series for a key, or null when there are too few points to draw.
  List<double>? of(String k) {
    final l = _series[k];
    return (l == null || l.length < 3) ? null : List.unmodifiable(l);
  }

  void dispose() => _timer?.cancel();
}
