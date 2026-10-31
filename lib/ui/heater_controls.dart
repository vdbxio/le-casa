// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/connection_manager.dart';
import '../decoders/decoded.dart';
import '../drivers/driver.dart';
import '../drivers/heater_driver.dart';
import '../drivers/heater_protocol.dart';

/// Power, mode and level or target for a diesel heater. Each change
/// connects, sends it, and reads the heater back, so the controls always
/// show what the heater accepted.
class HeaterControls extends StatefulWidget {
  final String id;
  final Decoded state;
  final ConnectionManager connections;

  const HeaterControls({
    super.key,
    required this.id,
    required this.state,
    required this.connections,
  });

  @override
  State<HeaterControls> createState() => _HeaterControlsState();
}

class _HeaterControlsState extends State<HeaterControls> {
  String? _sending;

  Object? _v(String label) =>
      widget.state.readings.where((r) => r.label == label).firstOrNull?.value;

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
        SnackBar(content: Text('Could not change the heater: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _sending != null;
    final on = _v(HeaterSetting.power) == true;
    final byTemp = _v(HeaterSetting.mode) == 'Temperature';
    final (setting, label, lo, hi, unit) = byTemp
        ? (HeaterSetting.target, 'Target', heaterMinTemp, heaterMaxTemp, ' °C')
        : (HeaterSetting.level, 'Level', heaterMinLevel, heaterMaxLevel, '');
    final value = _v(setting);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Heater controls', style: theme.textTheme.titleMedium),
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
          subtitle: const Text(
            'Turning off starts a few minutes of cooldown; the fan keeps '
            'running until the heater is cool.',
          ),
          value: on,
          onChanged: busy ? null : (v) => _send(HeaterSetting.power, v),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'Level', label: Text('Level')),
            ButtonSegment(value: 'Temperature', label: Text('Thermostat')),
          ],
          selected: {byTemp ? 'Temperature' : 'Level'},
          onSelectionChanged: busy
              ? null
              : (s) => _send(HeaterSetting.mode, s.first),
        ),
        if (value is int)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(label),
            subtitle: Text('$lo to $hi$unit'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.outlined(
                  onPressed: busy || value <= lo
                      ? null
                      : () => _send(setting, value - 1),
                  icon: const Icon(Icons.remove),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    '$value$unit',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton.outlined(
                  onPressed: busy || value >= hi
                      ? null
                      : () => _send(setting, value + 1),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
