// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';
import 'device_card.dart';
import 'device_page.dart';
import 'format.dart';
import 'group_page.dart';

IconData iconFor(DeviceKind k) => switch (k) {
  DeviceKind.climate => Icons.thermostat,
  DeviceKind.solar => Icons.solar_power,
  DeviceKind.battery => Icons.battery_charging_full,
  DeviceKind.power => Icons.electrical_services,
  DeviceKind.buttons => Icons.radio_button_checked,
  DeviceKind.leDevice => Icons.home,
  DeviceKind.sensor => Icons.sensors,
  DeviceKind.needsSetup => Icons.key,
  DeviceKind.improv => Icons.wifi_tethering,
};

/// The one reading that best sums a device up on a small tile.
Reading? primaryReading(Decoded d) {
  const preferred = [
    'temperature',
    'solar power',
    'state of charge',
    'battery voltage',
    'voltage',
    'battery',
  ];
  for (final label in preferred) {
    for (final r in d.readings) {
      if (r.label == label) return r;
    }
  }
  return d.readings.isEmpty ? null : d.readings.first;
}

/// Square tile for one group of recognised devices. Tapping it opens the
/// group; the tile itself shows a count and a line per device.
class GroupTile extends StatelessWidget {
  final DeviceKind kind;
  final List<TrackedDevice> devices;
  const GroupTile({super.key, required this.kind, required this.devices});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final needs = devices.where((d) => d.decoded?.needs != null).length;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => GroupPage(kind: kind))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(iconFor(kind), color: scheme.primary),
                  const Spacer(),
                  Text(
                    '${devices.length}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(kind.label, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              // Lines that do not fit a small tile are clipped, not
              // overflowed; the group page shows everything.
              Expanded(
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final d in devices.take(6)) _line(context, d),
                    ],
                  ),
                ),
              ),
              if (needs > 0)
                Text(
                  needs == 1 ? '1 needs setup' : '$needs need setup',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.tertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, TrackedDevice d) {
    final theme = Theme.of(context);
    final stale =
        DateTime.now().difference(d.lastSeen) > const Duration(seconds: 30);
    final r = d.decoded == null ? null : primaryReading(d.decoded!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              d.latest.name ?? d.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            r?.display ?? '–',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: stale
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// One fixed-height row for a device we cannot decode (yet).
class UnknownRow extends StatelessWidget {
  final TrackedDevice device;
  const UnknownRow({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = device.latest;
    final payload = DeviceCard.rawSummary(a).split('\n').first;
    return ListTile(
      dense: true,
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => DevicePage(id: device.id))),
      title: Text(
        a.name ?? device.decoded?.model ?? device.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${ago(device.lastSeen)} · $payload',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
      trailing: Rssi(a.rssi),
    );
  }
}
