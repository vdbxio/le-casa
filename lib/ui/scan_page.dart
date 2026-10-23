// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../ble/device_tracker.dart';
import '../decoders/raw_advertisement.dart';
import 'device_page.dart';
import 'format.dart';

/// Phase 0 screen: every broadcast the radio hears, decoded where we can.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  BluetoothLowEnergyState _state = BluetoothLowEnergyState.unknown;
  StreamSubscription? _stateSub;
  Timer? _tick;
  bool _onlyRecognised = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Repaint "3s ago" labels once a second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final s = AppServices.of(context).scanner;
    _state = s.state;
    _stateSub = s.stateChanges.listen((st) {
      setState(() => _state = st);
      if (st == BluetoothLowEnergyState.poweredOn) _start();
    });
    if (_state == BluetoothLowEnergyState.unauthorized) {
      final ok = await s.authorize();
      if (!ok) {
        setState(() => _error = 'Bluetooth permission was not granted.');
        return;
      }
      _state = s.state;
    }
    if (_state == BluetoothLowEnergyState.poweredOn) _start();
    setState(() {});
  }

  Future<void> _start() async {
    final s = AppServices.of(context).scanner;
    try {
      await s.start();
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = 'Could not start scanning: $e');
    }
  }

  Future<void> _toggle() async {
    final s = AppServices.of(context).scanner;
    if (s.scanning) {
      await s.stop();
    } else {
      await _start();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final scanning = services.scanner.scanning;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Le'Casa · Bluetooth test"),
        actions: [
          IconButton(
            tooltip: _onlyRecognised
                ? 'Show everything'
                : 'Only recognised devices',
            icon: Icon(
              _onlyRecognised ? Icons.filter_alt : Icons.filter_alt_off,
            ),
            onPressed: () => setState(() => _onlyRecognised = !_onlyRecognised),
          ),
          IconButton(
            tooltip: 'Clear list',
            icon: const Icon(Icons.delete_sweep),
            onPressed: services.tracker.clear,
          ),
          IconButton(
            tooltip: scanning ? 'Pause' : 'Scan',
            icon: Icon(scanning ? Icons.pause_circle : Icons.play_circle),
            onPressed: _state == BluetoothLowEnergyState.poweredOn
                ? _toggle
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(state: _state, error: _error, scanning: scanning),
          Expanded(
            child: ListenableBuilder(
              listenable: services.tracker,
              builder: (context, _) {
                var devices = services.tracker.devices;
                if (_onlyRecognised) {
                  devices = devices.where((d) => d.decoded != null).toList();
                }
                // Recognised first, then strongest signal.
                devices.sort((a, b) {
                  final ra = a.decoded == null ? 1 : 0;
                  final rb = b.decoded == null ? 1 : 0;
                  if (ra != rb) return ra - rb;
                  return b.latest.rssi.compareTo(a.latest.rssi);
                });
                if (devices.isEmpty) {
                  return Center(
                    child: Text(
                      scanning ? 'Listening…' : 'Not scanning',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: devices.length,
                  itemBuilder: (context, i) => _DeviceCard(device: devices[i]),
                );
              },
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
  const _StatusBar({
    required this.state,
    required this.error,
    required this.scanning,
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
            if (state == BluetoothLowEnergyState.unauthorized)
              TextButton(
                onPressed: services.scanner.showAppSettings,
                child: const Text('Settings'),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final TrackedDevice device;
  const _DeviceCard({required this.device});

  @override
  Widget build(BuildContext context) {
    final d = device.decoded;
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
                    _Badge(d.protocol, color: scheme.primaryContainer),
                  const SizedBox(width: 8),
                  _Rssi(device.latest.rssi),
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
                      _Badge(
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
                  _rawSummary(device.latest),
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

  static String _rawSummary(RawAdvertisement a) {
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

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final bool big;
  const _Badge(this.text, {required this.color, this.big = false});

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

class _Rssi extends StatelessWidget {
  final int rssi;
  const _Rssi(this.rssi);

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
