// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';
import '../platform/tablet.dart';
import '../ui/format.dart';
import '../ui/palette.dart';
import '../weather/weather.dart';
import 'cards/card_icons.dart';
import 'cards/card_model.dart';
import 'history.dart';
import 'layout.dart';

/// Everything cards read from.
class CardSources {
  final DeviceTracker tracker;
  final History? history;
  final TabletSensors? tablet;
  final WeatherService? weather;
  final DateTime Function() now;

  CardSources({
    required this.tracker,
    this.history,
    this.tablet,
    this.weather,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final Map<String, CardModel> _models = {};

  /// The same sources with nothing remembered, after live data changed.
  CardSources fresh() => CardSources(
    tracker: tracker,
    history: history,
    tablet: tablet,
    weather: weather,
    now: now,
  );

  /// [modelFor], remembered for as long as these sources live. The
  /// dashboard makes new sources when live data changes, so dragging a
  /// handle redraws cards without rebuilding every model each frame.
  CardModel model(CardSpec spec) {
    final m = _models.putIfAbsent(spec.key, () => modelFor(spec, this));
    if (spec.title == null && spec.icon == null) return m;
    return m.relabel(title: spec.title, icon: cardIcons[spec.icon]);
  }
}

/// How the first-run layout places a card.
enum CardRole {
  clock,
  solar,
  battery,
  climate,
  weather,
  appliance,
  other,
  tablet,
}

/// A card the user could put on the dashboard.
class CatalogEntry {
  final CardSpec spec;
  final String title;
  final String subtitle;
  final CardRole role;

  /// Recognised but not readable yet (needs a key, a connection...).
  final bool needsSetup;

  const CatalogEntry(
    this.spec,
    this.title,
    this.subtitle,
    this.role, {
    this.needsSetup = false,
  });
}

const _hiddenKinds = {DeviceKind.background, DeviceKind.improv};

/// Devices that have gone quiet for this long are drawn faded.
const staleAfter = Duration(minutes: 5);

/// Every card on offer right now: devices the tablet hears, then widgets.
List<CatalogEntry> catalog(CardSources s) {
  final out = <CatalogEntry>[];
  final solar = [
    for (final d in s.tracker.devices)
      if (d.view?.kind == DeviceKind.solar && d.view!.isReadable) d,
  ];
  if (solar.length >= 2) {
    out.add(
      CatalogEntry(
        const CardSpec('solar'),
        'Solar',
        '${solar.map(deviceName).join(' + ')} combined',
        CardRole.solar,
      ),
    );
  }
  for (final d in s.tracker.devices) {
    final v = d.view;
    if (v == null || _hiddenKinds.contains(v.kind)) continue;
    out.add(
      CatalogEntry(
        CardSpec.device(d.id, name: deviceName(d)),
        deviceName(d),
        v.model,
        switch (v.kind) {
          DeviceKind.solar => CardRole.solar,
          DeviceKind.battery => CardRole.battery,
          DeviceKind.climate => CardRole.climate,
          DeviceKind.appliance => CardRole.appliance,
          _ => CardRole.other,
        },
        needsSetup: !v.isReadable,
      ),
    );
  }
  out.addAll(const [
    CatalogEntry(CardSpec('clock'), 'Clock', 'Time and date', CardRole.clock),
    CatalogEntry(
      CardSpec('weather'),
      'Weather',
      'From the internet',
      CardRole.weather,
    ),
    CatalogEntry(
      CardSpec('tablet'),
      'This tablet',
      'Battery and light sensor',
      CardRole.tablet,
    ),
  ]);
  return out;
}

/// A readable name: the one the person gave it, if any. Otherwise the
/// advertised name where it is a real one (Victron
/// devices carry the name set in VictronConnect), otherwise the model plus
/// the end of the MAC so identical sensors can be told apart, and read the
/// same on every screen. iOS hides MACs, so there it is the MAC the device
/// sends in its broadcasts. Devices whose name carries a serial (Daly,
/// Alpicool) use the end of that instead, and the rest the end of iOS's own
/// id, which means something only on that one screen.
String deviceName(TrackedDevice d) => d.label ?? autoDeviceName(d);

/// The name Le'Casa makes up for [d], ignoring any the person gave it.
String autoDeviceName(TrackedDevice d) {
  final v = d.view;
  final name = d.latest.name;
  final isModuleId =
      name == null ||
      name == v?.info['module'] ||
      RegExp(r'^(LYWSD03MMC|ATC_|ATC|LYWSD|MJ_HT|BTHome|DL-|BYD-|AK1-|A1-)')
          .hasMatch(name);
  if (!isModuleId) return name;
  // Names like DL-694201312BA carry a serial that every screen sees.
  final serial = name != null && RegExp(r'^(DL-|BYD-|AK1-|A1-)').hasMatch(name);
  final tail = (serial ? name : d.mac ?? d.id).replaceAll(':', '');
  final suffix = tail.length >= 4 ? tail.substring(tail.length - 4) : tail;
  final base = switch (v?.kind) {
    DeviceKind.climate => 'Climate',
    DeviceKind.battery => 'Battery',
    _ => v?.model ?? 'Device',
  };
  return '$base · $suffix';
}

/// Builds what a card shows. Clocks and chip rows are drawn by their own
/// widgets; chip rows call this for each of their items.
CardModel modelFor(CardSpec spec, CardSources s) => switch (spec.type) {
  'device' => _device(spec.device!, s, spec.name),
  'solar' => _solarTotal(s),
  'tablet' => _tablet(s),
  'weather' => _weather(s),
  _ => CardModel(title: spec.type, icon: Icons.help_outline),
};

// ---------------------------------------------------------------- helpers

Reading? _r(Decoded d, String label) =>
    d.readings.where((r) => r.label == label).firstOrNull;

num? _n(Decoded d, String label) {
  final v = _r(d, label)?.value;
  return v is num ? v : null;
}

String _fmt(num? v, int digits) {
  if (v == null) return '–';
  final t = v.toStringAsFixed(digits);
  // -0.2 rounds to "-0"; show "0".
  return RegExp(r'^-0(\.0*)?$').hasMatch(t) ? t.substring(1) : t;
}

String _signed(num? v, int digits) =>
    v == null ? '–' : '${v > 0 ? '+' : ''}${v.toStringAsFixed(digits)}';

String _duration(num? minutes) {
  if (minutes == null) return '–';
  final m = minutes.round();
  return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
}

String _quiet(TrackedDevice d, DateTime now) =>
    'Not heard for ${ago(d.lastSeen, now).replaceAll(' ago', '')}';

// ---------------------------------------------------------------- devices

CardModel _device(String id, CardSources s, String? savedName) {
  final d = s.tracker[id];
  // Right after a restart a placed device may not have been heard, or its
  // first packet may not carry readings yet (Victron sends its name in a
  // separate scan response). Show the name it had when placed.
  CardModel waiting(String? name) => CardModel(
    title: savedName ?? name ?? 'Not found yet',
    icon: Icons.bluetooth_searching,
    note: 'Listening for this device…',
    pillLabel: 'listening',
    stale: true,
  );
  if (d == null) return waiting(null);
  final v = d.view;
  final name = deviceName(d);
  final now = s.now();
  final heard = d.polledAt != null && d.polled != null
      ? (d.polledAt!.isAfter(d.lastSeen) ? d.polledAt! : d.lastSeen)
      : d.lastSeen;
  final stale = now.difference(heard) > staleAfter;
  if (v == null) return waiting(name);
  if (!v.isReadable) {
    return CardModel(
      title: name,
      subtitle: v.model,
      icon: _iconFor(v.kind),
      tone: _toneFor(v.kind),
      note: v.needs,
      pillLabel: 'needs setup',
    );
  }
  final m = switch (v.kind) {
    DeviceKind.solar => _solar(d, v, name, s),
    DeviceKind.battery when _n(v, 'state of charge') != null => _battery(
      d,
      v,
      name,
      s,
    ),
    DeviceKind.climate => _climate(d, v, name, s),
    DeviceKind.appliance when v.protocol == 'Alpicool' => _fridge(
      d,
      v,
      name,
      s,
    ),
    DeviceKind.buttons || DeviceKind.leDevice => _buttons(d, v, name, s),
    _ => _generic(d, v, name, s),
  };
  if (!stale) return m;
  return CardModel(
    title: m.title,
    subtitle: m.subtitle,
    icon: m.icon,
    tone: m.tone,
    headline: m.headline,
    state: m.state,
    details: m.details,
    shares: m.shares,
    ring: m.ring,
    series: m.series,
    note: _quiet(d, now),
    stale: true,
    pillLabel: m.pillLabel,
  );
}

IconData _iconFor(DeviceKind k) => switch (k) {
  DeviceKind.solar => Icons.wb_sunny_outlined,
  DeviceKind.battery => Icons.battery_charging_full,
  DeviceKind.power => Icons.bolt,
  DeviceKind.climate => Icons.thermostat,
  DeviceKind.appliance => Icons.kitchen_outlined,
  DeviceKind.buttons || DeviceKind.leDevice => Icons.settings_remote_outlined,
  _ => Icons.sensors,
};

Tone _toneFor(DeviceKind k) => switch (k) {
  DeviceKind.solar => Tone.solar,
  DeviceKind.battery || DeviceKind.power => Tone.battery,
  DeviceKind.climate => Tone.climate,
  DeviceKind.appliance => Tone.heat,
  DeviceKind.buttons || DeviceKind.leDevice => Tone.accent,
  _ => Tone.neutral,
};

CardModel _solar(TrackedDevice d, Decoded v, String name, CardSources s) {
  final w = _n(v, 'solar power');
  final wh = _n(v, 'yield today');
  return CardModel(
    title: name,
    subtitle: v.model,
    icon: Icons.wb_sunny_outlined,
    tone: Tone.solar,
    headline: Metric('Solar', _fmt(w, 0), 'W'),
    state: _r(v, 'charge state')?.value?.toString(),
    details: [
      Metric('Battery', _fmt(_n(v, 'battery voltage'), 2), 'V'),
      Metric('Charging', _fmt(_n(v, 'battery current'), 1), 'A'),
      Metric('Today', _fmt(wh == null ? null : wh / 1000, 2), 'kWh'),
      if (_n(v, 'load current') case final l?) Metric('Load', _fmt(l, 1), 'A'),
    ],
    series: s.history?.of(History.key(d.id, 'solar power')),
  );
}

CardModel _solarTotal(CardSources s) {
  final chargers = [
    for (final d in s.tracker.devices)
      if (d.view?.kind == DeviceKind.solar && d.view!.isReadable) d,
  ];
  if (chargers.isEmpty) {
    return const CardModel(
      title: 'Solar',
      icon: Icons.wb_sunny_outlined,
      tone: Tone.solar,
      note: 'No solar chargers heard yet',
      stale: true,
    );
  }
  double sum(String label) =>
      chargers.fold(0.0, (a, d) => a + (_n(d.view!, label) ?? 0));
  final shares = [
    for (final d in chargers)
      Share(
        deviceName(d),
        (_n(d.view!, 'solar power') ?? 0).toDouble(),
        '${_fmt(_n(d.view!, 'solar power'), 0)} W',
        [
          '${_fmt(_n(d.view!, 'battery current'), 1)} A',
          '${_fmt((_n(d.view!, 'yield today') ?? 0) / 1000, 2)} kWh',
        ],
      ),
  ];
  final first = chargers.first.view!;
  return CardModel(
    title: 'Solar',
    subtitle: '${chargers.length} chargers',
    icon: Icons.wb_sunny_outlined,
    tone: Tone.solar,
    headline: Metric('Solar', _fmt(sum('solar power'), 0), 'W'),
    state: _r(first, 'charge state')?.value?.toString(),
    shares: shares,
    details: [
      Metric('Battery', _fmt(_n(first, 'battery voltage'), 2), 'V'),
      Metric('Charging', _fmt(sum('battery current'), 1), 'A'),
      Metric('Today', _fmt(sum('yield today') / 1000, 2), 'kWh'),
    ],
    series: s.history?.of(History.solarTotal),
  );
}

CardModel _battery(TrackedDevice d, Decoded v, String name, CardSources s) {
  final soc = _n(v, 'state of charge');
  // Daly and the aiobmsble drivers share reading labels.
  final isDaly = v.protocol.startsWith('Daly') || v.info.containsKey('bms');
  final current = _n(v, 'current');
  String? state;
  if (isDaly) {
    state = _r(v, 'state')?.value?.toString();
  } else if (current != null) {
    state = current > 0.2
        ? 'Charging'
        : current < -0.2
        ? 'Discharging'
        : 'Idle';
  }
  final temps = v.readings.where(
    (r) => r.label.startsWith('temperature') && r.value is num,
  );
  return CardModel(
    title: name,
    subtitle: v.model,
    icon: Icons.battery_charging_full,
    tone: Tone.battery,
    headline: Metric(
      'Charge',
      _fmt(soc, soc != null && soc % 1 != 0 ? 1 : 0),
      '%',
    ),
    state: state,
    ring: soc?.toDouble(),
    details: [
      Metric('Voltage', _fmt(_n(v, 'voltage'), 2), 'V'),
      Metric('Current', _signed(current, 1), 'A'),
      if (_n(v, 'power') ?? _power(_n(v, 'voltage'), current) case final w?)
        Metric('Power', _signed(w, 0), 'W'),
      if (isDaly) ...[
        if (_n(v, 'remaining') case final ah?)
          Metric('Remaining', _fmt(ah, 1), 'Ah'),
        if (_n(v, 'cell spread') case final mv?)
          Metric('Cell spread', _fmt(mv, 0), 'mV'),
        if (temps.isNotEmpty)
          Metric('Temp', _fmt(temps.first.value as num, 0), '°C'),
        if (_n(v, 'cycles') case final c?) Metric('Cycles', '$c'),
      ] else ...[
        if (_n(v, 'consumed') case final ah?) Metric('Used', _fmt(ah, 1), 'Ah'),
        if (_r(v, 'time to go') != null)
          Metric('Time to go', _duration(_n(v, 'time to go'))),
        if (_n(v, 'starter voltage') case final sv?)
          Metric('Starter', _fmt(sv, 2), 'V'),
      ],
    ],
    series: s.history?.of(History.key(d.id, 'state of charge')),
  );
}

/// Watts in or out, from the battery's own reading or volts times amps.
num? _power(num? volts, num? amps) =>
    volts == null || amps == null ? null : volts * amps;

CardModel _climate(TrackedDevice d, Decoded v, String name, CardSources s) {
  final t = _n(v, 'temperature');
  final h = _n(v, 'humidity');
  return CardModel(
    title: name,
    subtitle: v.model,
    icon: Icons.thermostat,
    tone: Tone.climate,
    headline: Metric('Temperature', _fmt(t, 1), '°C'),
    details: [
      Metric('Humidity', _fmt(h, 0), '%', '${_fmt(h, 0)}% humidity'),
      if (_n(v, 'battery') case final b?)
        Metric('Sensor battery', _fmt(b, 0), '%', null, true),
    ],
    series: s.history?.of(History.key(d.id, 'temperature')),
  );
}

CardModel _fridge(TrackedDevice d, Decoded v, String name, CardSources s) {
  Reading? r(String label) =>
      v.readings.where((x) => x.label == label).firstOrNull;
  final unit = r('temperature')?.unit ?? '°C';
  final on = r('power')?.value == true;
  final target = _n(v, 'target');
  final t2 = _n(v, 'temperature 2');
  return CardModel(
    title: name,
    subtitle: v.model,
    icon: Icons.kitchen_outlined,
    tone: Tone.cold,
    headline: Metric('Temperature', _fmt(_n(v, 'temperature'), 0), unit),
    state: on ? 'Cooling to ${_fmt(target, 0)} $unit' : 'Off',
    details: [
      if (t2 != null)
        Metric('Second zone', _fmt(t2, 0), unit, null)
      else
        Metric('Target', _fmt(target, 0), unit),
      if (r('mode')?.value case final String m) Metric('Mode', m),
      if (_n(v, 'battery voltage') case final b?)
        Metric('Supply', _fmt(b, 1), 'V', null, true),
    ],
    pillLabel: on ? 'on' : 'off',
    series: s.history?.of(History.key(d.id, 'temperature')),
  );
}

CardModel _buttons(TrackedDevice d, Decoded v, String name, CardSources s) {
  final last = d.events.firstOrNull;
  final now = s.now();
  final seen = switch (ago(d.lastSeen, now)) {
    'now' => 'Just now',
    final a => a,
  };
  return CardModel(
    title: name,
    subtitle: v.model,
    icon: Icons.settings_remote_outlined,
    tone: Tone.accent,
    headline: Metric('Last seen', seen),
    details: [
      Metric(
        'Last press',
        last == null
            ? 'None yet'
            : '${last.event.label} ${last.event.kind.replaceAll('_', ' ')}',
      ),
      if (last != null) Metric('Pressed', ago(last.at, now)),
      if (_n(v, 'battery') case final b?) Metric('Battery', _fmt(b, 0), '%'),
      if (_n(v, 'voltage') case final volts?)
        Metric('Battery', _fmt(volts, 2), 'V'),
    ],
    pillLabel: 'seen',
  );
}

CardModel _generic(TrackedDevice d, Decoded v, String name, CardSources s) {
  final nums = [
    for (final r in v.readings)
      if (r.value is num) r,
  ];
  final texts = [
    for (final r in v.readings)
      if (r.value is String) r,
  ];
  final head = nums.firstOrNull;
  String fmtR(Reading r) {
    final x = r.value as num;
    return x is int
        ? '$x'
        : _fmt(x, x.abs() >= 100 ? 0 : (x.abs() >= 10 ? 1 : 2));
  }

  return CardModel(
    title: name,
    subtitle: v.model,
    icon: _iconFor(v.kind),
    tone: _toneFor(v.kind),
    headline: head == null ? null : Metric(head.label, fmtR(head), head.unit),
    state: texts.firstOrNull?.value as String?,
    details: [
      for (final r in nums.skip(1).take(4))
        Metric(_cap(r.label), fmtR(r), r.unit),
    ],
    note: head == null && texts.isEmpty ? 'No readings yet' : null,
    series: head == null ? null : s.history?.of(History.key(d.id, head.label)),
  );
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

// ---------------------------------------------------------------- widgets

CardModel _tablet(CardSources s) {
  final t = s.tablet;
  if (t == null || !t.available || t.batteryPercent == null) {
    return const CardModel(
      title: 'This tablet',
      icon: Icons.tablet_android,
      note: 'Sensors not available on this device',
    );
  }
  return CardModel(
    title: 'This tablet',
    subtitle: 'Built-in sensors',
    icon: Icons.tablet_android,
    headline: Metric('Battery', '${t.batteryPercent}', '%'),
    state: t.charging == true ? 'Charging' : 'On battery',
    details: [if (t.lux != null) Metric('Light', _fmt(t.lux, 0), 'lx')],
    pillLabel: t.charging == true ? 'charging' : 'tablet',
  );
}

IconData weatherIcon(int code, {bool night = false}) => switch (code) {
  0 || 1 => night ? Icons.nightlight_outlined : Icons.wb_sunny_outlined,
  2 => night ? Icons.nights_stay_outlined : Icons.wb_cloudy_outlined,
  3 || 45 || 48 => Icons.cloud_outlined,
  51 ||
  53 ||
  55 ||
  56 ||
  57 ||
  61 ||
  63 ||
  65 ||
  66 ||
  67 ||
  80 ||
  81 ||
  82 => Icons.water_drop_outlined,
  71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
  95 || 96 || 99 => Icons.thunderstorm_outlined,
  _ => Icons.cloud_outlined,
};

CardModel _weather(CardSources s) {
  final w = s.weather;
  const offline = 'No forecast. Check the tablet is online.';
  if (w == null) {
    return const CardModel(
      title: 'Weather',
      icon: Icons.cloud_outlined,
      tone: Tone.climate,
      note: 'Set up where the forecast comes from',
      setup: 'Set up weather',
    );
  }
  final place = w.place;
  switch (w.status) {
    case WeatherStatus.noSource:
      return const CardModel(
        title: 'Weather',
        icon: Icons.cloud_outlined,
        tone: Tone.climate,
        note: 'Allow internet access or link the companion app',
        pillLabel: 'set up',
        setup: 'Set up weather',
      );
    case WeatherStatus.noPlace:
      return const CardModel(
        title: 'Weather',
        icon: Icons.cloud_outlined,
        tone: Tone.climate,
        note: 'Use the tablet\'s location or set one',
        pillLabel: 'set location',
        setup: 'Set location',
      );
    case WeatherStatus.noLocation:
      return const CardModel(
        title: 'Weather',
        icon: Icons.location_disabled_outlined,
        tone: Tone.climate,
        note: 'Could not find this tablet\'s location',
        pillLabel: 'no location',
        setup: 'Set location',
      );
    case WeatherStatus.loading:
      return CardModel(
        title: 'Weather',
        subtitle: place?.name ?? '',
        icon: Icons.cloud_outlined,
        tone: Tone.climate,
        note: 'Getting the forecast…',
      );
    case WeatherStatus.offline:
      return CardModel(
        title: 'Weather',
        subtitle: place?.name ?? '',
        icon: Icons.cloud_off_outlined,
        tone: Tone.climate,
        note: offline,
        pillLabel: 'offline',
      );
    case WeatherStatus.ok:
      final n = w.now!;
      final hourNow = s.now().hour;
      final night = hourNow < 6 || hourNow >= 20;
      return CardModel(
        title: 'Weather',
        subtitle: place?.name.split(',').first ?? '',
        icon: weatherIcon(n.code, night: night),
        tone: Tone.climate,
        headline: Metric('Now', _fmt(n.temperature, 0), '°C'),
        state: n.condition,
        details: [
          if (n.high != null && n.low != null)
            Metric(
              'High / low',
              '${_fmt(n.high, 0)}° / ${_fmt(n.low, 0)}',
              '°',
            ),
          if (n.rainChance != null) Metric('Rain', '${n.rainChance}', '%'),
          Metric('Wind', _fmt(n.wind, 0), 'km/h'),
          Metric('Feels like', _fmt(n.feelsLike, 0), '°'),
        ],
        hours: [
          for (final h in n.hours)
            HourCell(
              weatherIcon(h.code, night: h.time.hour < 6 || h.time.hour >= 20),
              '${_fmt(h.temperature, 0)}°',
              h.temperature,
            ),
        ],
        hoursLabel: 'Next ${n.hours.length} hours',
        pillLabel: n.condition,
      );
  }
}
