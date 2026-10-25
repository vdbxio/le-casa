// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/dashed_outline.dart';
import '../../ui/palette.dart';
import '../layout.dart';
import 'card_model.dart';
import 'card_view.dart';
import 'template.dart';

/// Space between boxes in a stack and in a row.
const _gapV = 8.0, _gapH = 12.0;

/// The card's inner padding.
const templatePadding = EdgeInsets.symmetric(horizontal: 18, vertical: 16);

/// A box placed on the card.
class PlacedPart {
  final NodePath path;
  final BoxPart part;
  final Rect rect;
  const PlacedPart(this.path, this.part, this.rect);
}

/// The line between two neighbouring boxes, where a handle trades space.
class Seam {
  final NodePath split;
  final int index;
  final SplitAxis axis;
  final Rect rect;

  /// The two boxes' combined length along [axis], to turn a drag into a
  /// share.
  final double pair;
  const Seam(this.split, this.index, this.axis, this.rect, this.pair);
}

class TemplatePlan {
  final List<PlacedPart> parts;
  final List<Seam> seams;

  /// Boxes with no room at this size. A graph among them is drawn behind
  /// the others instead.
  final List<BoxPart> hidden;
  const TemplatePlan(this.parts, this.seams, this.hidden);
}

/// The least room a box needs along [axis].
double minExtent(CardBox b, SplitAxis axis) {
  final down = axis == SplitAxis.vertical;
  switch (b) {
    case BoxPart(:final kind):
      return switch (kind) {
        null => down ? 28 : 44,
        PartKind.title => down ? 22 : 80,
        PartKind.big => down ? 30 : 64,
        PartKind.reading => down ? 36 : 60,
        PartKind.chip => down ? 24 : 54,
        PartKind.graph => down ? 26 : 60,
        PartKind.bars => down ? 34 : 90,
        PartKind.ring => 60,
        PartKind.split => down ? 30 : 100,
        PartKind.note => down ? 18 : 80,
      };
    case BoxSplit(:final children, axis: final along):
      // A group can drop its own boxes from the end, so along its axis it
      // needs only room for its first one.
      if (along == axis) return minExtent(children.first, axis);
      return children.map((c) => minExtent(c, axis)).fold(0.0, math.max);
  }
}

bool _fixed(CardBox b, SplitAxis axis) =>
    axis == SplitAxis.vertical && b is BoxPart && (b.kind?.fixed ?? false);

/// Where every box of [t] goes in [area]. Boxes that do not fit drop out
/// from the end of their stack, so the top of the card stays; with
/// [keepAll] (the card options preview) every box is kept and squeezed.
TemplatePlan planTemplate(CardTemplate t, Rect area, {bool keepAll = false}) {
  final parts = <PlacedPart>[];
  final seams = <Seam>[];
  final hidden = <BoxPart>[];

  void hide(CardBox b) {
    switch (b) {
      case BoxPart():
        hidden.add(b);
      case BoxSplit():
        b.children.forEach(hide);
    }
  }

  void place(CardBox b, NodePath path, Rect r) {
    if (b is BoxPart) {
      parts.add(PlacedPart(path, b, r));
      return;
    }
    final s = b as BoxSplit;
    final down = s.axis == SplitAxis.vertical;
    final gap = down ? _gapV : _gapH;
    final length = down ? r.height : r.width;
    final mins = [for (final c in s.children) minExtent(c, s.axis)];

    // Drop boxes from the end until the rest fit.
    var shown = s.children.length;
    double need(int n) =>
        mins.take(n).fold(0.0, (a, m) => a + m) + gap * (n - 1);
    if (!keepAll) {
      while (shown > 1 && need(shown) > length) {
        shown--;
      }
      for (var i = shown; i < s.children.length; i++) {
        hide(s.children[i]);
      }
    }

    // Fixed boxes keep their natural size; the rest share what is left by
    // weight, each getting at least its minimum where there is room.
    final sizes = List<double>.filled(shown, 0);
    var free = length - gap * (shown - 1);
    final flex = <int>[];
    for (var i = 0; i < shown; i++) {
      if (_fixed(s.children[i], s.axis)) {
        sizes[i] = mins[i];
        free -= mins[i];
      } else {
        flex.add(i);
      }
    }
    if (flex.isEmpty && shown > 0) {
      // Only fixed boxes: the last one takes the spare room.
      sizes[shown - 1] += math.max(0, free);
    } else {
      var open = [...flex];
      var left = math.max(0.0, free);
      for (var pass = 0; pass < flex.length && open.isNotEmpty; pass++) {
        final total = open.fold(0.0, (a, i) => a + s.weights[i]);
        final short = [
          for (final i in open)
            if (left * s.weights[i] / total < mins[i] && left >= mins[i]) i,
        ];
        if (short.isEmpty) break;
        for (final i in short) {
          sizes[i] = mins[i];
          left -= mins[i];
        }
        open = [
          for (final i in open)
            if (!short.contains(i)) i,
        ];
      }
      final total = open.fold(0.0, (a, i) => a + s.weights[i]);
      for (final i in open) {
        sizes[i] = total == 0 ? 0 : left * s.weights[i] / total;
      }
    }

    var at = down ? r.top : r.left;
    for (var i = 0; i < shown; i++) {
      final cr = down
          ? Rect.fromLTWH(r.left, at, r.width, math.max(0, sizes[i]))
          : Rect.fromLTWH(at, r.top, math.max(0, sizes[i]), r.height);
      place(s.children[i], [...path, i], cr);
      at += sizes[i];
      // Fixed boxes keep their size, so only a pair of growing boxes gets
      // a handle.
      if (i < shown - 1 &&
          !_fixed(s.children[i], s.axis) &&
          !_fixed(s.children[i + 1], s.axis)) {
        seams.add(
          Seam(
            path,
            i,
            s.axis,
            down
                ? Rect.fromLTWH(r.left, at, r.width, gap)
                : Rect.fromLTWH(at, r.top, gap, r.height),
            sizes[i] + sizes[i + 1],
          ),
        );
      }
      at += gap;
    }
  }

  place(t.root, const [], area);
  return TemplatePlan(parts, seams, hidden);
}

