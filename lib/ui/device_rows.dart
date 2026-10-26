// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/device_tracker.dart';
import '../dashboard/catalog.dart' show deviceName;
import '../decoders/decoded.dart';
import 'device_card.dart';
import 'format.dart';

IconData iconFor(DeviceKind k) => switch (k) {
  DeviceKind.climate => Icons.thermostat,
  DeviceKind.solar => Icons.solar_power,
  DeviceKind.battery => Icons.battery_charging_full,
  DeviceKind.power => Icons.electrical_services,
  DeviceKind.appliance => Icons.kitchen,
  DeviceKind.buttons => Icons.radio_button_checked,
  DeviceKind.leDevice => Icons.home,
  DeviceKind.sensor => Icons.sensors,
  DeviceKind.needsSetup => Icons.key,
  DeviceKind.improv => Icons.wifi_tethering,
  DeviceKind.background => Icons.phone_iphone,
};

/// The one reading that best sums a device up in a list row.
Reading? primaryReading(Decoded d) {
  const preferred = [
    'state of charge',
    'solar power',
    'temperature',
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

/// Height of every device row. Fixed, and rows stay in first-heard order,
/// so nothing jumps around while you are trying to tap it.
const deviceRowHeight = 64.0;

/// One device in the devices list: its name, what it is, and the reading
/// that sums it up. Devices we cannot decode show their raw payload.
class DeviceRow extends StatelessWidget {
  final TrackedDevice device;
  final bool selected;
  final VoidCallback onTap;
  const DeviceRow({
    super.key,
    required this.device,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = device.latest;
    final d = device.view;
    final stale =
        DateTime.now().difference(device.lastSeen) >
        const Duration(seconds: 30);
    final r = d == null ? null : primaryReading(d);
    final title = d == null ? a.name ?? device.id : deviceName(device);
    final subtitle = d == null
        ? '${ago(device.lastSeen)} · ${rawSummary(a).split('\n').first}'
        : d.needs != null
        ? 'Needs setup'
        : {
            if (a.name != null && a.name != title) a.name,
            d.model,
            d.protocol,
          }.join(' · ');
    return SizedBox(
      height: deviceRowHeight,
      child: ListTile(
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        onTap: onTap,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: d == null ? 'monospace' : null,
            color: d?.needs != null ? scheme.tertiary : null,
          ),
        ),
        trailing: d == null
            ? Rssi(a.rssi)
            : Text(
                r?.display ?? '–',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: stale ? scheme.onSurface.withValues(alpha: 0.4) : null,
                ),
              ),
      ),
    );
  }
}
