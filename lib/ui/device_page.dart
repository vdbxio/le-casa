// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../decoders/raw_advertisement.dart';
import 'format.dart';

/// Everything about one broadcaster: decoded values, raw bytes, packet rate,
/// and the encryption key field for Victron / encrypted BTHome devices.
class DevicePage extends StatefulWidget {
  final String id;
  const DevicePage({super.key, required this.id});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  Timer? _tick;
  final _keyCtl = TextEditingController();
  String? _keyError;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _keyCtl.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final keys = AppServices.of(context).keys;
    try {
      await keys.set(widget.id, _keyCtl.text);
      setState(() => _keyError = null);
      _keyCtl.clear();
    } on FormatException catch (e) {
      setState(() => _keyError = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.tracker, services.keys]),
      builder: (context, _) {
        final dev = services.tracker[widget.id];
        if (dev == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Device gone')),
          );
        }
        final d = dev.decoded;
        final a = dev.latest;
        final hasKey = services.keys.has(widget.id);
        final wantsKey = d?.needs != null || hasKey;
        return Scaffold(
          appBar: AppBar(title: Text(dev.title)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _kv('Id', a.id),
              if (a.name != null) _kv('Advertised name', a.name!),
              _kv('Signal', '${a.rssi} dBm'),
              _kv('Last seen', ago(a.seenAt)),
              _kv(
                'Packets',
                '${dev.packets} (${dev.rate.toStringAsFixed(1)}/min)',
              ),
              if (d != null) ...[
                const Divider(height: 32),
                Text(d.protocol, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (d.needs != null)
                  Card(
                    color: theme.colorScheme.tertiaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(d.needs!),
                    ),
                  ),
                for (final r in d.readings) _kv(r.label, r.display),
                for (final e in d.info.entries) _kv(e.key, e.value, dim: true),
              ],
              if (wantsKey) ...[
                const Divider(height: 32),
                Text('Encryption key', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  hasKey
                      ? 'A key is stored for this device.'
                      : 'Paste the 32-character hex key. Victron: VictronConnect > device > '
                            'Settings > Product info > Instant readout via Bluetooth > Show. '
                            'BTHome: the bindkey from the device firmware.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _keyCtl,
                  decoration: InputDecoration(
                    labelText: '16-byte key (hex)',
                    errorText: _keyError,
                    border: const OutlineInputBorder(),
                  ),
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _saveKey,
                      child: const Text('Save key'),
                    ),
                    const SizedBox(width: 8),
                    if (hasKey)
                      OutlinedButton(
                        onPressed: () => services.keys.remove(widget.id),
                        child: const Text('Forget key'),
                      ),
                  ],
                ),
              ],
              if (dev.events.isNotEmpty) ...[
                const Divider(height: 32),
                Text('Events', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final e in dev.events)
                  Text(
                    '${clock(e.at)}  ${e.event}',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
              ],
              const Divider(height: 32),
              Text('Raw advertisement', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final e in a.manufacturerData.entries)
                _raw(
                  'Manufacturer 0x${e.key.toRadixString(16).padLeft(4, '0')}',
                  e.value,
                ),
              for (final e in a.serviceData.entries)
                _raw(
                  'Service data 0x${e.key.toRadixString(16).padLeft(4, '0')}',
                  e.value,
                ),
              if (a.serviceUuids.isNotEmpty)
                _kv(
                  'Service UUIDs',
                  a.serviceUuids
                      .map((u) => '0x${u.toRadixString(16)}')
                      .join(', '),
                ),
              if (a.manufacturerData.isEmpty && a.serviceData.isEmpty)
                const Text('No payload, only name and flags.'),
              const SizedBox(height: 24),
              Text('Recent packets', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final p in dev.recent.reversed.take(10))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${clock(p.seenAt)} ${p.rssi} ${_oneLine(p)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _oneLine(RawAdvertisement p) => [
    for (final e in p.manufacturerData.entries)
      'm${e.key.toRadixString(16)}:${hex(e.value, sep: '')}',
    for (final e in p.serviceData.entries)
      's${e.key.toRadixString(16)}:${hex(e.value, sep: '')}',
  ].join(' ');

  Widget _kv(String k, String v, {bool dim = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            k,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            v,
            style: dim
                ? TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
        ),
      ],
    ),
  );

  Widget _raw(String label, List<int> bytes) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(
          '${hex(bytes)}  (${bytes.length} bytes)',
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ],
    ),
  );
}
