// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/device_tracker.dart';
import '../decoders/raw_advertisement.dart';
import 'device_page.dart';
import 'format.dart';

class DeviceCard extends StatelessWidget {
  final TrackedDevice device;
  const DeviceCard({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    final d = device.view;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stale =
        DateTime.now().difference(device.lastSeen) >
        const Duration(seconds: 30);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => DevicePage(id: device.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      device.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: stale
                            ? scheme.onSurface.withValues(alpha: 0.5)
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (d != null)
                    InfoBadge(d.protocol, color: scheme.primaryContainer),
                  const SizedBox(width: 8),
                  Rssi(device.latest.rssi),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (device.latest.name != null &&
                      device.latest.name != device.title)
                    device.latest.name!,
                  device.id,
                  ago(device.lastSeen),
                  '${device.packets} pkts',
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (d != null && d.readings.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final r in d.readings)
                      InfoBadge(
                        '${r.label}  ${r.display}',
                        color: scheme.surfaceContainerHighest,
                        big: true,
                      ),
                  ],
                ),
              ],
              if (d != null && d.needs != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.key, size: 16, color: scheme.tertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(d.needs!, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ],
              if (device.events.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final e in device.events.take(3))
                  Text(
                    '${clock(e.at)}  ${e.event}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
              if (d == null) ...[
                const SizedBox(height: 8),
                Text(
                  rawSummary(device.latest),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String rawSummary(RawAdvertisement a) {
    final parts = <String>[
      for (final e in a.manufacturerData.entries)
        'mfr 0x${e.key.toRadixString(16).padLeft(4, '0')}: ${hex(e.value)}',
      for (final e in a.serviceData.entries)
        'svc 0x${e.key.toRadixString(16).padLeft(4, '0')}: ${hex(e.value)}',
      if (a.serviceUuids.isNotEmpty)
        'uuids: ${a.serviceUuids.map((u) => u.toRadixString(16)).join(', ')}',
    ];
    return parts.isEmpty ? 'no payload (name/flags only)' : parts.join('\n');
  }
}

class InfoBadge extends StatelessWidget {
  final String text;
  final Color color;
  final bool big;
  const InfoBadge(
    this.text, {
    super.key,
    required this.color,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: big ? 10 : 8,
      vertical: big ? 6 : 3,
    ),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: big
          ? Theme.of(context).textTheme.bodyMedium
          : Theme.of(context).textTheme.labelSmall,
    ),
  );
}

class Rssi extends StatelessWidget {
  final int rssi;
  const Rssi(this.rssi, {super.key});

  @override
  Widget build(BuildContext context) {
    final bars = rssi > -60
        ? 4
        : rssi > -70
        ? 3
        : rssi > -80
        ? 2
        : rssi > -90
        ? 1
        : 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(switch (bars) {
          4 => Icons.signal_cellular_alt,
          3 => Icons.signal_cellular_alt,
          2 => Icons.signal_cellular_alt_2_bar,
          1 => Icons.signal_cellular_alt_1_bar,
          _ => Icons.signal_cellular_0_bar,
        }, size: 16),
        const SizedBox(width: 3),
        Text('$rssi', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
