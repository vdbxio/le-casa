// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../ble/connection_manager.dart';
import '../ble/device_tracker.dart';
import '../bms/registry.dart';
import '../decoders/raw_advertisement.dart';
import 'format.dart';
import 'fridge_controls.dart';

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
  final _pinCtl = TextEditingController();
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
    _pinCtl.dispose();
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

  Future<void> _savePin() async {
    final services = AppServices.of(context);
    await services.keys.setSecret(widget.id, _pinCtl.text);
    _pinCtl.clear();
    // try it straight away
    unawaited(services.connections.readNow(widget.id));
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        services.tracker,
        services.keys,
        services.connections,
      ]),
      builder: (context, _) {
        final dev = services.tracker[widget.id];
        if (dev == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Device gone')),
          );
        }
        final d = dev.view;
        final a = dev.latest;
        final link = services.connections[widget.id];
        final hasKey = services.keys.has(widget.id);
        // A BMS waits for a connection, not for a key.
        final bms = bmsSpecFor(dev.lastRecognised ?? a);
        final isBms = bms != null || (d?.protocol.startsWith('Daly') ?? false);
        // Devices read over a connection wait for it, not for a key.
        final wantsKey = (d?.needs != null && !isBms && link == null) || hasKey;
        final hasPin = services.keys.secretFor(widget.id) != null;
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
              if (link != null) ...[
                const Divider(height: 32),
                _ConnectionSection(link: link, device: dev),
              ],
              if (d != null &&
                  d.isReadable &&
                  d.protocol == 'Alpicool' &&
                  services.connections.canControl(widget.id)) ...[
                const Divider(height: 32),
                FridgeControls(
                  id: widget.id,
                  state: d,
                  connections: services.connections,
                ),
              ],
              if (d != null) ...[
                const Divider(height: 32),
                Text(d.protocol, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (dev.polled != null && dev.polledAt != null)
                  Text(
                    dev.polledBy == null
                        ? 'Read over connection ${ago(dev.polledAt!)}'
                        : 'Read by ${dev.polledBy} ${ago(dev.polledAt!)}',
                    style: theme.textTheme.bodySmall,
                  ),
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
              if (bms != null && bms.acceptSecret) ...[
                const Divider(height: 32),
                Text('Battery PIN', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  [
                    hasPin
                        ? 'A PIN is stored for this battery.'
                        : 'Only needed if a PIN or password is set in the '
                              'battery\'s own app.',
                    ?bms.secretHint,
                  ].join(' '),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pinCtl,
                  decoration: const InputDecoration(
                    labelText: 'PIN or password',
                    border: OutlineInputBorder(),
                  ),
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _savePin,
                      child: const Text('Save PIN'),
                    ),
                    const SizedBox(width: 8),
                    if (hasPin)
                      OutlinedButton(
                        onPressed: () => services.keys.removeSecret(widget.id),
                        child: const Text('Forget PIN'),
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

/// Status and controls for a device that is read over a GATT connection.
class _ConnectionSection extends StatelessWidget {
  final Link link;
  final TrackedDevice device;
  const _ConnectionSection({required this.link, required this.device});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connections = AppServices.of(context).connections;
    final elsewhere = connections.heldElsewhere(link.id);
    final status = elsewhere != null
        ? '${elsewhere.screen} holds this connection and shares what it '
              'reads, so this screen leaves the device alone'
        : (connections.remote?.leavesConnections ?? false)
        ? 'This screen leaves device connections to your other screens '
              '(Settings › Screens and phones)'
        : switch (link.phase) {
            LinkPhase.ok when link.lastOk != null =>
              'Last read ${ago(link.lastOk!)}, next in '
                  '${_inSeconds(link.nextDue)}',
            LinkPhase.failed =>
              '${link.statusText}. Retry in ${_inSeconds(link.nextDue)}',
            _ => link.statusText,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connection', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '${link.driver.name} driver. Le\'Casa connects every '
          '${_duration(link.driver.interval)}, reads, and disconnects so the '
          'device stays free for its own app in between. Only one app can be '
          'connected at a time.',
          style: theme.textTheme.bodySmall,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Read over connection'),
          subtitle: Text(status),
          value: link.enabled,
          onChanged: link.phase == LinkPhase.unsupported
              ? null
              : (v) => connections.setDeviceEnabled(link.id, v),
        ),
        if (link.keepsDropping && elsewhere == null)
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'This device keeps dropping the connection a few seconds '
                'after it connects. Its radio and this tablet\'s Bluetooth '
                'chip do not get along, and no setting in Le\'Casa changes '
                'that. Another phone or tablet usually reads it fine. '
                'Le\'Casa keeps trying in the background.',
              ),
            ),
          ),
        if (!connections.enabled)
          Text(
            'Connections are paused globally (see the scan screen menu).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.tertiary,
            ),
          ),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: link.busy || link.phase == LinkPhase.unsupported
                  ? null
                  : () => connections.readNow(link.id),
              icon: link.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(link.busy ? link.statusText : 'Read now'),
            ),
          ],
        ),
      ],
    );
  }

  static String _inSeconds(DateTime t) {
    final s = t.difference(DateTime.now()).inSeconds;
    if (s <= 0) return 'a moment';
    if (s < 90) return '${s}s';
    return '${(s / 60).round()} min';
  }

  static String _duration(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';
}
