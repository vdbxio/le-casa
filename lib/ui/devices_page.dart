// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';
import '../settings/device_stage.dart';
import '../settings/sidebar.dart';
import 'device_page.dart';
import 'device_rows.dart';

/// Settings › Devices: everything heard, grouped by kind. A device opens
/// its own page in the settings panel, with its card large on the dimmed
/// dashboard beside it.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  Timer? _tick;
  bool _onlyRecognised = false;

  @override
  void initState() {
    super.initState();
    // Repaint "3s ago" labels once a second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  Future<void> _toggle() async {
    final s = AppServices.of(context).scanner;
    if (!s.paused) {
      await s.pause();
    } else {
      await AppServices.of(context).autostart.startScan();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _open(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SidebarStage(
          stage: DeviceStage(id: id),
          child: DevicePage(id: id),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final tracker = AppServices.of(context).tracker;
    final theme = Theme.of(context);
    final groups = tracker.groups;
    final improv = groups.remove(DeviceKind.improv) ?? const [];
    final background = groups.remove(DeviceKind.background) ?? const [];
    final unknown = _onlyRecognised ? const <TrackedDevice>[] : tracker.unknown;
    final scanning = AppServices.of(context).scanner.scanning;
    final connections = AppServices.of(context).connections;

    Widget row(TrackedDevice d) => DeviceRow(
      key: ValueKey(d.id),
      device: d,
      selected: false,
      connecting:
          connections.enabled &&
          connections[d.id] != null &&
          connections.allows(d.id),
      onTap: () => _open(context, d.id),
    );

    final nothing =
        groups.isEmpty &&
        unknown.isEmpty &&
        improv.isEmpty &&
        background.isEmpty;

    return CustomScrollView(
      slivers: [
        if (nothing)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  scanning ? 'Listening for devices…' : 'Not scanning',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
          ),
        for (final e in groups.entries) ...[
          _SectionHeader(
            '${e.key.label} · ${e.value.length}',
            icon: iconFor(e.key),
          ),
          SliverList.list(children: [for (final d in e.value) row(d)]),
        ],
        if (unknown.isNotEmpty) ...[
          _SectionHeader(
            'Unknown · ${unknown.length}',
            icon: Icons.help_outline,
          ),
          SliverFixedExtentList(
            itemExtent: deviceRowHeight,
            delegate: SliverChildBuilderDelegate(
              (context, i) => row(unknown[i]),
              childCount: unknown.length,
            ),
          ),
        ],
        if (improv.isNotEmpty)
          _CollapsedGroup(
            icon: Icons.wifi_tethering,
            title: 'Improv setup · ${improv.length}',
            subtitle:
                'Devices advertising Improv Wi-Fi setup (ESPHome and similar)',
            children: [for (final d in improv) row(d)],
          ),
        if (background.isNotEmpty)
          _CollapsedGroup(
            icon: Icons.phone_iphone,
            title: 'Phones & beacons · ${background.length}',
            subtitle:
                'Apple and similar background adverts. Nothing to read here.',
            children: [for (final d in background) row(d)],
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  List<Widget> _actions(AppServices services) {
    final paused = services.scanner.paused;
    final state = services.autostart.state;
    return [
      IconButton(
        tooltip: _onlyRecognised
            ? 'Show unknown devices'
            : 'Hide unknown devices',
        icon: Icon(_onlyRecognised ? Icons.filter_alt : Icons.filter_alt_off),
        onPressed: () => setState(() => _onlyRecognised = !_onlyRecognised),
      ),
      ListenableBuilder(
        listenable: services.connections,
        builder: (context, _) {
          final c = services.connections;
          return IconButton(
            tooltip: c.enabled
                ? 'Pause connections (stop polling Daly / Xiaomi)'
                : 'Resume connections',
            icon: Icon(
              c.enabled ? Icons.link : Icons.link_off,
              color: c.busyId != null
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onPressed: () => c.setEnabled(!c.enabled),
          );
        },
      ),
      IconButton(
        tooltip: 'Clear list',
        icon: const Icon(Icons.delete_sweep),
        onPressed: services.tracker.clear,
      ),
      IconButton(
        tooltip: paused ? 'Scan' : 'Pause',
        icon: Icon(paused ? Icons.play_circle : Icons.pause_circle),
        onPressed: state == BluetoothLowEnergyState.poweredOn ? _toggle : null,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final autostart = services.autostart;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices'), actions: _actions(services)),
      body: Column(
        children: [
          _StatusBar(
            state: autostart.state,
            error: autostart.error,
            scanning: services.scanner.scanning,
            paused: services.scanner.paused,
            onAllow: autostart.askPermission,
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: services.tracker,
              builder: (context, _) => _list(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final BluetoothLowEnergyState state;
  final String? error;
  final bool scanning;
  final bool paused;
  final VoidCallback onAllow;
  const _StatusBar({
    required this.state,
    required this.error,
    required this.scanning,
    required this.paused,
    required this.onAllow,
  });

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (state) {
      BluetoothLowEnergyState.poweredOn when scanning => (
        'Scanning',
        scheme.primary,
      ),
      BluetoothLowEnergyState.poweredOn when paused => (
        'Paused',
        scheme.secondary,
      ),
      // Android stops the scan while a connection opens.
      BluetoothLowEnergyState.poweredOn => ('Connecting…', scheme.primary),
      BluetoothLowEnergyState.poweredOff => ('Bluetooth is off', scheme.error),
      BluetoothLowEnergyState.unauthorized => (
        'Needs Bluetooth permission',
        scheme.error,
      ),
      BluetoothLowEnergyState.unsupported => (
        'No Bluetooth LE on this device',
        scheme.error,
      ),
      BluetoothLowEnergyState.unknown => (
        'Starting Bluetooth…',
        scheme.secondary,
      ),
    };
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: ListenableBuilder(
                listenable: services.tracker,
                builder: (context, _) => Text(
                  error ??
                      '$label · ${services.tracker.devices.length} devices · '
                          '${services.tracker.totalPackets} packets',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            if (state == BluetoothLowEnergyState.unauthorized) ...[
              TextButton(onPressed: onAllow, child: const Text('Allow')),
              TextButton(
                onPressed: services.scanner.showAppSettings,
                child: const Text('Settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  final IconData icon;
  const _SectionHeader(this.text, {required this.icon});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              text,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// A group of recognised-but-uninteresting devices, folded away at the end
/// of the list so they do not crowd out the things worth tapping.
class _CollapsedGroup extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  const _CollapsedGroup({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        children: children,
      ),
    ),
  );
}
