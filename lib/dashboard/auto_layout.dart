// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'catalog.dart';
import 'layout.dart';

/// Builds the first-run dashboard from what the tablet can hear, so nobody
/// starts from a blank screen:
///
/// 1. Clock above solar (combined when there are several chargers).
/// 2. Batteries: monitor/BMS cards stacked.
/// 3. Weather, up to two climate sensors and appliances, then a chip row
///    with everything else (more sensors, buttons, this tablet).
///
/// Columns with nothing in them are left out. Devices that still need setup
/// are not placed; they stay in the card picker.
DashboardLayout autoLayout(List<CatalogEntry> entries) {
  final usable = [
    for (final e in entries)
      if (!e.needsSetup) e,
  ];
  List<CatalogEntry> role(CardRole r) => [
    for (final e in usable)
      if (e.role == r) e,
  ];

  final combined = usable.where((e) => e.spec.type == 'solar').toList();
  final solar = combined.isNotEmpty
      ? combined
      : role(CardRole.solar).take(1).toList();
  final extraSolar = combined.isNotEmpty
      ? const <CatalogEntry>[]
      : role(CardRole.solar).skip(1).toList();
  final batteries = role(CardRole.battery);
  final climate = role(CardRole.climate);
  final appliances = role(CardRole.appliance);

  final columns = <(Node, double)>[];

  // 1. Clock and solar.
  columns.add((
    solar.isEmpty
        ? Slot(const CardSpec('clock'))
        : Split(
            SplitAxis.vertical,
            [Slot(const CardSpec('clock')), Slot(solar.first.spec)],
            [0.62, 1.38],
          ),
    1.15,
  ));

  // 2. Batteries, two at most; any more go to the chip row.
  if (batteries.isNotEmpty) {
    final shown = batteries.take(2).toList();
    columns.add((
      shown.length == 1
          ? Slot(shown.single.spec)
          : Split(
              SplitAxis.vertical,
              [for (final b in shown) Slot(b.spec)],
              [1.25, 0.75],
            ),
      1.15,
    ));
  }

  // 3. Weather, climate, appliances and the chip row.
  final chips = <CardSpec>[
    for (final e in [
      ...climate.skip(2),
      ...extraSolar,
      ...batteries.skip(2),
      ...appliances.skip(1),
      ...role(CardRole.other),
    ])
      e.spec,
    const CardSpec('tablet'),
  ];
  final third = <(Node, double)>[
    (Slot(const CardSpec('weather')), 0.7),
    for (final c in climate.take(2)) (Slot(c.spec), 0.55),
    for (final a in appliances.take(1)) (Slot(a.spec), 0.45),
    (Slot(CardSpec('chips', items: chips)), 0.55),
  ];
  columns.add((
    Split(
      SplitAxis.vertical,
      [for (final t in third) t.$1],
      [for (final t in third) t.$2],
    ),
    0.9,
  ));

  return DashboardLayout(
    Split(
      SplitAxis.horizontal,
      [for (final c in columns) c.$1],
      [for (final c in columns) c.$2],
    ),
  );
}
