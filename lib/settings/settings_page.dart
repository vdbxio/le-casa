// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../app.dart';
import '../weather/weather.dart';
import 'settings_store.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final st = s.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
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
            const _Header('Weather'),
            ListTile(
              title: const Text('Location'),
              subtitle: Text(
                st.place?.name ??
                    'Not set. The weather card needs it to fetch a forecast.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickPlace(context, st),
            ),
            const _Header('Dashboard'),
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
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPlace(BuildContext context, SettingsStore st) async {
    final place = await showDialog<WeatherPlace?>(
      context: context,
      builder: (_) => const _PlaceSearch(),
    );
    if (place != null) await st.setPlace(place);
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

class _PlaceSearch extends StatefulWidget {
  const _PlaceSearch();

  @override
  State<_PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends State<_PlaceSearch> {
  final _q = TextEditingController();
  List<WeatherPlace> _results = const [];
  String? _error;
  bool _busy = false;

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await WeatherService.search(q);
      setState(() {
        _results = r;
        if (r.isEmpty) _error = 'No places found for “$q”';
      });
    } catch (_) {
      setState(
        () => _error =
            'Please connect to the internet or install the companion app',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Weather location'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _q,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Town or city',
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _search,
                    ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!),
            ),
          for (final p in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(p.name),
              subtitle: Text(
                '${p.lat.toStringAsFixed(2)}, ${p.lon.toStringAsFixed(2)}',
              ),
              onTap: () => Navigator.pop(context, p),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ],
  );
}