/// What the card options screen needs from the preview.
class TemplateEditing {
  final NodePath? selected;
  final ValueChanged<NodePath> onSelect;
  final void Function(Seam seam, double delta) onResize;
  const TemplateEditing({
    required this.selected,
    required this.onSelect,
    required this.onResize,
  });
}

/// Draws a card from its [template] at whatever size it is given.
class TemplateCard extends StatelessWidget {
  final CardModel model;
  final CardTemplate template;
  final TemplateEditing? editing;
  const TemplateCard(this.model, this.template, {super.key, this.editing});

  static const _radius = BorderRadius.all(Radius.circular(20));

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final points = dataPoints(model);
    final edit = editing;
    final card = DecoratedBox(
      decoration: BoxDecoration(color: c.card, borderRadius: _radius),
      child: ClipRRect(
        borderRadius: _radius,
        child: LayoutBuilder(
          builder: (context, box) {
            final area = templatePadding.deflateRect(Offset.zero & box.biggest);
            final plan = planTemplate(template, area, keepAll: edit != null);
            final behind = plan.hidden
                .where(
                  (p) => p.kind == PartKind.graph || p.kind == PartKind.bars,
                )
                .firstOrNull;
            return Stack(
              children: [
                if (behind != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: box.maxHeight * 0.6,
                    child: IgnorePointer(
                      child: _part(context, c, behind, points, faint: true),
                    ),
                  ),
                for (final p in plan.parts)
                  Positioned.fromRect(
                    rect: p.rect,
                    child: edit == null
                        ? _part(context, c, p.part, points)
                        : _EditableBox(
                            selected: _same(edit.selected, p.path),
                            empty: p.part.isEmpty,
                            onTap: () => edit.onSelect(p.path),
                            child: _part(context, c, p.part, points),
                          ),
                  ),
                if (edit != null)
                  for (final s in plan.seams) _handle(c, s, edit),
              ],
            );
          },
        ),
      ),
    );
    return model.stale && edit == null
        ? Opacity(opacity: 0.55, child: card)
        : card;
  }

  static bool _same(NodePath? a, NodePath b) =>
      a != null &&
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  Widget _handle(LeColors c, Seam s, TemplateEditing edit) {
    final down = s.axis == SplitAxis.vertical;
    // A wider strip than the gap, so the handle is easy to catch.
    final r = down
        ? Rect.fromCenter(
            center: s.rect.center,
            width: s.rect.width,
            height: 22,
          )
        : Rect.fromCenter(
            center: s.rect.center,
            width: 22,
            height: s.rect.height,
          );
    return Positioned.fromRect(
      rect: r,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: down
            ? (d) => edit.onResize(s, d.delta.dy / s.pair)
            : null,
        onHorizontalDragUpdate: down
            ? null
            : (d) => edit.onResize(s, d.delta.dx / s.pair),
        child: Center(
          child: Container(
            width: down ? 34 : 5,
            height: down ? 5 : 34,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }

  Alignment _align(PartAlign a, {double y = 0}) => switch (a) {
    PartAlign.start => Alignment(-1, y),
    PartAlign.center => Alignment(0, y),
    PartAlign.end => Alignment(1, y),
  };

  CrossAxisAlignment _cross(PartAlign a) => switch (a) {
    PartAlign.start => CrossAxisAlignment.start,
    PartAlign.center => CrossAxisAlignment.center,
    PartAlign.end => CrossAxisAlignment.end,
  };

  TextAlign _text(PartAlign a) => switch (a) {
    PartAlign.start => TextAlign.left,
    PartAlign.center => TextAlign.center,
    PartAlign.end => TextAlign.right,
  };

  Widget _part(
    BuildContext context,
    LeColors c,
    BoxPart part,
    List<DataPoint> points, {
    bool faint = false,
  }) {
    final kind = part.kind;
    if (kind == null) {
      return editing == null
          ? const SizedBox.shrink()
          : Center(child: Icon(Icons.add, color: c.accent, size: 24));
    }
    final p = pointById(points, part.point);
    final tone = c.tone(model.tone);
    final align = part.align;
    switch (kind) {
      case PartKind.title:
        return Align(
          alignment: _align(align),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(model.icon, size: 20, color: tone),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  model.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: c.ink,
                  ),
                ),
              ),
            ],
          ),
        );
      case PartKind.big:
        final m = p?.metric ?? _missing(part.point);
        return LayoutBuilder(
          builder: (context, box) {
            final size = math.min(110.0, math.max(20.0, box.maxHeight * 0.86));
            return Align(
              alignment: _align(align, y: 0.4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: _align(align),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: m.value, style: numberStyle(size, c.ink)),
                      if (m.unit.isNotEmpty)
                        TextSpan(
                          text: ' ${m.unit}',
                          style: numberStyle(
                            size * 0.42,
                            c.muted,
                          ).copyWith(fontWeight: FontWeight.w500),
                        ),
                    ],
                  ),
                  maxLines: 1,
                ),
              ),
            );
          },
        );
      case PartKind.reading:
        final m = p?.metric ?? _missing(part.point);
        return LayoutBuilder(
          builder: (context, box) {
            final size = math.min(
              48.0,
              math.max(14.0, (box.maxHeight - 16) * 0.8),
            );
            return Column(
              crossAxisAlignment: _cross(align),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  m.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.6,
                    color: c.muted,
                  ),
                ),
                const SizedBox(height: 2),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: _align(align),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: m.value,
                            style: numberStyle(size, c.ink),
                          ),
                          if (m.unit.isNotEmpty)
                            TextSpan(
                              text: ' ${m.unit}',
                              style: TextStyle(
                                fontSize: size * 0.6,
                                color: c.muted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      case PartKind.chip:
        final text = p?.preview ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        return Align(
          alignment: _align(align),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              text[0].toUpperCase() + text.substring(1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: tone,
              ),
            ),
          ),
        );
      case PartKind.graph:
        final s = model.series;
        if (s == null) return _empty(c, 'No history yet');
        return CustomPaint(
          painter: SparkPainter(s, tone, faint: faint),
          size: Size.infinite,
        );
      case PartKind.bars:
        if (model.hours.isEmpty) return _empty(c, 'No forecast');
        return HourBars(
          model.hours,
          c,
          caption: model.hoursLabel,
          faint: faint,
        );
      case PartKind.ring:
        final v = model.ring;
        if (v == null) return _empty(c, 'No level');
        return LayoutBuilder(
          builder: (context, box) => Align(
            alignment: _align(align),
            child: Ring(
              value: v,
              color: tone,
              track: c.card2,
              size: math.min(box.maxWidth, box.maxHeight),
              label: model.headline,
            ),
          ),
        );
      case PartKind.split:
        if (model.shares.isEmpty) return _empty(c, 'Nothing to split');
        return LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ShareBar(model.shares, c),
              if (box.maxHeight >= 34) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: _align(align),
                  child: ShareLine(model.shares, c),
                ),
              ],
            ],
          ),
        );
      case PartKind.note:
        final text = p?.preview ?? '';
        return LayoutBuilder(
          builder: (context, box) => Align(
            alignment: _align(align),
            child: Text(
              text,
              maxLines: math.max(1, (box.maxHeight / 18).floor()),
              overflow: TextOverflow.ellipsis,
              textAlign: _text(align),
              style: TextStyle(fontSize: 13, height: 1.3, color: c.muted),
            ),
          ),
        );
    }
  }

  /// A reading the card does not have right now (a battery that is not
  /// discharging has no "Time to go"): its name and a dash.
  Metric _missing(String? id) {
    final name = id == null || !id.contains(':')
        ? ''
        : id.substring(id.indexOf(':') + 1);
    return Metric(
      name.isEmpty ? '' : name[0].toUpperCase() + name.substring(1),
      '–',
    );
  }

  Widget _empty(LeColors c, String text) => editing == null
      ? const SizedBox.shrink()
      : Center(
          child: Text(text, style: TextStyle(fontSize: 12, color: c.muted)),
        );
}

class _EditableBox extends StatelessWidget {
  final bool selected, empty;
  final VoidCallback onTap;
  final Widget child;
  const _EditableBox({
    required this.selected,
    required this.empty,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: CustomPaint(
        foregroundPainter: DashedOutline(
          selected ? c.accent : c.accent.withValues(alpha: empty ? 0.7 : 0.35),
          selected ? 2.5 : 1.5,
          radius: 8,
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: IgnorePointer(child: child),
        ),
      ),
    );
  }
}
