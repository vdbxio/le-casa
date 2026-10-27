// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../ui/palette.dart';
import 'home.dart';
import 'radio.dart';
import 'session.dart';
import 'sync_service.dart';

/// Settings › Screens and phones: start a home, join one, add screens,
/// compare pairing codes, and see where the other screens are.
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
            ...home.inHome ? _inHome(sync, home) : _alone(sync),
          ],
        ),
      ),
    );
  }

  List<Widget> _alone(SyncService sync) => [
    const _Note(
      'Share readings, keys and controls with your other tablets and phones, '
      'over Bluetooth only. Every screen links to the others it can hear and '
      'passes messages along, so screens out of each other\'s range still '
      'talk through the ones in between.',
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => _startHome(sync),
            icon: const Icon(Icons.home_outlined),
            label: const Text('Start a home'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() => _looking = true),
            icon: const Icon(Icons.link),
            label: const Text('Join a home'),
          ),
        ],
      ),
    ),
    if (_looking) ...[
      const _Header('Screens nearby'),
      if (!sync.nearby.values.any((h) => h.adding))
        const _Note(
          'Looking… On any screen already in the home, phone included, open '
          'Settings › Screens and phones and tap "Add a screen or phone".',
        ),
      for (final h in _sorted(sync.nearby.values.where((h) => h.adding)))
        ListTile(
          leading: const Icon(Icons.devices_other),
          title: Text("Le'Casa screen ${h.screen ?? ''}".trim()),
          subtitle: Text('Adding screens · signal ${h.rssi} dBm'),
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

  List<Widget> _inHome(SyncService sync, HomeStore home) => [
    ListTile(
      leading: Icon(sync.inTouch ? Icons.hub : Icons.hub_outlined),
      title: Text(home.homeName),
      subtitle: Text(
        sync.inTouch
            ? 'Linked to ${sync.touching.map((p) => p.name).join(', ')}'
                  '${sync.visitEvery != null ? ' (short visits every ${sync.visitEvery!.inSeconds} s, so this tablet keeps hearing broadcasts)' : ''}'
            : sync.connecting
            ? 'Linking…'
            : 'Looking for your other screens…',
      ),
    ),
    if (sync.serverError != null)
      _Note(sync.serverError!, color: Theme.of(context).colorScheme.tertiary),
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
                    'On the new screen, open Settings › Screens and phones '
                    '› Join a home.',
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
                onPressed: sync.serverError == null ? sync.startAdding : null,
                icon: const Icon(Icons.add),
                label: const Text('Add a screen or phone'),
              ),
            ),
    ),
    const _Header('Screens in this home'),
    for (final m in sync.screens) _screenTile(sync, home, m),
    if (sync.screens.length == 1) const _Note('No other screens heard yet.'),
    const _Header('Home'),
    _leaveTile(sync),
  ];

  Widget _screenTile(SyncService sync, HomeStore home, ScreenId m) {
    final me = m == home.me;
    final info = sync.peer(m.id);
    final phone = me ? home.phone : info?.phone ?? false;
    final lines = <String>[
      if (me)
        'This screen'
      else if (sync.touching.contains(m))
        'Linked directly'
      else
        'Reached through your other screens',
      ?_where(sync, home, m),
    ];
    return ListTile(
      leading: Icon(phone ? Icons.phone_iphone : Icons.tablet_android),
      title: Text(m.name),
      subtitle: Text(lines.join('\n')),
    );
  }

  /// "Nearest Kitchen iPad (-48 dBm), then M10 -71": which screens hear
  /// [m] and how loudly, for a rough idea of where it is.
  static String? _where(SyncService sync, HomeStore home, ScreenId m) {
    final heard = sync.heardBy(m.id);
    if (heard.isEmpty) return null;
    String name(ScreenId s) => s == home.me ? 'this screen' : s.name;
    final first = heard.first;
    final rest = [for (final h in heard.skip(1)) '${name(h.by)} ${h.rssi}'];
    return 'Nearest ${name(first.by)} (${first.rssi} dBm)'
        '${rest.isEmpty ? '' : ', then ${rest.join(', ')}'}';
  }

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
            'To join again, pair with any screen still in the home.',
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
            child: const Text('Start'),
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

  static List<PeerSighting> _sorted(Iterable<PeerSighting> hs) =>
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
