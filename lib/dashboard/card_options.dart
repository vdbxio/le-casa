// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart' hide Split;

import '../ui/palette.dart';
import 'card_picker.dart';
import 'cards/card_model.dart';
import 'cards/fit.dart' show hasChart;
import 'cards/template.dart';
import 'cards/template_view.dart';
import 'catalog.dart';
import 'dashboard_page.dart' show cardContent;
import 'layout.dart';

/// Card options: the card on the left, zoomed from its real slot size, and
/// on the right either the cards that can go in the slot or, once a box on
/// the card is tapped, what that box can show. Boxes split and merge like
/// dashboard slots. Returns the slot's new card, [PickEmpty], or null when
/// nothing changed.
Future<Pick?> showCardOptions(
  BuildContext context, {
  required CardSpec spec,
  required Size slotSize,
  required CardSources sources,
  required List<CatalogEntry> entries,
  required Set<String> onDashboard,
}) => Navigator.of(context).push<Pick>(
  PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => CardOptionsPage(
      spec: spec,
      slotSize: slotSize,
      sources: sources,
      entries: entries,
      onDashboard: onDashboard,
    ),
    transitionsBuilder: (context, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  ),
);

class CardOptionsPage extends StatefulWidget {
  final CardSpec spec;
  final Size slotSize;
  final CardSources sources;
  final List<CatalogEntry> entries;
  final Set<String> onDashboard;

  const CardOptionsPage({
    super.key,
    required this.spec,
    required this.slotSize,
    required this.sources,
    required this.entries,
    required this.onDashboard,
  });

  @override
  State<CardOptionsPage> createState() => _CardOptionsPageState();
}

class _CardOptionsPageState extends State<CardOptionsPage> {
  late CardTemplate _t;

  /// Whether the card uses [_t] rather than the automatic layouts.
  late bool _custom;
  NodePath? _sel;

  CardSpec get spec => widget.spec;

  /// Clocks and chip rows draw themselves; only data cards have boxes.
  bool get _arrangeable => spec.type != 'clock' && spec.type != 'chips';

  @override
  void initState() {
    super.initState();
    _custom = spec.template != null;
    _t = spec.template?.copy() ?? defaultTemplate(_model);
  }

  CardModel get _model => widget.sources.model(spec);

  void _edit(void Function() f) => setState(() {
    f();
    _custom = true;
  });

