// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../ble/device_tracker.dart';
import '../decoders/decoded.dart';
import 'group_tiles.dart';

/// Phase 0 screen: every broadcast the radio hears, decoded where we can.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
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
    if (s.scanning) {
      await s.stop();
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

  Widget _body(BuildContext context, bool scanning) {
    final tracker = AppServices.of(context).tracker;
    final theme = Theme.of(context);
    final groups = tracker.groups;
    final improv = groups.remove(DeviceKind.improv) ?? const [];
    final background = groups.remove(DeviceKind.background) ?? const [];
    final unknown = _onlyRecognised ? const <TrackedDevice>[] : tracker.unknown;

    if (groups.isEmpty &&
        unknown.isEmpty &&
        improv.isEmpty &&
        background.isEmpty) {
      return Center(
        child: Text(
          scanning ? 'Listening…' : 'Not scanning',
          style: theme.textTheme.titleMedium,
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        if (groups.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              delegate: SliverChildListDelegate([
                for (final e in groups.entries)
                  GroupTile(
                    key: ValueKey(e.key),
                    kind: e.key,
                    devices: e.value,
                  ),
              ]),
            ),
          ),
        if (unknown.isNotEmpty) ...[
          _SectionHeader('Unknown · ${unknown.length}'),
          SliverFixedExtentList(
            // Fixed height rows and first-heard order: nothing jumps around
            // while you are trying to tap it.
            itemExtent: 64,
            delegate: SliverChildBuilderDelegate(
              (context, i) =>
                  UnknownRow(key: ValueKey(unknown[i].id), device: unknown[i]),
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
            devices: improv,
          ),
        if (background.isNotEmpty)
          _CollapsedGroup(
            icon: Icons.phone_iphone,
            title: 'Phones & beacons · ${background.length}',
            subtitle:
                'Apple and similar background adverts. Nothing to read here.',
            devices: background,
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final scanning = services.scanner.scanning;
    final autostart = services.autostart;
    final state = autostart.state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            tooltip: _onlyRecognised
                ? 'Show unknown devices'
                : 'Hide unknown devices',
            icon: Icon(
              _onlyRecognised ? Icons.filter_alt : Icons.filter_alt_off,
            ),
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
            tooltip: scanning ? 'Pause' : 'Scan',
            icon: Icon(scanning ? Icons.pause_circle : Icons.play_circle),
            onPressed: state == BluetoothLowEnergyState.poweredOn
                ? _toggle
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(
            state: state,
            error: autostart.error,
            scanning: scanning,
            onAllow: autostart.askPermission,
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: services.tracker,
              builder: (context, _) => _body(context, scanning),
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
  final VoidCallback onAllow;
  const _StatusBar({
    required this.state,
    required this.error,
    required this.scanning,
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
      BluetoothLowEnergyState.poweredOn => ('Paused', scheme.secondary),
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
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

/// A group of recognised-but-uninteresting devices, folded away at the end
/// of the list so they do not crowd out the things worth tapping.
class _CollapsedGroup extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<TrackedDevice> devices;

  const _CollapsedGroup({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.devices,
  });

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        children: [
          for (final d in devices) UnknownRow(key: ValueKey(d.id), device: d),
        ],
      ),
    ),
  );
}
