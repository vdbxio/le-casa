// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart' hide Split;
import 'package:flutter/services.dart';

import '../app.dart';
import '../settings/settings_page.dart';
import '../ui/palette.dart';
import '../ui/scan_page.dart';
import 'auto_layout.dart';
import 'card_picker.dart';
import 'cards/card_view.dart';
import 'cards/fit.dart';
import 'catalog.dart';
import 'dashboard_controller.dart';
import 'geometry.dart';
import 'layout.dart';

/// The home screen: a full-screen, non-scrolling dashboard. Long-press (or
/// the faint menu button) to edit it.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

const _screenPad = 14.0;
const _gap = 12.0;

/// How long the first launch listens before laying out the dashboard.
const firstRunListen = Duration(seconds: 12);

class _DashboardPageState extends State<DashboardPage> {
  Timer? _firstRun;

  @override
  void initState() {
    super.initState();
    _lockLandscape();
  }

  @override
  void dispose() {
    _firstRun?.cancel();
    super.dispose();
  }

  void _lockLandscape() => SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  Future<void> _open(Widget page) async {
    final dash = AppServices.of(context).dashboard;
    dash.setEditing(false);
    await SystemChrome.setPreferredOrientations(const []);
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    _lockLandscape();
  }

  CardSources _sources(AppServices s) => CardSources(
    tracker: s.tracker,
    history: s.history,
    tablet: s.tablet,
    weather: s.weather,
  );

  void _buildFirstLayout() {
    final s = AppServices.of(context);
    _firstRun?.cancel();
    _firstRun = null;
    s.dashboard.setLayout(autoLayout(catalog(_sources(s))));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final c = LeColors.of(context);
    return Scaffold(
      backgroundColor: c.screen,
      body: ListenableBuilder(
        listenable: Listenable.merge([s.dashboard, s.liveData]),
        builder: (context, _) {
          final dash = s.dashboard;
          if (!dash.loaded) return const SizedBox.expand();
          if (!dash.hasLayout) {
            _firstRun ??= Timer(firstRunListen, () {
              if (mounted) _buildFirstLayout();
            });
            return _FirstRun(
              heard: catalog(_sources(s))
                  .where((e) => e.spec.type == 'device' && !e.needsSetup)
                  .length,
              onNow: _buildFirstLayout,
            );
          }
          return SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => _Board(
                size: box.biggest,
                dash: dash,
                sources: _sources(s),
                onOpenDevices: () => _open(const ScanPage()),
                onOpenSettings: () => _open(const SettingsPage()),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FirstRun extends StatelessWidget {
  final int heard;
  final VoidCallback onNow;
  const _FirstRun({required this.heard, required this.onNow});

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(),
          ),
          const SizedBox(height: 24),
          Text(
            'Listening for your devices',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            heard == 0
                ? 'Nothing heard yet'
                : 'Heard $heard so far. Your dashboard is built from them.',
            style: TextStyle(color: c.muted, fontSize: 16),
          ),
          const SizedBox(height: 20),
          TextButton(onPressed: onNow, child: const Text('Build it now')),
        ],
      ),
    );
  }
}

class _Board extends StatelessWidget {
  final Size size;
  final DashboardController dash;
  final CardSources sources;
  final VoidCallback onOpenDevices, onOpenSettings;

  const _Board({
    required this.size,
    required this.dash,
    required this.sources,
    required this.onOpenDevices,
    required this.onOpenSettings,
  });

