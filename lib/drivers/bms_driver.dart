// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Runs the BMS drivers ported from aiobmsble (lib/bms/) as one
// GattDriver: picks the BMS type from the advertisement, keeps one BMS
// object per battery so what it learned (protocol version, device ID)
// survives between connections, reads a sample and turns it into
// readings with the same labels the Daly driver uses.

import 'package:flutter/foundation.dart';

import '../ble/gatt_session.dart';
import '../bms/base_bms.dart';
import '../bms/registry.dart';
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'driver.dart';

/// Looks up the PIN or password stored for a device id.
typedef SecretProvider = String? Function(String id);

String? noSecrets(String id) => null;

class BmsDriver implements GattDriver {
  final SecretProvider secretFor;

  /// Module names left to other drivers, e.g. Daly, which has its own.
  final Set<String> exclude;

  BmsDriver({this.secretFor = noSecrets, this.exclude = const {}});

  final Map<String, _Entry> _bms = {};

  @override
  String get name => 'Battery (BMS)';

  @override
  Duration get interval => const Duration(seconds: 30);

  /// One request can take up to about ten seconds with retries, and some
  /// BMSs need several, plus a device info read the first time.
  @override
  Duration get timeout => const Duration(seconds: 45);

  BmsSpec? specFor(RawAdvertisement adv) {
    final s = bmsSpecFor(adv);
    return s == null || exclude.contains(s.module) ? null : s;
  }

  @override
  bool matches(RawAdvertisement adv) => specFor(adv) != null;

  @override
  Future<Decoded> read(GattSession session, RawAdvertisement adv) async {
    final secret = secretFor(adv.id) ?? '';
    var e = _bms[adv.id];
    final spec = e?.spec ?? specFor(adv);
    if (spec == null) {
      throw UnsupportedDeviceException('No BMS driver for ${adv.name}');
    }
    if (e == null || e.secret != secret) {
      e = _Entry(
        spec,
        secret,
        spec.create(
          BmsDevice(adv.name ?? '', adv.macString ?? adv.id),
          BmsConfig(secret: secret),
        ),
      );
      _bms[adv.id] = e;
    }
    final bms = e.bms..attach(session);
    try {
      final sample = await bms.update();
      if (e.deviceInfo == null) {
        try {
          e.deviceInfo = await bms.deviceInfo();
        } catch (err) {
          debugPrint('bms: ${adv.id}: device info failed: $err');
          e.deviceInfo = const {};
        }
      }
      return bmsSampleToDecoded(
        spec,
        sample,
        module: adv.name ?? adv.id,
        deviceInfo: e.deviceInfo!,
      );
    } finally {
      await bms.disconnect();
    }
  }
}

class _Entry {
  final BmsSpec spec;
  final String secret;
  final BaseBms bms;
  BmsInfo? deviceInfo;
  _Entry(this.spec, this.secret, this.bms);
}

double? _d(Object? v) => v is num ? v.toDouble() : null;

double? _round(Object? v, int places) {
  final d = _d(v);
  return d == null ? null : double.parse(d.toStringAsFixed(places));
}

const _tempLabels = {
  TempType.mosfet: 'MOSFET temperature',
  TempType.pcb: 'board temperature',
  TempType.heater: 'heater temperature',
  TempType.balancer: 'balancer temperature',
  TempType.ambient: 'ambient temperature',
  TempType.cellMax: 'highest cell temperature',
  TempType.cellMin: 'lowest cell temperature',
};

List<Reading> _temperatures(Object? values) {
  final list = (values as List?) ?? const [];
  final general = <double>[];
  final special = <TempType, List<double>>{};
  for (final t in list) {
    final (v, type) = t is TempSensor
        ? (t.value, t.type)
        : ((t as num).toDouble(), TempType.generic);
    if (_tempLabels.containsKey(type)) {
      (special[type] ??= []).add(v);
    } else {
      general.add(v);
    }
  }
  return [
    for (var i = 0; i < general.length; i++)
      Reading(
        general.length == 1 ? 'temperature' : 'temperature ${i + 1}',
        _round(general[i], 1),
        '°C',
      ),
    for (final MapEntry(key: type, value: vs) in special.entries)
      for (var i = 0; i < vs.length; i++)
        Reading(
          vs.length == 1 ? _tempLabels[type]! : '${_tempLabels[type]} ${i + 1}',
          _round(vs[i], 1),
          '°C',
        ),
  ];
}

/// Problem codes can be wider than 63 bits, so they arrive as BigInt or as
/// an int with the top bit set.
String _hexCode(Object code) => switch (code) {
  BigInt b => b.toRadixString(16),
  int i => BigInt.from(i).toUnsigned(64).toRadixString(16),
  _ => '$code',
};

