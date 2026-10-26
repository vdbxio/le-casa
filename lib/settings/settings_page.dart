// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../app.dart';
import '../sync/sync_page.dart';

/// General settings: the first entry in the devices list.
class SettingsPage extends StatelessWidget {
  /// Shown beside the devices list instead of as its own page.
  final bool embedded;
  const SettingsPage({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final st = s.settings;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !embedded,
        title: const Text('General'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([st, s.tablet]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const _Header('Display'),
            ListTile(
              title: const Text('Theme'),
              subtitle: const Text(
                'System follows the tablet’s light/dark setting',
              ),
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {st.themeMode},
                onSelectionChanged: (v) => st.update(themeMode: v.single),
              ),
            ),
            SwitchListTile(
              title: const Text('Dim with room light'),
              subtitle: Text(
                s.tablet.lux == null
                    ? 'Uses the ambient light sensor. None reported on this tablet yet.'
                    : 'Uses the ambient light sensor · ${s.tablet.lux!.toStringAsFixed(0)} lx now',
              ),
              value: st.autoDim,
              onChanged: (v) => st.update(autoDim: v),
            ),
            ListTile(
              enabled: st.autoDim,
              title: const Text('Darkest brightness'),
              subtitle: Slider(
                value: st.minBrightness,
                min: 0.02,
                max: 0.8,
                divisions: 39,
                label: '${(st.minBrightness * 100).round()}%',
                onChanged: st.autoDim
                    ? (v) => st.update(minBrightness: v)
                    : null,
              ),
            ),
            SwitchListTile(
              title: const Text('Keep the screen on'),
              subtitle: const Text('For a tablet on the wall or on a charger'),
              value: st.keepScreenOn,
              onChanged: (v) => st.update(keepScreenOn: v),
            ),
            const _Header('Sync'),
            ListenableBuilder(
              listenable: Listenable.merge([s.sync, s.home]),
              builder: (context, _) => ListTile(
                title: const Text('Screens and phones'),
                subtitle: Text(
                  !s.home.inHome
                      ? 'Share readings, keys and controls with your other screens over Bluetooth'
                      : s.sync.connected
                      ? '${s.home.homeName} · linked to ${s.sync.linked.map((p) => p.name).join(', ')}'
                      : '${s.home.homeName} · looking for your other screens',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const SyncPage()),
                ),
              ),
            ),
            const _Header('Dashboard'),
            ListTile(
              title: const Text('Edit dashboard'),
              subtitle: const Text(
                'Add, move and resize cards. You can also long-press the dashboard.',
              ),
              trailing: const Icon(Icons.dashboard_customize_outlined),
              onTap: () {
                s.dashboard.setEditing(true);
                Navigator.popUntil(context, (r) => r.isFirst);
              },
            ),
            ListTile(
              title: const Text('Rebuild from devices'),
              subtitle: const Text(
                'Replaces the current layout with a fresh one from what the tablet hears',
              ),
              trailing: const Icon(Icons.refresh),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Rebuild the dashboard?'),
                    content: const Text(
                      'Your current layout will be replaced.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Rebuild'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await s.dashboard.reset();
                  if (context.mounted) {
                    Navigator.popUntil(context, (r) => r.isFirst);
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