  DashboardLayout get page => dash.page;

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final area = Rect.fromLTWH(
      _screenPad,
      _screenPad,
      size.width - 2 * _screenPad,
      size.height - 2 * _screenPad,
    );
    final g = computeGeometry(page.root, area, gap: _gap);
    final editing = dash.editing;
    final selected = dash.selected;
    final selBox = selected == null
        ? null
        : g.slots.where((b) => _samePath(b.path, selected)).firstOrNull;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: editing ? null : () => dash.setEditing(true),
      onTap: editing ? () => dash.select(null) : null,
      child: Stack(
        children: [
          for (final b in g.slots)
            Positioned.fromRect(
              rect: b.rect,
              child: _SlotView(
                key: ValueKey(b.path.join('.')),
                box: b,
                editing: editing,
                selected: selBox == b,
                sources: sources,
                onSelect: () => dash.select(b.path),
                onPick: () => _pick(context, b),
                onRemove: () {
                  page.remove(b.path);
                  dash.selected = null;
                  dash.changed();
                },
                onCycleSize: (current) {
                  final card = b.slot.card!;
                  const order = [
                    null,
                    CardSize.large,
                    CardSize.medium,
                    CardSize.small,
                    CardSize.pill,
                  ];
                  final next =
                      order[(order.indexOf(card.pinned) + 1) % order.length];
                  b.slot.card = next == null
                      ? card.copyWith(unpin: true)
                      : card.copyWith(pinned: next);
                  dash.changed();
                },
              ),
            ),
          if (editing) ...[
            for (final gap in g.gaps) ..._gapTools(c, gap),
            ..._rootCaps(c, area),
            if (selBox != null) ..._edgeButtons(c, selBox),
            Positioned(
              right: _screenPad + 8,
              bottom: _screenPad + 8,
              child: _EditBar(
                axis: page.root.axis,
                onAxis: (a) {
                  page.setRootAxis(a);
                  dash.selected = null;
                  dash.changed();
                },
                onDevices: onOpenDevices,
                onSettings: onOpenSettings,
                onDone: () => dash.setEditing(false),
              ),
            ),
          ] else
            Positioned(
              top: 0,
              right: 0,
              child: _MenuButton(
                onEdit: () => dash.setEditing(true),
                onDevices: onOpenDevices,
                onSettings: onOpenSettings,
              ),
            ),
        ],
      ),
    );
  }

  static bool _samePath(NodePath a, NodePath b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _pick(BuildContext context, SlotBox b) async {
    final pick = await showCardPicker(
      context,
      entries: catalog(sources),
      onDashboard: page.cardKeys,
      sources: sources,
      slotHasCard: b.slot.card != null,
    );
    switch (pick) {
      case null:
        return;
      case PickEmpty():
        b.slot.card = null;
      case PickCard(:final spec, :final move):
        if (move) page.take(spec.key);
        b.slot.card = spec;
    }
    dash.changed();
  }

  /// A drag handle on every gap, with a + beside it that inserts a slot.
  List<Widget> _gapTools(LeColors c, GapBox gap) {
    final sideways = gap.axis == SplitAxis.horizontal;
    const hit = 28.0;
    final r = gap.rect;
    final hitRect = sideways
        ? Rect.fromCenter(center: r.center, width: hit, height: r.height)
        : Rect.fromCenter(center: r.center, width: r.width, height: hit);
    final plusAt = sideways
        ? r.center.translate(0, 46)
        : r.center.translate(46, 0);
    void drag(double px) {
      page.resize(
        gap.split,
        gap.index,
        px / gap.pairExtent,
        minFraction: (72 / gap.pairExtent).clamp(0.04, 0.45),
      );
      dash.changed();
    }

    return [
      Positioned.fromRect(
        rect: hitRect,
        child: MouseRegion(
          cursor: sideways
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: sideways ? (d) => drag(d.delta.dx) : null,
            onVerticalDragUpdate: sideways ? null : (d) => drag(d.delta.dy),
            child: Center(
              child: Container(
                width: sideways ? 5 : 48,
                height: sideways ? 48 : 5,
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
      ),
      _plus(c, plusAt, 'Add a slot here', () {
        final p = page.insertSlot(gap.split, gap.index + 1);
        dash.selected = p;
        dash.changed();
      }),
    ];
  }

  /// + at the two screen edges: a new column (or row) at either end.
  List<Widget> _rootCaps(LeColors c, Rect area) {
    final cols = page.root.axis == SplitAxis.horizontal;
    final what = cols ? 'column' : 'row';
    final start = cols
        ? Offset(area.left, area.center.dy)
        : Offset(area.center.dx, area.top);
    final end = cols
        ? Offset(area.right, area.center.dy)
        : Offset(area.center.dx, area.bottom);
    void add(int at) {
      final p = page.insertSlot(const [], at);
      dash.selected = p;
      dash.changed();
    }

    return [
      _plus(c, start, 'Add a $what at the start', () => add(0)),
      _plus(
        c,
        end,
        'Add a $what at the end',
        () => add(page.root.children.length),
      ),
    ];
  }

  /// On the selected slot: + just inside each edge. Along the parent's
  /// direction it adds a neighbour; across it, it splits the slot (the
  /// third level) or, when already three deep, adds beside the parent.
  List<Widget> _edgeButtons(LeColors c, SlotBox b) {
    final r = b.rect;
    final parent = page.parentOf(b.path);
    final i = b.path.last;
    // Sides facing a neighbour along the parent's direction already have
    // the + beside that gap's handle.
    bool hasNeighbour(AxisDirection side) {
      final along = (side == AxisDirection.left || side == AxisDirection.right)
          ? SplitAxis.horizontal
          : SplitAxis.vertical;
      if (parent.axis != along) return false;
      final after = side == AxisDirection.right || side == AxisDirection.down;
      return after ? i < parent.children.length - 1 : i > 0;
    }

    Widget at(Offset o, AxisDirection side) =>
        _plus(c, o, 'Add a slot ${side.name}', () {
          final p = _addAtEdge(b.path, side);
          dash.selected = p;
          dash.changed();
        }, filled: false);
    return [
      for (final (o, side) in [
        (r.topCenter, AxisDirection.up),
        (r.bottomCenter, AxisDirection.down),
        (r.centerLeft, AxisDirection.left),
        (r.centerRight, AxisDirection.right),
      ])
        if (!hasNeighbour(side)) at(o, side),
    ];
  }

  NodePath _addAtEdge(NodePath path, AxisDirection side) {
    final sideAxis = (side == AxisDirection.left || side == AxisDirection.right)
        ? SplitAxis.horizontal
        : SplitAxis.vertical;
    final after = side == AxisDirection.right || side == AxisDirection.down;
    final parentPath = path.sublist(0, path.length - 1);
    final parent = page.at(parentPath) as Split;
    final i = path.last;
    if (parent.axis == sideAxis) {
      return page.insertSlot(parentPath, after ? i + 1 : i);
    }
    if (page.canSplitBeside(path)) return page.splitBeside(path, after: after);
    final gi = parentPath.last;
    return page.insertSlot(
      parentPath.sublist(0, parentPath.length - 1),
      after ? gi + 1 : gi,
    );
  }

  Widget _plus(
    LeColors c,
    Offset center,
    String label,
    VoidCallback onTap, {
    bool filled = true,
  }) {
    const s = 30.0;
    return Positioned(
      left: center.dx - s / 2,
      top: center.dy - s / 2,
      width: s,
      height: s,
      child: Tooltip(
        message: label,
        child: Material(
          color: filled ? c.accent : c.card,
          shape: CircleBorder(
            side: BorderSide(color: filled ? c.screen : c.accent, width: 2),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Icon(
              Icons.add,
              size: 18,
              color: filled ? Colors.white : c.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _SlotView extends StatelessWidget {
  final SlotBox box;
  final bool editing, selected;
  final CardSources sources;
  final VoidCallback onSelect, onPick, onRemove;
  final void Function(CardSize current) onCycleSize;

  const _SlotView({
    super.key,
    required this.box,
    required this.editing,
    required this.selected,
    required this.sources,
    required this.onSelect,
    required this.onPick,
    required this.onRemove,
    required this.onCycleSize,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final card = box.slot.card;
    final (content, size) = card == null
        ? (null, null)
        : cardContent(card, box.rect.size, sources);
    if (!editing) return content ?? const SizedBox.shrink();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      child: CustomPaint(
        foregroundPainter: _DashedOutline(
          selected ? c.accent : c.accent.withValues(alpha: 0.45),
          selected ? 2.5 : 2,
        ),
        child: Stack(
          children: [
            if (content != null)
              Positioned.fill(child: IgnorePointer(child: content)),
            if (card == null)
              Center(
                child: TextButton(
                  onPressed: onPick,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.accent, width: 2.5),
                        ),
                        child: Icon(Icons.add, size: 30, color: c.accent),
                      ),
                      if (box.rect.height > 120) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Add card',
                          style: TextStyle(
                            color: c.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (selected)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (card != null &&
                        card.type != 'chips' &&
                        size != null) ...[
                      _SizeBadge(
                        pinned: card.pinned != null,
                        size: size,
                        onTap: () => onCycleSize(size),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (card != null) ...[
                      _ToolButton(
                        icon: Icons.swap_horiz,
                        label: 'Change card',
                        onTap: onPick,
                      ),
                      const SizedBox(width: 6),
                    ],
                    _ToolButton(
                      icon: Icons.delete_outline,
                      label: 'Remove slot',
                      onTap: onRemove,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The widget for a card spec at a slot size, and the size it chose.
(Widget, CardSize) cardContent(CardSpec spec, Size space, CardSources sources) {
  switch (spec.type) {
    case 'clock':
      final s = spec.pinned ?? _clockSize(space);
      return (ClockCard(s), s);
    case 'chips':
      return (
        ChipRow([for (final i in spec.items) modelFor(i, sources)]),
        CardSize.pill,
      );
    default:
      final m = modelFor(spec, sources);
      final s = spec.pinned ?? fitSize(m, space);
      return (DashCard(m, s), s);
  }
}

CardSize _clockSize(Size s) {
  if (s.height < 84 || s.width < 136) return CardSize.pill;
  if (s.height < 150) return CardSize.small;
  if (s.height < 260 || s.width < 300) return CardSize.medium;
  return CardSize.large;
}

class _SizeBadge extends StatelessWidget {
  final bool pinned;
  final CardSize size;
  final VoidCallback onTap;
  const _SizeBadge({
    required this.pinned,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Tooltip(
      message: 'Tap to pin a size',
      child: Material(
        color: c.card,
        shape: StadiumBorder(side: BorderSide(color: c.accent, width: 1.5)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(
              '${pinned ? 'pinned' : 'auto'} · ${size.short}',
              style: TextStyle(
                fontSize: 12,
                color: c.accent,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Tooltip(
      message: label,
      child: Material(
        color: c.accent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 40,
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _EditBar extends StatelessWidget {
  final SplitAxis axis;
  final ValueChanged<SplitAxis> onAxis;
  final VoidCallback onDevices, onSettings, onDone;

  const _EditBar({
    required this.axis,
    required this.onAxis,
    required this.onDevices,
    required this.onSettings,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Material(
      color: c.ink,
      elevation: 8,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Layout',
              style: TextStyle(color: c.screen, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 10),
            SegmentedButton<SplitAxis>(
              showSelectedIcon: false,
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.selected) ? c.ink : c.screen,
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.selected)
                      ? c.screen
                      : Colors.transparent,
                ),
                visualDensity: VisualDensity.compact,
              ),
              segments: const [
                ButtonSegment(
                  value: SplitAxis.horizontal,
                  label: Text('Columns'),
                ),
                ButtonSegment(value: SplitAxis.vertical, label: Text('Rows')),
              ],
              selected: {axis},
              onSelectionChanged: (s) => onAxis(s.single),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Devices',
              onPressed: onDevices,
              icon: Icon(Icons.bluetooth_searching, color: c.screen),
            ),
            IconButton(
              tooltip: 'Settings',
              onPressed: onSettings,
              icon: Icon(Icons.settings_outlined, color: c.screen),
            ),
            const SizedBox(width: 4),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: onDone,
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A faint corner button for people who don't know about long-press.
class _MenuButton extends StatelessWidget {
  final VoidCallback onEdit, onDevices, onSettings;
  const _MenuButton({
    required this.onEdit,
    required this.onDevices,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Opacity(
      opacity: 0.45,
      child: PopupMenuButton<VoidCallback>(
        tooltip: 'Menu',
        icon: Icon(Icons.more_horiz, color: c.muted),
        onSelected: (f) => f(),
        itemBuilder: (context) => [
          PopupMenuItem(value: onEdit, child: const Text('Edit dashboard')),
          PopupMenuItem(value: onDevices, child: const Text('Devices')),
          PopupMenuItem(value: onSettings, child: const Text('Settings')),
        ],
      ),
    );
  }
}

class _DashedOutline extends CustomPainter {
  final Color color;
  final double width;
  _DashedOutline(this.color, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(width / 2),
      const Radius.circular(20),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 14) {
        canvas.drawPath(m.extractPath(d, d + 8), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline old) =>
      old.color != color || old.width != width;
}
