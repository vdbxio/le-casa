// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../sync/sync_page.dart';
import 'people.dart';

/// Settings › Home: the people who live here and what tells that they are
/// home, then this home's screens and phones.
class HomeSettingsPage extends StatelessWidget {
  const HomeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const SyncPage(title: 'Home', top: [_People()]);
}

class _People extends StatefulWidget {
  const _People();

  @override
  State<_People> createState() => _PeopleState();
}

class _PeopleState extends State<_People> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // "Left 3m ago" moves on its own.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _add(AppServices s) async {
    final name = await askName(context, title: 'Add a person');
    if (name == null || !mounted) return;
    final p = s.people.add(name);
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => PersonPage(id: p.id)));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.people, s.liveData]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'People',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          if (s.people.people.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'Add the people who live here and give each one a Le\'Fob or '
                'their phone. The dashboard can then tell who is home.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final p in s.people.people) _PersonTile(person: p),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _add(s),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add a person'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final Person person;
  const _PersonTile({required this.person});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final home = personHome(person, s);
    final what = person.trackers.isEmpty
        ? 'Nothing to track yet'
        : person.trackers.map((t) => t.name).join(', ');
    return ListTile(
      leading: PersonAvatar(person: person, home: home),
      title: Text(person.name),
      subtitle: Text(
        '${switch (home) {
          true => 'Home',
          false => 'Away',
          null => person.trackers.isEmpty ? 'Unknown' : 'Checking',
        }} · $what',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PersonPage(id: person.id)),
      ),
    );
  }
}

/// A person's initial, with a dot that is filled while they are home.
class PersonAvatar extends StatelessWidget {
  final Person person;
  final bool? home;
  const PersonAvatar({super.key, required this.person, required this.home});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = person.name.isEmpty
        ? '?'
        : person.name.characters.first.toUpperCase();
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: home == true
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            child: Text(initial),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: home == true ? scheme.primary : scheme.surface,
                border: Border.all(
                  color: home == true ? scheme.surface : scheme.outline,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One person: their name and the fobs and phones that say they are home.
class PersonPage extends StatelessWidget {
  final String id;
  const PersonPage({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.people, s.liveData, s.sync]),
      builder: (context, _) {
        final p = s.people.byId(id);
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Removed')),
          );
        }
        final fobs = fobCandidates(s);
        final phones = phoneCandidates(s);
        // Trackers already given but not heard now still show, so they
        // can be taken away.
        final fobTrackers = <Tracker>[
          for (final d in fobs) Tracker(TrackerKind.fob, d.id, fobName(d)),
          for (final t in p.trackers)
            if (t.kind == TrackerKind.fob && !fobs.any((d) => d.id == t.id)) t,
        ];
        final phoneTrackers = <Tracker>[
          ...phones,
          for (final t in p.trackers)
            if (t.kind == TrackerKind.phone && !phones.contains(t)) t,
        ];
        final home = personHome(p, s);
        Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            text,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        );
        Widget note(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(text, style: theme.textTheme.bodyMedium),
        );
        Widget tile(Tracker t, IconData icon) {
          final owner = s.people.ownerOf(t);
          final st = trackerState(t, s);
          final mine = owner == p;
          return CheckboxListTile(
            secondary: Icon(icon),
            title: Text(t.name),
            subtitle: Text(
              owner != null && !mine
                  ? '${st.detail} · ${owner.name}\'s'
                  : st.detail,
            ),
            value: mine,
            onChanged: (v) => s.people.assign(p, t, v ?? false),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(p.name),
            actions: [
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final name = await askName(
                    context,
                    title: 'Rename',
                    initial: p.name,
                  );
                  if (name != null) s.people.rename(p, name);
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              ListTile(
                leading: PersonAvatar(person: p, home: home),
                title: Text(switch (home) {
                  true => 'Home',
                  false => 'Away',
                  null => p.trackers.isEmpty ? 'Not tracked' : 'Checking',
                }, style: theme.textTheme.titleLarge),
                subtitle: const Text(
                  'Home while any of the things ticked below is home.',
                ),
              ),
              header("Le'Fobs"),
              if (fobTrackers.isEmpty)
                note(
                  'No Le\'Fob heard yet. Press a button on one nearby and it '
                  'shows here.',
                ),
              for (final t in fobTrackers)
                tile(t, Icons.settings_remote_outlined),
              header('Phones'),
              if (phoneTrackers.isEmpty)
                note(
                  s.home.inHome
                      ? 'Phones show here once they run Le\'Casa and join '
                            'this home: below in Home, tap "Add a screen or '
                            'phone", then Join a home on the phone.'
                      : 'Start a home first (Home › Start a home), then add '
                            'phones to it. A phone in the home counts as home '
                            'while the screens can hear it.',
                ),
              for (final t in phoneTrackers) tile(t, Icons.phone_iphone),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: Text('Remove ${p.name}'),
                onTap: () {
                  s.people.remove(p);
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Asks for a name; null when cancelled.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'Name'),
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
}
