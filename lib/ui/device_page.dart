// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../ble/connection_manager.dart';
import '../ble/device_tracker.dart';
import '../bms/registry.dart';
import '../dashboard/catalog.dart' show autoDeviceName, deviceName;
import '../decoders/decoded.dart';
import '../decoders/raw_advertisement.dart';
import 'format.dart';
import 'fridge_controls.dart';
import 'switch_controls.dart';

/// Everything about one broadcaster: decoded values, raw bytes, packet rate,
/// and the encryption key field for Victron / encrypted BTHome devices.
class DevicePage extends StatefulWidget {
  final String id;

  /// Shown beside the devices list instead of as its own page.
  final bool embedded;
  const DevicePage({super.key, required this.id, this.embedded = false});

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
    final services = AppServices.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await services.keys.set(widget.id, _keyCtl.text);
      setState(() => _keyError = null);
      _keyCtl.clear();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            services.home.inHome
                ? 'Key saved and sent to your other screens. Watch the key '
                      'status below.'
                : 'Key saved. Watch the key status below.',
          ),
        ),
      );
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
            appBar: AppBar(automaticallyImplyLeading: !widget.embedded),
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
        final wantsKey =
            (d?.needs != null && !isBms && link == null) ||
            dev.decoded?.protocol == 'Xiaomi MiBeacon' ||
            dev.polled?.protocol == 'Xiaomi (connected)' ||
            hasKey;
        final hasPin = services.keys.secretFor(widget.id) != null;
        // iOS knows devices by its own id, not a MAC: show it beside the
        // name where there is room, else with the other details.
        final platformId = parseMac(a.id) == null;
        final idInHeader =
            platformId && MediaQuery.sizeOf(context).width >= 600;
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !widget.embedded,
            title: _NameTitle(key: ValueKey(widget.id), device: dev),
            actions: [
              if (idInHeader)
                Padding(
                  padding: const EdgeInsets.only(left: 12, right: 16),
                  child: SelectableText(
                    a.id,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _InfoChips([
                if (!idInHeader) (platformId ? 'Id' : 'MAC', a.id),
                // iOS ids hide the MAC; some devices send it in their
                // broadcasts, or another screen knows it.
                if (dev.mac case final mac? when mac != a.id) ('MAC', mac),
                if (a.name case final name? when name != deviceName(dev))
                  ('Advertised', name),
                ('Signal', '${a.rssi} dBm'),
                // A device held open stops advertising: its last read is
                // what says it is alive.
                if (dev.polledAt case final at?) ('Read', ago(at)),
                ('Seen', ago(a.seenAt)),
                (
                  'Packets',
                  '${dev.packets} · ${dev.rate.toStringAsFixed(1)}/min',
                ),
              ]),
              if (link != null) ...[
                const Divider(height: 32),
                _ConnectionSection(link: link, device: dev),
              ] else if (dev.polledBy != null && services.home.inHome) ...[
                // Known only through another screen: a device that stops
                // advertising while that screen stays connected to it.
                // Its settings still belong here.
                const Divider(height: 32),
                Text('Connection', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  DateTime.now().difference(dev.polledAt!) <
                          const Duration(minutes: 5)
                      ? '${dev.polledBy} is connected to it and shares what '
                            'it reads. This screen cannot hear the device '
                            'itself right now.'
                      : '${dev.polledBy} last read it '
                            '${ago(dev.polledAt!)}. Nothing has heard it '
                            'since: it may be off, out of range, or held by '
                            'another app.',
                  style: theme.textTheme.bodySmall,
                ),
                _ReadBy(id: widget.id),
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
              if (d != null &&
                  d.isReadable &&
                  d.kind == DeviceKind.switches &&
                  services.connections.canControl(widget.id)) ...[
                const Divider(height: 32),
                SwitchControls(
                  id: widget.id,
                  state: d,
                  connections: services.connections,
                ),
              ],
              if (d != null) ...[
                const Divider(height: 32),
                Text(d.protocol, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (identical(d, dev.polled) && dev.polledAt != null)
                  Text(
                    dev.polledBy == null
                        ? 'Read over connection ${ago(dev.polledAt!)}'
                        : 'Read by ${dev.polledBy} ${ago(dev.polledAt!)}',
                    style: theme.textTheme.bodySmall,
                  )
                else if (d.keyCheck == KeyCheck.works && d.decryptedAt != null)
                  Text(
                    'Read from its broadcasts, last decrypted '
                    '${ago(d.decryptedAt!)}',
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
                if (hasKey)
                  _KeyStatus(decoded: dev.decoded)
                else
                  Text(
                    'Paste the 32-character hex key. Victron: VictronConnect > device > '
                    'Settings > Product info > Instant readout via Bluetooth > Show. '
                    'BTHome: the bindkey from the device firmware. '
                    'Stock Xiaomi: the bindkey from the Xiaomi cloud; '
                    'once it is in, every screen reads the sensor\'s '
                    'broadcasts and none needs to connect.',
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

/// Whether the stored key works, so entering one gets an answer.
class _KeyStatus extends StatelessWidget {
  final Decoded? decoded;
  const _KeyStatus({required this.decoded});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final d = decoded;
    final (icon, color, text) = switch (d?.keyCheck) {
      KeyCheck.works => (
        Icons.check_circle,
        c.primary,
        'Key works. ${d!.decryptedAt == null ? 'Its broadcasts decrypt' : 'Last broadcast decrypted ${ago(d.decryptedAt!)}'}'
            ', so no screen needs to connect to it.',
      ),
      KeyCheck.wrong => (
        Icons.error,
        c.error,
        'This key does not fit: a broadcast with readings did not '
            'decrypt. Check that it is the key for this MAC.',
      ),
      _ => (
        Icons.hourglass_top,
        c.tertiary,
        'Key saved. Waiting for a broadcast with readings to try it on; '
            'stock Xiaomi sensors send one every few minutes.',
      ),
    };
    return Card(
      color: c.surfaceContainerHighest,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(text),
      ),
    );
  }
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
    final aside = connections.remote?.standAside(link.id);
    final broadcasts = device.decoded?.isReadable ?? false;
    final status = !link.enabled && link.phase != LinkPhase.unsupported
        ? 'Off. Le\'Casa only connects to devices you turn on here, so it '
              'leaves other people\'s devices alone'
        : broadcasts
        ? 'Not needed now: its broadcasts carry the readings'
        : elsewhere != null
        ? '${elsewhere.screen} holds this connection and shares what it '
              'reads, so this screen leaves the device alone'
        : aside != null
        ? '$aside, so this screen leaves the device alone'
        : connections.isLive(link.id)
        ? 'Staying connected, reading every few seconds. Last read '
              '${ago(link.lastOk!)}'
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
          connections.isLive(link.id)
              ? '${link.driver.name} driver. Le\'Casa stays connected and '
                    'reads every few seconds. Only one app can be connected '
                    'at a time.'
              : '${link.driver.name} driver. Le\'Casa connects every '
                    '${_duration(link.driver.interval)}, reads, and '
                    'disconnects so the device stays free for its own app in '
                    'between. Only one app can be connected at a time.',
          style: theme.textTheme.bodySmall,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Connect to this device'),
          subtitle: Text(status),
          value: link.enabled,
          onChanged: link.phase == LinkPhase.unsupported
              ? null
              : (v) => connections.setDeviceEnabled(link.id, v),
        ),
        if (AppServices.of(context).home.inHome) _ReadBy(id: link.id),
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
            'Connections are paused for every device (the link button above the devices list).',
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

/// Which screen in the home reads this device: automatic, or locked to one.
class _ReadBy extends StatelessWidget {
  final String id;
  const _ReadBy({required this.id});

  @override
  Widget build(BuildContext context) {
    final sync = AppServices.of(context).sync;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, sync.readBy]),
      builder: (context, _) {
        final lock = sync.readBy.lockOf(id);
        final screens = sync.screens;
        final locked = lock?.screen;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Read by'),
          subtitle: const Text(
            'Automatic lets the screen that hears it best read it, and '
            'another takes over if that one stops. Lock it to one screen '
            'when another keeps failing to connect.',
          ),
          trailing: DropdownButton<String?>(
            value: locked,
            onChanged: (v) => sync.lock(
              id,
              v == null ? null : screens.firstWhere((s) => s.id == v),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('Automatic')),
              for (final s in screens)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(s == sync.home.me ? '${s.name} (this)' : s.name),
                ),
              if (locked != null && !screens.any((s) => s.id == locked))
                DropdownMenuItem(
                  value: locked,
                  child: Text('${lock?.screenName ?? 'Gone screen'} (away)'),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The device's name, tap to change it. Every screen in the home takes the
/// new name; an empty one goes back to the name Le'Casa makes up.
class _NameTitle extends StatefulWidget {
  final TrackedDevice device;
  const _NameTitle({super.key, required this.device});

  @override
  State<_NameTitle> createState() => _NameTitleState();
}

class _NameTitleState extends State<_NameTitle> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _save();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    _ctl.text = widget.device.label ?? '';
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  void _save() {
    final text = _ctl.text.trim();
    setState(() => _editing = false);
    if (text == (widget.device.label ?? '')) return;
    AppServices.of(context).sync.rename(
      widget.device.id,
      text.isEmpty || text == autoDeviceName(widget.device) ? null : text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    if (_editing) {
      return TextField(
        controller: _ctl,
        focusNode: _focus,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        style: Theme.of(context).textTheme.titleLarge,
        decoration: InputDecoration(
          isDense: true,
          hintText: autoDeviceName(d),
          helperText: 'Empty uses the automatic name',
          suffixIcon: IconButton(
            tooltip: 'Save name',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ),
      );
    }
    return Tooltip(
      message: 'Rename',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _edit,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  deviceName(d),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.edit_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The basic facts about a device on one line that scrolls sideways.
class _InfoChips extends StatelessWidget {
  final List<(String, String)> items;
  const _InfoChips(this.items);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (k, v) in items)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$k  ',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    TextSpan(text: v),
                  ],
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