  void _done() {
    if (_custom == (spec.template != null) && !_custom) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      PickCard(
        _custom
            ? spec.copyWith(template: _t.copy())
            : spec.copyWith(clearTemplate: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final model = widget.sources.model(spec);
    final slot = widget.slotSize;
    final hiddenHere = _arrangeable
        ? planTemplate(
            _t,
            templatePadding.deflateRect(Offset.zero & slot),
          ).hidden.length
        : 0;

    return Scaffold(
      backgroundColor: c.screen,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              title: model.title,
              slot: slot,
              onCancel: () => Navigator.pop(context),
              onReset: _arrangeable
                  ? () => setState(() {
                      _t = defaultTemplate(model);
                      _custom = false;
                      _sel = null;
                    })
                  : null,
              onDone: _done,
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 24, 24, 24),
                      child: Column(
                        children: [
                          // The card at its real slot size, zoomed to fill
                          // the space, so it looks as it will on the
                          // dashboard and its boxes are easy to tap.
                          Expanded(
                            child: SizedBox.expand(
                              child: FittedBox(
                                child: SizedBox.fromSize(
                                  size: slot,
                                  child: _preview(model),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _hint(hiddenHere),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: c.muted, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 420,
                    color: c.card,
                    child: _sel == null ? _cards() : _boxPanel(c, model),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _hint(int hidden) {
    if (!_arrangeable) return 'This card arranges itself.';
    final base = _sel == null
        ? 'Tap a box on the card to choose what it shows.'
        : 'Drag the handles between boxes to resize them. Hold a box and '
              'drag it onto another to swap them.';
    if (hidden == 0) return base;
    return '$base\n${hidden == 1 ? 'One box does' : '$hidden boxes do'} '
        'not fit this slot and will be hidden on the dashboard.';
  }

  Widget _preview(CardModel model) {
    if (!_arrangeable) {
      return IgnorePointer(
        child: cardContent(spec, widget.slotSize, widget.sources).$1,
      );
    }
    return TemplateCard(
      model,
      _t,
      editing: TemplateEditing(
        selected: _sel,
        onSelect: (p) => setState(() => _sel = p),
        onMove: (from, to) => _edit(() {
          _t.movePart(from, to);
          _sel = to;
        }),
        onResize: (seam, d) =>
            _edit(() => _t.resize(seam.split, seam.index, d)),
      ),
    );
  }

  Widget _cards() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Options for the card as a whole, for what no box can be tapped for.
      if (_arrangeable && hasChart(_model))
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
          child: SwitchListTile(
            title: const Text('Graph behind the card'),
            subtitle: const Text(
              'Faintly, when no box on the card shows the graph',
            ),
            value: _t.backdrop,
            onChanged: (v) => _edit(() => _t.backdrop = v),
          ),
        ),
      _PanelHeader(title: 'Change card'),
      Expanded(
        child: CardPickerList(
          entries: widget.entries,
          onDashboard: widget.onDashboard,
          sources: widget.sources,
          slotHasCard: true,
          current: spec.key,
          onPick: (p) => Navigator.pop(context, p),
        ),
      ),
    ],
  );

  Widget _boxPanel(LeColors c, CardModel model) {
    final path = _sel!;
    final box = _t.at(path);
    final part = box is BoxPart ? box : null;
    final points = dataPoints(model);
    final suggested = suggestedFor(_t, path, points);
    final rest = [
      for (final p in points)
        if (!suggested.contains(p)) p,
    ];
    final current = pointById(points, part?.point);

    Widget heading(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        s.toUpperCase(),
        style: TextStyle(fontSize: 12, letterSpacing: 1, color: c.muted),
      ),
    );

    Widget row(DataPoint p) {
      final on = part?.point == p.id;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: on ? c.accent.withValues(alpha: 0.14) : c.card2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: on ? BorderSide(color: c.accent, width: 2) : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _edit(() {
              final b = _t.at(path) as BoxPart;
              b.point = p.id;
              if (b.kind == null || !p.kinds.contains(b.kind)) {
                b.kind = p.kinds.first;
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      p.label,
                      style: TextStyle(fontSize: 15, color: c.ink),
                    ),
                  ),
                  if (p.preview.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        p.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: numberStyle(16, c.muted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final canAlign =
        part?.kind != null &&
        part!.kind != PartKind.graph &&
        part.kind != PartKind.bars;
    final styles = current?.kinds ?? const <PartKind>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: part == null
              ? 'Group of boxes'
              : (part.kind?.label ?? 'Empty box'),
          onBack: () => setState(() => _sel = null),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ToolChip(
                icon: Icons.vertical_split_outlined,
                label: 'Add beside',
                onTap: _t.canSplit(path, SplitAxis.horizontal)
                    ? () => _edit(
                        () => _sel = _t.split(path, SplitAxis.horizontal),
                      )
                    : null,
              ),
              _ToolChip(
                icon: Icons.horizontal_split_outlined,
                label: 'Add below',
                onTap: _t.canSplit(path, SplitAxis.vertical)
                    ? () =>
                          _edit(() => _sel = _t.split(path, SplitAxis.vertical))
                    : null,
              ),
              _ToolChip(
                icon: Icons.delete_outline,
                label: 'Remove box',
                onTap: () => _edit(() {
                  _t.remove(path);
                  _sel = null;
                }),
              ),
            ],
          ),
        ),
        if (canAlign || styles.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (canAlign)
                  SegmentedButton<PartAlign>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: PartAlign.start,
                        icon: Icon(Icons.format_align_left),
                        tooltip: 'Align left',
                      ),
                      ButtonSegment(
                        value: PartAlign.center,
                        icon: Icon(Icons.format_align_center),
                        tooltip: 'Align centre',
                      ),
                      ButtonSegment(
                        value: PartAlign.end,
                        icon: Icon(Icons.format_align_right),
                        tooltip: 'Align right',
                      ),
                    ],
                    selected: {part.align},
                    onSelectionChanged: (s) =>
                        _edit(() => (_t.at(path) as BoxPart).align = s.first),
                  ),
                if (styles.length > 1)
                  SegmentedButton<PartKind>(
                    showSelectedIcon: false,
                    segments: [
                      for (final k in styles)
                        ButtonSegment(value: k, label: Text(k.label)),
                    ],
                    selected: {part!.kind!},
                    onSelectionChanged: (s) =>
                        _edit(() => (_t.at(path) as BoxPart).kind = s.first),
                  ),
              ],
            ),
          ),
        if (part != null)
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
              children: [
                heading('Suggested for this box'),
                for (final p in suggested) row(p),
                if (rest.isNotEmpty) ...[
                  heading('Everything else'),
                  for (final p in rest) row(p),
                ],
              ],
            ),
          )
        else
          const Spacer(),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final Size slot;
  final VoidCallback onCancel, onDone;
  final VoidCallback? onReset;

  const _TopBar({
    required this.title,
    required this.slot,
    required this.onCancel,
    required this.onDone,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        children: [
          OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
          Expanded(
            child: Column(
              children: [
                Text(
                  'Card options',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  '$title · slot ${slot.width.round()} × ${slot.height.round()}',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          if (onReset != null) ...[
            TextButton(
              onPressed: onReset,
              child: const Text('Reset to default'),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton(onPressed: onDone, child: const Text('Done')),
        ],
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  const _PanelHeader({required this.title, this.onBack});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 14, 18, 4),
    child: Row(
      children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            tooltip: 'Back to the card list',
            icon: const Icon(Icons.arrow_back),
          )
        else
          const SizedBox(width: 12),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
        ),
      ],
    ),
  );
}

class _ToolChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ToolChip({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}
