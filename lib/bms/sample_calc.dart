// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Fills in what a BMS did not report but can be worked out from what it
// did: power from volts and amps, runtime from charge and current, cell
// spread from cell voltages, pack totals from packs.

import 'dart:math' as math;

import 'bms_types.dart';
import 'bytes.dart';

const _hrsToSecs = 3600;

num _n(BmsSample d, String k) => (d[k] as num?) ?? 0;

List<double> _cells(BmsSample d) =>
    ((d[BmsKeys.cellVoltages] as List?) ?? const [])
        .cast<num>()
        .map((e) => e.toDouble())
        .toList();

class _C {
  final String output;
  final Set<String> requires;
  final bool Function(BmsSample) apply;
  const _C(this.output, this.requires, this.apply);
}

final List<_C> _registry = [
  _C('voltage', {'cell_voltages'}, (d) {
    d['voltage'] = pyRound(_cells(d).fold<double>(0, (a, b) => a + b), 3);
    return true;
  }),
  _C('delta_voltage', {'cell_voltages'}, (d) {
    final c = _cells(d);
    if (c.isEmpty) return false;
    d['delta_voltage'] = pyRound(c.reduce(math.max) - c.reduce(math.min), 3);
    return true;
  }),
  _C('cycle_charge', {'design_capacity', 'battery_level'}, (d) {
    d['cycle_charge'] =
        (_n(d, 'design_capacity') * _n(d, 'battery_level')) / 100;
    return true;
  }),
  _C('battery_level', {'design_capacity', 'cycle_charge'}, (d) {
    final cap = _n(d, 'design_capacity');
    if (cap == 0) return false;
    d['battery_level'] = pyRound(_n(d, 'cycle_charge') / cap * 100, 1);
    return true;
  }),
  _C('cell_count', {'cell_voltages'}, (d) {
    d['cell_count'] = _cells(d).length;
    return true;
  }),
  _C('cycle_capacity', {'voltage', 'cycle_charge'}, (d) {
    d['cycle_capacity'] = pyRound(_n(d, 'voltage') * _n(d, 'cycle_charge'), 3);
    return true;
  }),
  _C('cycles', {'design_capacity', 'total_charge'}, (d) {
    final cap = _n(d, 'design_capacity');
    if (cap == 0) return false;
    d['cycles'] = (_n(d, 'total_charge') / cap).floor();
    return true;
  }),
  _C('power', {'voltage', 'current'}, (d) {
    d['power'] = pyRound(_n(d, 'voltage') * _n(d, 'current'), 3);
    return true;
  }),
  _C('battery_charging', {'current'}, (d) {
    d['battery_charging'] = _n(d, 'current') > 0;
    return true;
  }),
  _C('runtime', {'current', 'cycle_charge'}, (d) {
    final current = _n(d, 'current');
    if (current >= 0) return false;
    d['runtime'] = (_n(d, 'cycle_charge') / current.abs() * _hrsToSecs)
        .truncate();
    return true;
  }),
  _C('temperature', {'temp_values'}, (d) {
    final t = d['temp_values'] as List?;
    if (t == null || t.isEmpty) return false;
    d['temperature'] = pyRound(fmean(t), 3);
    return true;
  }),
];

void _deriveFromPacks(BmsSample data) {
  final packs = (data[BmsKeys.packs] as List?)?.cast<BmsSample>();
  if (packs == null || packs.isEmpty) return;

  bool canCalc(String key) =>
      !data.containsKey(key) && packs.every((p) => p.containsKey(key));
  List<Object?> pvalues(String key) => [for (final p in packs) p[key] ?? 0];

  for (final pack in packs) {
    final cv = pack['cell_voltages'] as List?;
    if (cv == null || cv.isEmpty) continue;
    final c = cv.cast<num>();
    pack.putIfAbsent(
      'delta_voltage',
      () => pyRound(c.reduce(math.max) - c.reduce(math.min), 3),
    );
    pack.putIfAbsent('cell_count', () => c.length);
  }

  if (canCalc('cell_voltages')) {
    data['cell_voltages'] = [
      for (final p in packs) ...((p['cell_voltages'] as List?) ?? const []),
    ];
  }
  if (canCalc('cell_count') && pvalues('cell_count').toSet().length == 1) {
    data['cell_count'] = pvalues('cell_count').first;
  }

  num sum(List<Object?> v) => v.fold<num>(0, (a, b) => a + (b as num));
  final calculations = <String, Object? Function(List<Object?>)>{
    'battery_health': (v) => v.cast<num>().reduce(math.min),
    'current': sum,
    'cycle_charge': sum,
    'cycle_capacity': sum,
    'design_capacity': sum,
    'cycles': (v) => v.cast<num>().reduce(math.max),
    'delta_voltage': (v) => v.cast<num>().reduce(math.max),
  };
  for (final e in calculations.entries) {
    if (canCalc(e.key)) data[e.key] = e.value(pvalues(e.key));
  }

  final cap = data['design_capacity'] as num?;
  if (canCalc('battery_level') && cap != null && cap != 0) {
    final lev = pvalues('battery_level').cast<num>();
    final caps = pvalues('design_capacity').cast<num>();
    var s = 0.0;
    for (var i = 0; i < lev.length; i++) {
      s += lev[i] * caps[i];
    }
    data['battery_level'] = s / cap;
  }

  if (canCalc('voltage')) {
    data['voltage'] = pyRound(fmean(pvalues('voltage')), 3);
  }
}

/// Adds every value that can be derived and is not in [rawValues].
void deriveMissingFields(BmsSample data, [Set<String> rawValues = const {}]) {
  _deriveFromPacks(data);

  int order(_C a, _C b) {
    final c = a.requires.length.compareTo(b.requires.length);
    return c != 0 ? c : a.output.compareTo(b.output);
  }

  var pending = [
    for (final c in _registry)
      if (!rawValues.contains(c.output) && !data.containsKey(c.output)) c,
  ]..sort(order);

  while (pending.isNotEmpty) {
    var progress = false;
    final remaining = <_C>[];
    for (final calc in pending) {
      if (!calc.requires.every(data.containsKey)) {
        remaining.add(calc);
        continue;
      }
      progress |= calc.apply(data);
    }
    if (!progress) break;
    pending = remaining..sort(order);
  }
}