String _state(BmsSample s) {
  final charging = s['battery_charging'];
  final current = _d(s['current']) ?? 0;
  if (charging == true || current > 0.05) return 'charging';
  if (current < -0.05) return 'discharging';
  return 'idle';
}

/// Readings for one BMS sample, labelled like the Daly driver's so the
/// battery card and history treat every BMS the same.
Decoded bmsSampleToDecoded(
  BmsSpec spec,
  BmsSample s, {
  required String module,
  BmsInfo deviceInfo = const {},
}) {
  final cells = ((s['cell_voltages'] as List?) ?? const []).cast<num>();
  final delta = _d(s['delta_voltage']);
  final runtime = _d(s['runtime']);
  final problemCode = s['problem_code'];
  final hasProblemCode =
      problemCode != null && problemCode != 0 && problemCode != false;
  final packs = ((s['packs'] as List?) ?? const []).cast<BmsSample>();
  final balancer = s['balancer'];
  final mode = s['battery_mode'];
  final readings = <Reading>[
    if (s.containsKey('battery_level'))
      Reading('state of charge', _round(s['battery_level'], 1), '%'),
    if (s.containsKey('voltage'))
      Reading('voltage', _round(s['voltage'], 3), 'V'),
    if (s.containsKey('current'))
      Reading('current', _round(s['current'], 3), 'A'),
    if (s.containsKey('power')) Reading('power', _round(s['power'], 1), 'W'),
    if (s.containsKey('current') || s.containsKey('battery_charging'))
      Reading('state', _state(s)),
    if (s.containsKey('cycle_charge'))
      Reading('remaining', _round(s['cycle_charge'], 2), 'Ah'),
    if (s.containsKey('cycle_capacity'))
      Reading('energy', _round(s['cycle_capacity'], 0), 'Wh'),
    if (s.containsKey('design_capacity'))
      Reading('capacity', s['design_capacity'], 'Ah'),
    if (runtime != null) Reading('time to go', (runtime / 60).round(), 'min'),
    if (s.containsKey('battery_health'))
      Reading('health', _round(s['battery_health'], 1), '%'),
    ..._temperatures(s['temp_values']),
    for (var i = 0; i < cells.length; i++)
      Reading('cell ${i + 1}', _round(cells[i], 3), 'V'),
    if (delta != null) Reading('cell spread', (delta * 1000).round(), 'mV'),
    if (s.containsKey('cycles')) Reading('cycles', s['cycles']),
    if (s['chrg_mosfet'] is bool) Reading('charge MOSFET', s['chrg_mosfet']),
    if (s['dischrg_mosfet'] is bool)
      Reading('discharge MOSFET', s['dischrg_mosfet']),
    if (balancer != null)
      Reading('balancing', balancer is bool ? balancer : balancer != 0),
    if (s.containsKey('balance_current'))
      Reading('balance current', _round(s['balance_current'], 3), 'A'),
    if (s['heater'] is bool) Reading('heater', s['heater']),
    if (s.containsKey('heater_current'))
      Reading('heater current', _round(s['heater_current'], 3), 'A'),
    if (mode is BmsMode && mode != BmsMode.unknown)
      Reading('charge mode', mode.name),
    if (s['problem'] == true)
      Reading(
        'alarm',
        hasProblemCode
            ? 'code 0x${_hexCode(problemCode)}'
            : 'value out of range',
      ),
    if (packs.isNotEmpty) Reading('packs', packs.length),
    for (var i = 0; i < packs.length; i++) ...[
      if (packs[i].containsKey('voltage'))
        Reading('pack ${i + 1} voltage', _round(packs[i]['voltage'], 2), 'V'),
      if (packs[i].containsKey('current'))
        Reading('pack ${i + 1} current', _round(packs[i]['current'], 2), 'A'),
      if (packs[i].containsKey('battery_level'))
        Reading(
          'pack ${i + 1} state of charge',
          _round(packs[i]['battery_level'], 1),
          '%',
        ),
    ],
  ];
  final m = deviceInfo['model'];
  return Decoded(
    protocol: '${spec.info['manufacturer']} BMS',
    kind: DeviceKind.battery,
    model: [
      m != null && m.isNotEmpty ? m : spec.title,
      if (cells.isNotEmpty) '(${cells.length}S)',
    ].join(' '),
    readings: readings,
    info: {
      'module': module,
      'bms': spec.module,
      'source': 'connection',
      for (final e in deviceInfo.entries)
        if (e.value.isNotEmpty && e.key != 'model')
          e.key.replaceAll('_', ' '): e.value,
    },
  );
}
