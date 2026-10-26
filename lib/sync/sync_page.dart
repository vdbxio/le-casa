// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../ui/palette.dart';
import 'home.dart';
import 'radio.dart';
import 'sync_service.dart';

/// Settings › Screens and phones: make this screen the hub, join one, add
/// screens, and compare pairing codes.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  bool _looking = false;
  PairPrompt? _shown;
  Timer? _tick;
  SyncService? _sync;

  @override
  void initState() {
    super.initState();
    // Countdown and the nearby list move on their own.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppServices.of(context).sync;
    if (_sync != s) {
      _sync?.removeListener(_onSync);
      _sync = s..addListener(_onSync);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sync?.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    final p = _sync?.prompt;
    if (p != null && p != _shown) {
      _shown = p;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showCode(p));
    }
  }

  Future<void> _showCode(PairPrompt p) async {
    final sync = _sync!;
    void closeIfGone() {
      if (sync.prompt != p && mounted) Navigator.of(context).maybePop();
    }

    sync.addListener(closeIfGone);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CodeDialog(prompt: p),
    );
    sync.removeListener(closeIfGone);
    if (sync.prompt == p) sync.answer(ok ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final sync = s.sync;
    final home = s.home;
    return Scaffold(
      appBar: AppBar(title: const Text('Screens and phones')),
      body: ListenableBuilder(
        listenable: Listenable.merge([sync, home]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            ListTile(
              title: const Text('This screen'),
              subtitle: Text(home.me.name),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _rename(home),
            ),
            if (sync.error != null)
              _Note(sync.error!, color: Theme.of(context).colorScheme.error),
            ...switch (home.role) {
              SyncRole.alone => _alone(sync),
              SyncRole.hub => _hub(sync, home),
              SyncRole.member => _member(sync, home),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _alone(SyncService sync) => [
    const _Note(
      'Share readings, keys and controls with your other tablets and phones, '
      'over Bluetooth only. One screen is the hub: pick one with good '
      'Bluetooth that stays on. Each device is read by one screen and shown '
      'on all of them.',
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => _startHome(sync),
            icon: const Icon(Icons.hub_outlined),
            label: const Text('Make this screen the hub'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() => _looking = true),
            icon: const Icon(Icons.link),
            label: const Text('Join a hub'),
          ),
        ],
      ),
    ),
    if (_looking) ...[
      const _Header('Hubs nearby'),
      if (sync.nearby.isEmpty)
        const _Note(
          'Looking… On the hub, open Settings › Screens and phones and tap '
          '"Add a screen or phone".',
        ),
      for (final h in _sorted(sync.nearby.values))
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: Text("Le'Casa hub ${h.tag ?? ''}".trim()),
          subtitle: Text('Signal ${h.rssi} dBm'),
          trailing: sync.joining
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: sync.joining ? null : () => sync.join(h),
        ),
    ],
  ];

  List<Widget> _hub(SyncService sync, HomeStore home) => [
    ListTile(
      leading: const Icon(Icons.hub),
      title: Text('Hub of ${home.homeName}'),
      subtitle: Text(
        sync.connected
            ? 'Other screens find this one over Bluetooth'
            : 'Starting…',
      ),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: sync.adding
          ? Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Waiting for a screen to join (${_left(sync.addingUntil!)}). '
                    'On the other screen, open Settings › Screens and phones '
                    '› Join a hub.',
                  ),
                ),
                TextButton(
                  onPressed: sync.stopAdding,
                  child: const Text('Stop'),
                ),
              ],
            )
          : Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: sync.connected ? sync.startAdding : null,
                icon: const Icon(Icons.add),
                label: const Text('Add a screen or phone'),
              ),
            ),
    ),
    const _Header('Connected now'),
    if (sync.members.isEmpty) const _Note('No other screens yet.'),
    for (final m in sync.members)
      ListTile(leading: const Icon(Icons.tablet_android), title: Text(m.name)),
    const _Header('Home'),
    _leaveTile(sync),
  ];

  List<Widget> _member(SyncService sync, HomeStore home) => [
    ListTile(
      leading: Icon(sync.connected ? Icons.link : Icons.link_off),
      title: Text('Part of ${home.homeName}'),
      subtitle: Text(
        sync.connected
            ? 'Connected to ${home.hubName}'
            : sync.connecting
            ? 'Connecting to ${home.hubName}…'
            : 'Looking for ${home.hubName}…',
      ),
    ),
    if (sync.connected) ...[
      const _Header('Screens in this home'),
      for (final m in sync.screens)
        ListTile(
          leading: Icon(
            m.name == home.hubName ? Icons.hub : Icons.tablet_android,
          ),
          title: Text(m == home.me ? '${m.name} (this screen)' : m.name),
        ),
    ],
    const _Header('Home'),
    _leaveTile(sync),
  ];

  Widget _leaveTile(SyncService sync) => ListTile(
    leading: const Icon(Icons.logout),
    title: const Text('Leave this home'),
    subtitle: const Text(
      'This screen goes back to reading everything itself. Keys it already '
      'has stay.',
    ),
    onTap: () async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Leave this home?'),
          content: const Text(
            'To join again you will need to pair with the hub again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Leave'),
            ),
          ],
        ),
      );
      if (ok == true) await sync.leave();
    },
  );

  Future<void> _startHome(SyncService sync) async {
    final ctl = TextEditingController(text: 'Home');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name this home'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Van, Boat, Cabin…'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctl.text),
            child: const Text('Make hub'),
          ),
        ],
      ),
    );
    if (name != null) await sync.startHome(name);
  }

  Future<void> _rename(HomeStore home) async {
    final ctl = TextEditingController(text: home.me.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name this screen'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Kitchen iPad'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null) await home.rename(name);
  }

  static List<HubSighting> _sorted(Iterable<HubSighting> hs) =>
      hs.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));

  static String _left(DateTime until) {
    final s = until.difference(DateTime.now()).inSeconds.clamp(0, 999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _CodeDialog extends StatelessWidget {
  final PairPrompt prompt;
  const _CodeDialog({required this.prompt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = prompt.code;
    return AlertDialog(
      title: Text('Pair with ${prompt.peer.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${code.substring(0, 3)} ${code.substring(3)}',
            style: theme.textTheme.displayMedium?.copyWith(
              fontFamily: displayFont,
              fontWeight: FontWeight.w600,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Check that ${prompt.peer.name} shows the same number, then tap '
            'Match on both screens.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text("Doesn't match"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Match'),
        ),
      ],
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

class _Note extends StatelessWidget {
  final String text;
  final Color? color;
  const _Note(this.text, {this.color});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
    ),
  );
}
