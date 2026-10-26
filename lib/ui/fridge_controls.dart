// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/connection_manager.dart';
import '../decoders/decoded.dart';
import '../drivers/alpicool_driver.dart';
import '../drivers/alpicool_protocol.dart';
import '../drivers/driver.dart';

/// Power, target, mode, lock and battery protection for a fridge. Each
/// change connects, sends it, and reads the fridge back, so the controls
/// always show what the fridge accepted.
class FridgeControls extends StatefulWidget {
  final String id;
  final Decoded state;
  final ConnectionManager connections;

  const FridgeControls({
    super.key,
    required this.id,
    required this.state,
    required this.connections,
  });

  @override
  State<FridgeControls> createState() => _FridgeControlsState();
}

class _FridgeControlsState extends State<FridgeControls> {
  String? _sending;

  Object? _v(String label) =>
      widget.state.readings.where((r) => r.label == label).firstOrNull?.value;

  String get _unit =>
      widget.state.readings
          .where((r) => r.label == 'temperature')
          .firstOrNull
          ?.unit ??
      '°C';

  (int, int)? get _range {
    final m = RegExp(r'^(-?\d+) to (-?\d+)')
        .firstMatch(widget.state.info['settable range'] ?? '');
    return m == null ? null : (int.parse(m[1]!), int.parse(m[2]!));
  }

  Future<void> _send(String setting, Object value) async {
    setState(() => _sending = setting);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.connections.control(
        widget.id,
        DeviceCommand(setting, value),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not change the fridge: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _sending != null;
    final on = _v(FridgeSetting.power) == true;
    final range = _range;
    Widget target(String setting, String label) {
      final t = _v(setting);
      if (t is! int) return const SizedBox.shrink();
      bool ok(int x) => range == null || (x >= range.$1 && x <= range.$2);
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: range == null
            ? null
            : Text('${range.$1} to ${range.$2} $_unit'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.outlined(
              onPressed: busy || !ok(t - 1)
                  ? null
                  : () => _send(setting, t - 1),
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 72,
              child: Text(
                '$t $_unit',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton.outlined(
              onPressed: busy || !ok(t + 1)
                  ? null
                  : () => _send(setting, t + 1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      );
    }

    final protection = _v(FridgeSetting.batteryProtection);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Fridge controls', style: theme.textTheme.titleMedium),
            const SizedBox(width: 12),
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Power'),
          value: on,
          onChanged: busy ? null : (v) => _send(FridgeSetting.power, v),
        ),
        target(FridgeSetting.target, 'Target'),
        if (_v(FridgeSetting.target2) != null)
          target(FridgeSetting.target2, 'Second zone target'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Eco mode'),
          subtitle: const Text('Slower, quieter cooling'),
          value: _v('mode') == 'Eco',
          onChanged: busy ? null : (v) => _send(FridgeSetting.eco, v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lock the fridge\'s buttons'),
          value: _v(FridgeSetting.locked) == true,
          onChanged: busy ? null : (v) => _send(FridgeSetting.locked, v),
        ),
        const SizedBox(height: 8),
        Text('Battery protection', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 4),
        SegmentedButton<int>(
          segments: [
            for (final (i, l) in alpicoolBatteryProtection.indexed)
              ButtonSegment(value: i, label: Text(l)),
          ],
          selected: {
            if (protection is String)
              alpicoolBatteryProtection.indexOf(protection),
          },
          emptySelectionAllowed: true,
          onSelectionChanged: busy
              ? null
              : (s) {
                  if (s.isNotEmpty) {
                    _send(FridgeSetting.batteryProtection, s.first);
                  }
                },
        ),
        const SizedBox(height: 4),
        Text(
          'Stops the compressor when the supply drops below 9.6, 10.1 or '
          '11.1 V on a 12 V system (21.3, 22.3 or 24.3 V on 24 V). Use High '
          'on a starter battery.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
