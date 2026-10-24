// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ui/palette.dart';
import 'cards/card_model.dart';
import 'cards/card_view.dart';
import 'catalog.dart';
import 'layout.dart';

/// What the picker returns.
sealed class Pick {
  const Pick();
}

/// Put this card in the slot. [move] is set when the card is already on
/// the dashboard elsewhere: it moves rather than being duplicated.
class PickCard extends Pick {
  final CardSpec spec;
  final bool move;
  const PickCard(this.spec, {this.move = false});
}

class PickEmpty extends Pick {
  const PickEmpty();
}

/// The side sheet for choosing a card. Cancel, the back button or a tap
/// outside closes it without changes.
Future<Pick?> showCardPicker(
  BuildContext context, {
  required List<CatalogEntry> entries,
  required Set<String> onDashboard,
  required CardSources sources,
  required bool slotHasCard,
}) => showGeneralDialog<Pick>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Cancel',
  barrierColor: Colors.black45,
  transitionDuration: const Duration(milliseconds: 180),
  pageBuilder: (context, _, _) => _PickerSheet(
    entries: entries,
    onDashboard: onDashboard,
    sources: sources,
    slotHasCard: slotHasCard,
  ),
  transitionBuilder: (context, anim, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(anim),
    child: child,
  ),
);

class _PickerSheet extends StatelessWidget {
  final List<CatalogEntry> entries;
  final Set<String> onDashboard;
  final CardSources sources;
  final bool slotHasCard;

  const _PickerSheet({
    required this.entries,
    required this.onDashboard,
    required this.sources,
    required this.slotHasCard,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final fresh = [
      for (final e in entries)
        if (!onDashboard.contains(e.spec.key)) e,
    ];
    final devices = [
      for (final e in fresh)
        if (e.spec.type == 'device' || e.spec.type == 'solar') e,
    ];
    final widgets = [
      for (final e in fresh)
        if (e.spec.type != 'device' && e.spec.type != 'solar') e,
    ];
    final placed = [
      for (final e in entries)
        if (onDashboard.contains(e.spec.key)) e,
    ];
    // A chip row starts with whatever readable devices are not placed yet.
    final chipItems = [
      for (final e in devices)
        if (!e.needsSetup && e.spec.type == 'device') e.spec,
    ].take(6).toList();

    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(fontSize: 12, letterSpacing: 1, color: c.muted),
      ),
    );

    Widget tile(CatalogEntry e, {bool move = false}) => _Tile(
      preview: e.spec.type == 'clock'
          ? _clockPill()
          : Pill(modelFor(e.spec, sources)),
      title: e.title,
      subtitle: move ? 'On the dashboard · tap to move it here' : e.subtitle,
      faded: move || e.needsSetup,
      onTap: () => Navigator.pop(context, PickCard(e.spec, move: move)),
    );

    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: c.card,
        elevation: 12,
        child: SizedBox(
          width: 440,
          height: double.infinity,
          child: SafeArea(
            left: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          slotHasCard ? 'Change card' : 'Add a card',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                    children: [
                      section('Found nearby'),
                      if (devices.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'Everything the tablet can hear is already on the dashboard.',
                            style: TextStyle(color: c.muted),
                          ),
                        ),
                      for (final e in devices) tile(e),
                      section('Widgets'),
                      for (final e in widgets) tile(e),
                      _Tile(
                        preview: Pill(
                          const CardModel(
                            title: 'Chips',
                            icon: Icons.view_agenda_outlined,
                            tone: Tone.accent,
                            headline: Metric('', 'Chips'),
                            pillLabel: '',
                          ),
                        ),
                        title: 'Chip row',
                        subtitle: chipItems.isEmpty
                            ? 'Needs devices that are not on the dashboard yet'
                            : 'Several small readings sharing one slot',
                        faded: chipItems.isEmpty,
                        onTap: chipItems.isEmpty
                            ? null
                            : () => Navigator.pop(
                                context,
                                PickCard(CardSpec('chips', items: chipItems)),
                              ),
                      ),
                      if (placed.isNotEmpty) ...[
                        section('Already on the dashboard'),
                        for (final e in placed) tile(e, move: true),
                      ],
                      if (slotHasCard) ...[
                        const SizedBox(height: 18),
                        OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.pop(context, const PickEmpty()),
                          icon: const Icon(Icons.layers_clear_outlined),
                          label: const Text('Empty this slot'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _clockPill() {
    final n = DateTime.now();
    return Pill(
      CardModel(
        title: 'Clock',
        icon: Icons.schedule,
        headline: Metric(
          'Time',
          '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}',
        ),
        pillLabel: 'time',
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final Widget preview;
  final String title, subtitle;
  final bool faded;
  final VoidCallback? onTap;

  const _Tile({
    required this.preview,
    required this.title,
    required this.subtitle,
    this.faded = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: c.card2,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Opacity(
            opacity: faded ? 0.6 : 1,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  SizedBox(width: 170, child: IgnorePointer(child: preview)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: TextStyle(fontSize: 13, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
