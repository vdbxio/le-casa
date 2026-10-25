// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import 'weather.dart';

/// Asks for a town or city by name and returns the place picked, or null.
Future<WeatherPlace?> showPlaceSearch(BuildContext context) =>
    showDialog<WeatherPlace?>(
      context: context,
      builder: (_) => const _PlaceSearch(),
    );

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
