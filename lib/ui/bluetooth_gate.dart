// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

import '../app.dart';

/// Dims the whole app and says why when Bluetooth is off or not allowed:
/// every reading on screen is then stale, and nothing can be controlled.
/// Clears by itself once Bluetooth is back.
class BluetoothGate extends StatelessWidget {
  final Widget child;
  const BluetoothGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final autostart = services.autostart;
    return ListenableBuilder(
      listenable: autostart,
      builder: (context, _) {
        final problem = switch (autostart.state) {
          BluetoothLowEnergyState.poweredOff => (
            'Bluetooth is off',
            'Le\'Casa reads and controls everything over Bluetooth. Turn it '
                'on in the system settings or quick settings, and this '
                'clears by itself.',
            false,
          ),
          BluetoothLowEnergyState.unauthorized => (
            'Bluetooth is not allowed',
            'Le\'Casa needs Bluetooth permission to hear your devices.',
            true,
          ),
          BluetoothLowEnergyState.unsupported => (
            'No Bluetooth on this device',
            'This tablet or phone has no Bluetooth LE radio Le\'Casa can use.',
            false,
          ),
          _ => null,
        };
        return Stack(
          children: [
            child,
            if (problem case (final title, final body, final ask))
              Positioned.fill(
                child: _Notice(
                  title: title,
                  body: body,
                  onAllow: ask ? autostart.askPermission : null,
                  onSettings: ask ? services.scanner.showAppSettings : null,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  final String title, body;
  final VoidCallback? onAllow, onSettings;
  const _Notice({
    required this.title,
    required this.body,
    this.onAllow,
    this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      // Taps stop here: what is underneath is stale.
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bluetooth_disabled,
                      size: 48,
                      color: scheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      title,
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      body,
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (onAllow != null || onSettings != null) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          if (onAllow != null)
                            FilledButton(
                              onPressed: onAllow,
                              child: const Text('Allow'),
                            ),
                          if (onSettings != null)
                            OutlinedButton(
                              onPressed: onSettings,
                              child: const Text('Open settings'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
