// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';

/// A short memory of numeric readings for the sparklines: one sample every
/// two minutes, the last 24 hours, in memory only for now.
class History {
  static const interval = Duration(minutes: 2);
  static const keep = 24 * 30; // 24 h at 2 min

  final DeviceTracker tracker;
  final Map<String, List<double>> _series = {};
  Timer? _timer;

  History(this.tracker);

  /// Key for the sum of every solar charger's power.
  static const solarTotal = 'solar|total';

  static String key(String deviceId, String label) => '$deviceId|$label';

  void start() {
    // A first sample soon after launch, so sparklines start filling.
    Timer(const Duration(seconds: 20), sample);
    _timer = Timer.periodic(interval, (_) => sample());
  }

  void sample() {
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
