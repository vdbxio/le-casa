// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';
import 'fob_log.dart';

/// A short memory of numeric readings for the sparklines: one sample every
/// two minutes, the last 24 hours. Saved on the tablet every few samples
/// and when the app goes to the background, so a restart keeps the lines.
class History {
  static const interval = Duration(minutes: 2);
  static const keep = 24 * 30; // 24 h at 2 min
  static const prefsKey = 'history:v1';
  static const fobsKey = 'fobs:v1';

  /// Save every this many samples (and on pause), not on every sample.
  static const saveEvery = 5;

  final DeviceTracker tracker;
  final Map<String, List<double>> _series = {};
  Timer? _timer;
  int _unsaved = 0;
  DateTime? _lastSample;

  History(this.tracker);

  /// Button remotes' presses and chirps, by device id.
  final Map<String, FobLog> _fobs = {};

  /// When this screen was running, for telling a silence from a gap in
  /// listening.
  List<Span> _listening = [];
  DateTime? _runStart;
  final Map<String, (String?, DateTime)> _lastBurst = {};

  /// The button log of a remote, and the times this screen listened (the
  /// current run reaching up to [now]).
  (FobLog, List<Span>)? fob(String id, DateTime now) {
    final l = _fobs[id];
    if (l == null) return null;
    return (l, listening(now));
  }

  /// Puts a remote's log in place, for tests and previews.
  @visibleForTesting
  void seedFob(String id, FobLog log, List<Span> listened) {
    _fobs[id] = log;
    _listening = listened;
  }

  List<Span> listening(DateTime now) => mergeSpans([
    ..._listening,
    if (_runStart != null) Span(_runStart!, now),
  ], now);

  /// Notes bursts and presses from button remotes as they are heard.
  void watch() {
    for (final d in tracker.devices) {
      final v = d.decoded;
      if (v == null) continue;
      if (v.kind != DeviceKind.buttons && v.kind != DeviceKind.leDevice) {
        continue;
      }
      if (!v.protocol.startsWith('BTHome')) continue;
      final at = d.latest.seenAt;
      final pid = v.info['packet id'];
      final prev = _lastBurst[d.id];
      // One burst repeats the same packet for a second or so.
      if (prev != null &&
          (pid != null
              ? prev.$1 == pid &&
                    at.difference(prev.$2) < const Duration(seconds: 30)
              : at.difference(prev.$2) < const Duration(seconds: 3))) {
        continue;
      }
      if (prev != null && !at.isAfter(prev.$2)) continue;
      _lastBurst[d.id] = (pid, at);
      final log = _fobs.putIfAbsent(d.id, FobLog.new);
      final presses = [
        for (final e in v.events)
          if (buttonNumber(e.label) case final n?) Press(at, n, e.kind),
      ];
      log.bursts.add(Burst(at, presses.isNotEmpty));
      log.presses.addAll(presses);
      log.trim(at);
      if (presses.isNotEmpty) _unsaved++;
    }
  }

  /// Key for the sum of every solar charger's power.
  static const solarTotal = 'solar|total';

  static String key(String deviceId, String label) => '$deviceId|$label';

  Future<void> start() async {
    await load();
    _runStart = DateTime.now();
    tracker.addListener(watch);
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
      if (raw != null) {
        restore(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
          DateTime.now(),
        );
      }
      final fobs = p.getString(fobsKey);
      if (fobs != null) {
        restoreFobs(
          (jsonDecode(fobs) as Map).cast<String, Object?>(),
          DateTime.now(),
        );
      }
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
  void restoreFobs(Map<String, Object?> j, DateTime now) {
    for (final e in (j['fobs'] as Map? ?? const {}).entries) {
      final l = FobLog.fromJson((e.value as Map).cast<String, Object?>())
        ..trim(now);
      final live = _fobs[e.key as String];
      if (live != null) {
        l.bursts.addAll(live.bursts);
        l.presses.addAll(live.presses);
      }
      _fobs[e.key as String] = l;
    }
    _listening = mergeSpans([
      for (final s in (j['listening'] as List? ?? const []))
        Span(
          DateTime.fromMillisecondsSinceEpoch(
            ((s as List)[0] as num).toInt() * 1000,
          ),
          DateTime.fromMillisecondsSinceEpoch((s[1] as num).toInt() * 1000),
        ),
      ..._listening,
    ], now);
  }

  @visibleForTesting
  Map<String, Object?> fobsJson(DateTime now) => {
    'fobs': {
      for (final e in _fobs.entries) e.key: (e.value..trim(now)).toJson(),
    },
    'listening': [
      for (final s in listening(now))
        [
          s.from.millisecondsSinceEpoch ~/ 1000,
          s.to.millisecondsSinceEpoch ~/ 1000,
        ],
    ],
  };

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
    if (_series.isEmpty && _fobs.isEmpty) return;
    _unsaved = 0;
    try {
      final p = await SharedPreferences.getInstance();
      if (_series.isNotEmpty) {
        await p.setString(prefsKey, jsonEncode(toJson()));
      }
      if (_fobs.isNotEmpty) {
        await p.setString(fobsKey, jsonEncode(fobsJson(DateTime.now())));
      }
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

  void dispose() {
    _timer?.cancel();
    tracker.removeListener(watch);
  }
}
