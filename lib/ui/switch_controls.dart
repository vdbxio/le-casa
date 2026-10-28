// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ble/connection_manager.dart';
import '../decoders/decoded.dart';
import '../drivers/driver.dart';
import '../drivers/switchbot_driver.dart';

/// On/off for a plug or switch. The switch shows what the device last
/// broadcast, so it flips over once the device has actually switched.
class SwitchControls extends StatefulWidget {
  final String id;
  final Decoded state;
  final ConnectionManager connections;

  const SwitchControls({
    super.key,
    required this.id,
    required this.state,
    required this.connections,
  });

  @override
  State<SwitchControls> createState() => _SwitchControlsState();
}

class _SwitchControlsState extends State<SwitchControls> {
  bool _sending = false;

  Future<void> _send(bool on) async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.connections.control(
        widget.id,
        DeviceCommand(SwitchSetting.on, on),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not switch it ${on ? 'on' : 'off'}: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.state.readings
        .where((r) => r.label == SwitchSetting.on)
        .firstOrNull
        ?.value;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Power'),
      subtitle: _sending ? const Text('Switching…') : null,
      value: on == true,
      onChanged: _sending || on is! bool ? null : _send,
    );
  }
}
