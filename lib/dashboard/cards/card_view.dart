// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/palette.dart';
import '../layout.dart';
import 'card_model.dart';
import 'fit.dart';

const _radius = BorderRadius.all(Radius.circular(20));

/// Draws any [CardModel] at any [CardSize].
class DashCard extends StatelessWidget {
  final CardModel model;
  final CardSize size;
  const DashCard(this.model, this.size, {super.key});

  @override
  Widget build(BuildContext context) {
    if (size == CardSize.pill) {
      return Center(child: Pill(model));
    }
    final c = LeColors.of(context);
    final pad = size == CardSize.small ? CardMetrics.padSmall : CardMetrics.pad;
    final card = DecoratedBox(
      decoration: BoxDecoration(color: c.card, borderRadius: _radius),
      child: ClipRRect(
        borderRadius: _radius,
        child: LayoutBuilder(
          builder: (context, outer) {
            final slot = outer.biggest;
            final side = sideBySide(model, size, slot);
            final inline = chartInline(model, size, slot);
            return Stack(
              children: [
                // A graph that has no room of its own sits behind the
                // numbers instead of disappearing.
                if (hasChart(model) && !inline)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: slot.height * 0.6,
                    child: IgnorePointer(child: _chart(c, faint: true)),
                  ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: pad + 2,
                    vertical: pad,
                  ),
                  child: LayoutBuilder(
                    builder: (context, box) => side
                        ? _side(context, c, box.biggest)
                        : switch (size) {
                            CardSize.small => _small(context, c, inline),
                            CardSize.medium => _medium(
                              context,
                              c,
                              box.biggest,
                              inline,
                            ),
                            _ => _large(context, c, box.maxWidth, inline),
                          },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    return model.stale ? Opacity(opacity: 0.55, child: card) : card;
  }

  Color _tone(LeColors c) => c.tone(model.tone);

  Widget _header(
    BuildContext context,
    LeColors c, {
    bool showSubtitle = false,
  }) => SizedBox(
    height: CardMetrics.header,
    child: Row(
      children: [
        Icon(model.icon, size: 20, color: _tone(c)),
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
        if (showSubtitle && model.subtitle.isNotEmpty) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              model.subtitle,
              maxLines: 1,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: c.muted,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _headline(LeColors c, double size) {
    final h = model.headline;
    if (h == null) return const SizedBox.shrink();
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: h.value, style: numberStyle(size, c.ink)),
            if (h.unit.isNotEmpty)
              TextSpan(
                text: ' ${h.unit}',
                style: numberStyle(
                  size * 0.42,
                  c.muted,
                ).copyWith(fontWeight: FontWeight.w500),
              ),
          ],
        ),
        maxLines: 1,
      ),
    );
  }

  Widget _chip(LeColors c, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: _tone(c).withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1),
      maxLines: 1,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: _tone(c),
      ),
    ),
  );

  Widget _line(LeColors c, String text, {double size = 13}) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: size, color: c.muted),
  );

  Widget _noteOrNothing(LeColors c) =>
      model.note == null ? const SizedBox.shrink() : _line(c, model.note!);

  /// The graph: the history line, or the forecast bars.
  Widget _chart(LeColors c, {bool faint = false}) => model.hours.isNotEmpty
      ? HourBars(model.hours, c, caption: model.hoursLabel, faint: faint)
      : CustomPaint(
          painter: SparkPainter(model.series!, _tone(c), faint: faint),
          size: Size.infinite,
        );

  List<Metric> get _major => model.details.where((d) => !d.minor).toList();

  String? get _summary {
    final m = _major.take(3).map((d) => d.summary).join(' · ');
    return m.isEmpty ? null : m;
  }

  /// As many rows of [items] as fit the space it is given, bottom aligned.
  /// When not even one row fits, [fallback] instead.
  Widget _fillDetails(LeColors c, List<Metric> items, {Widget? fallback}) =>
      LayoutBuilder(
        builder: (context, box) {
          final cols = CardMetrics.detailColumns(box.maxWidth);
          final rows =
              ((box.maxHeight + CardMetrics.detailGap) /
                      (CardMetrics.detailHeight + CardMetrics.detailGap))
                  .floor();
          final shown = rows <= 0
              ? const <Metric>[]
              : items.take(rows * cols).toList();
          return Align(
            alignment: Alignment.bottomLeft,
            child: shown.isEmpty
                ? (fallback ?? const SizedBox.shrink())
                : _detailGrid(c, shown, box.maxWidth),
          );
        },
      );

  Widget _headlineRow(LeColors c, CardSize s, {double? fontSize}) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Flexible(child: _headline(c, fontSize ?? CardMetrics.headlineSize(s))),
      if (model.state != null && s != CardSize.small) ...[
        const SizedBox(width: 10),
        Padding(
          padding: EdgeInsets.only(bottom: s == CardSize.large ? 8 : 0),
          child: _chip(c, model.state!),
        ),
      ],
    ],
  );

  /// The headline grown into the spare height (up to about twice its
  /// size), so a card without a graph of its own has no empty band.
  Widget _grownHeadline(LeColors c, CardSize s, {bool withState = true}) =>
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            final base = CardMetrics.headlineSize(s);
            final most = switch (s) {
              CardSize.large => 1.5,
              CardSize.medium => 1.8,
              _ => 2.0,
            };
            final size = math.min(
              base * most,
              math.max(base, box.maxHeight * 0.85),
            );
            return Align(
              alignment: Alignment.bottomLeft,
              child: withState
                  ? _headlineRow(c, s, fontSize: size)
                  : _headline(c, size),
            );
          },
        ),
      );

  Widget _small(BuildContext context, LeColors c, bool inline) {
    final second = model.note ?? model.state ?? _major.firstOrNull?.summary;
    final numbers = [
      if (model.headline != null)
        _headline(c, CardMetrics.headlineSize(CardSize.small)),
      if (second != null) ...[const SizedBox(height: 4), _line(c, second)],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, c),
        if (inline) ...[
          const SizedBox(height: 6),
          ...numbers,
          const SizedBox(height: CardMetrics.gap),
          Expanded(child: _chart(c)),
        ] else ...[
          if (model.headline != null)
            _grownHeadline(c, CardSize.small, withState: false)
          else
            const Spacer(),
          if (second != null) ...[const SizedBox(height: 4), _line(c, second)],
        ],
      ],
    );
  }

  /// The bottom line of a medium card: the split of the total, a note, or
  /// a summary of the main readings.
  Widget? _mediumFooter(LeColors c) {
    if (model.shares.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ShareBar(model.shares, c),
          const SizedBox(height: 8),
          ShareLine(model.shares, c),
        ],
      );
    }
    final text = model.note ?? _summary;
    return text == null ? null : _line(c, text, size: 14);
  }

  Widget _medium(BuildContext context, LeColors c, Size box, bool inline) {
    final w = box.width;
    final showRing = model.ring != null && w >= ringMediumMinWidth;
    if (showRing) {
      final summary = _summary;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, c),
          const SizedBox(height: CardMetrics.gap),
          Expanded(
            child: Row(
              children: [
                Ring(
                  value: model.ring!,
                  color: _tone(c),
                  track: c.card2,
                  size: CardMetrics.ringMedium,
                  label: model.headline,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _fillDetails(
                    c,
                    model.details,
                    fallback: summary == null ? null : _line(c, summary),
                  ),
                ),
              ],
            ),
          ),
          _noteOrNothing(c),
        ],
      );
    }
    final footer = _mediumFooter(c);
    final top = [
      _header(context, c),
      const SizedBox(height: CardMetrics.gap),
      _headlineRow(c, CardSize.medium),
    ];
    if (inline) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...top,
          const SizedBox(height: CardMetrics.gap),
          Expanded(child: _chart(c)),
          if (footer != null) ...[
            const SizedBox(height: CardMetrics.gap),
            footer,
          ],
        ],
      );
    }
    // No graph here: spare height goes to more readings, then to a bigger
    // number, never to a gap.
    final fillable = model.shares.isEmpty && model.note == null;
    final spare =
        box.height -
        CardMetrics.header -
        CardMetrics.gap * 2 -
        CardMetrics.headlineSize(CardSize.medium) * 1.15;
    final rows = !fillable
        ? 0
        : math.max(
            0,
            ((spare + CardMetrics.detailGap) /
                    (CardMetrics.detailHeight + CardMetrics.detailGap))
                .floor(),
          );
    final shown = _major.take(rows * CardMetrics.detailColumns(w)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, c),
        const SizedBox(height: CardMetrics.gap),
        _grownHeadline(c, CardSize.medium),
        if (shown.isNotEmpty) ...[
          const SizedBox(height: CardMetrics.gap),
          _detailGrid(c, shown, w),
        ] else if (footer != null) ...[
          const SizedBox(height: CardMetrics.gap),
          footer,
        ],
      ],
    );
  }

  Widget _large(BuildContext context, LeColors c, double w, bool inline) {
    final grow = !inline;
    final showRing = model.ring != null && w >= ringLargeMinWidth;
    final top = <Widget>[
      _header(context, c, showSubtitle: true),
      const SizedBox(height: CardMetrics.gap),
    ];
    final chart = inline
        ? Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _chart(c),
            ),
          )
        : const Spacer();
    if (showRing) {
      Widget ringRow(double ring) => Row(
        children: [
          Ring(
            value: model.ring!,
            color: _tone(c),
            track: c.card2,
            size: ring,
            label: model.headline,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (model.state != null) ...[
                  _chip(c, model.state!),
                  const SizedBox(height: 10),
                ],
                _detailGrid(c, model.details, w - ring - 20, maxCols: 2),
              ],
            ),
          ),
        ],
      );
      if (grow) {
        // No graph of its own: the ring grows into the spare height.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...top,
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Align(
                  alignment: Alignment.centerLeft,
                  // Never so big that the readings beside it lose a column.
                  child: ringRow(
                    [
                      box.maxHeight,
                      w - 20 - 2 * CardMetrics.detailWidth - 16,
                      240.0,
                    ].reduce(math.min).clamp(CardMetrics.ringLarge, 240.0),
                  ),
                ),
              ),
            ),
            _noteOrNothing(c),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...top,
          ringRow(CardMetrics.ringLarge),
          chart,
          _noteOrNothing(c),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...top,
        if (grow)
          _grownHeadline(c, CardSize.large)
        else
          _headlineRow(c, CardSize.large),
        if (model.shares.isNotEmpty) ...[
          const SizedBox(height: 12),
          ShareBar(model.shares, c),
          const SizedBox(height: 6),
          for (final (i, s) in model.shares.indexed) _shareRow(c, s, i),
        ],
        if (!grow) chart else const SizedBox(height: CardMetrics.gap),
        _detailGrid(c, model.details, w),
        if (model.note != null) ...[
          const SizedBox(height: 6),
          _line(c, model.note!),
        ],
      ],
    );
  }

  /// Wide and short: the numbers on the left, the graph (or more
  /// readings) on the right.
  Widget _side(BuildContext context, LeColors c, Size box) {
    final leftW = (box.width * 0.45).clamp(170.0, 300.0);
    final medium = size == CardSize.medium;
    // The state gets its own chip on a medium card, so the number keeps
    // its full size.
    final chip = medium ? model.state : null;
    final second = model.shares.isNotEmpty
        ? null
        : (model.note ??
              (medium ? null : model.state) ??
              _major.firstOrNull?.summary);
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, c),
        const Spacer(),
        _headline(c, CardMetrics.headlineSize(size)),
        if (chip != null) ...[const SizedBox(height: 6), _chip(c, chip)],
        if (model.shares.isNotEmpty) ...[
          const SizedBox(height: 6),
          ShareLine(model.shares, c),
        ] else if (second != null) ...[
          const SizedBox(height: 4),
          _line(c, second),
        ],
      ],
    );
    final rest = hasChart(model)
        ? _chart(c)
        : _fillDetails(
            c,
            model.details.where((d) => d.summary != second).toList(),
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: leftW, child: left),
        const SizedBox(width: 16),
        Expanded(child: rest),
      ],
    );
  }

  Widget _shareRow(LeColors c, Share s, int i) => SizedBox(
    height: CardMetrics.shareRow,
    child: Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: shareColor(c, i),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: c.ink,
              fontSize: 14,
            ),
          ),
        ),
        Text(s.value, style: numberStyle(17, c.ink)),
        for (final e in s.extra) ...[
          const SizedBox(width: 14),
          Text(
            e,
            style: TextStyle(
              color: c.muted,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    ),
  );

  Widget _detailGrid(
    LeColors c,
    List<Metric> items,
    double w, {
    int maxCols = 4,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cols = math.min(maxCols, CardMetrics.detailColumns(w));
    final itemW = (w - (cols - 1) * 16) / cols;
    return Wrap(
      spacing: 16,
      runSpacing: CardMetrics.detailGap,
      children: [
        for (final m in items)
          SizedBox(
            width: itemW,
            height: CardMetrics.detailHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
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
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: m.value, style: numberStyle(23, c.ink)),
                        if (m.unit.isNotEmpty)
                          TextSpan(
                            text: ' ${m.unit}',
                            style: TextStyle(
                              fontSize: 14,
                              color: c.muted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

Color shareColor(LeColors c, int i) => i.isEven ? c.solar : c.solar2;

/// Each part's share of the total as one bar.
class ShareBar extends StatelessWidget {
  final List<Share> shares;
  final LeColors c;
  const ShareBar(this.shares, this.c, {super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 10,
    width: double.infinity,
    child: CustomPaint(painter: _ShareBarPainter(shares, c)),
  );
}

class _ShareBarPainter extends CustomPainter {
  final List<Share> shares;
  final LeColors c;
  _ShareBarPainter(this.shares, this.c);

  @override
  void paint(Canvas canvas, Size size) {
    final total = shares.fold(0.0, (a, s) => a + s.amount);
    final r = Radius.circular(size.height / 2);
    if (total <= 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, r),
        Paint()..color = c.card2,
      );
      return;
    }
    const gap = 2.0;
    final usable = size.width - gap * (shares.length - 1);
    var x = 0.0;
    for (final (i, s) in shares.indexed) {
      final w = usable * s.amount / total;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, 0, w, size.height),
          topLeft: i == 0 ? r : Radius.zero,
          bottomLeft: i == 0 ? r : Radius.zero,
          topRight: i == shares.length - 1 ? r : Radius.zero,
          bottomRight: i == shares.length - 1 ? r : Radius.zero,
        ),
        Paint()..color = shareColor(c, i),
      );
      x += w + gap;
    }
  }

  @override
  bool shouldRepaint(_ShareBarPainter old) =>
      old.shares != shares || old.c != c;
}

/// "Luna 50 412 W   Sol 30 236 W" on one line, or nothing at all when it
/// does not fit. Sub info is all or nothing so a cut-off split never
/// misleads.
class ShareLine extends StatelessWidget {
  final List<Share> shares;
  final LeColors c;
  const ShareLine(this.shares, this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(
      children: [
        for (final (i, s) in shares.indexed) ...[
          if (i > 0) const TextSpan(text: '    '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              width: 9,
              height: 9,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: shareColor(c, i),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          TextSpan(
            text: '${s.name} ',
            style: TextStyle(color: c.muted),
          ),
          TextSpan(
            text: s.value,
            style: TextStyle(color: c.ink, fontWeight: FontWeight.w600),
          ),
        ],
      ],
      style: const TextStyle(fontSize: 13),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final plain = shares.map((s) => '■ ${s.name} ${s.value}').join('    ');
        final tp = TextPainter(
          text: TextSpan(
            text: plain,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final fits = tp.width <= box.maxWidth;
        tp.dispose();
        return fits ? Text.rich(span, maxLines: 1) : const SizedBox.shrink();
      },
    );
  }
}

/// The forecast as bars, the value and an icon above each, under a caption
/// for the whole range ("Next 6 hours"). As the space shrinks the icons go
/// first, then the values, then the caption. [faint] draws just the bars,
/// for behind the numbers.
class HourBars extends StatelessWidget {
  final List<HourCell> hours;
  final LeColors c;
  final String? caption;
  final bool faint;
  const HourBars(
    this.hours,
    this.c, {
    super.key,
    this.caption,
    this.faint = false,
  });

  static const captionHeight = 16.0;
  static const valueHeight = 18.0;
  static const iconHeight = 20.0;
  static const minBar = 14.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final showCaption =
          !faint && caption != null && box.maxHeight >= captionHeight + minBar;
      var rest = box.maxHeight - (showCaption ? captionHeight : 0);
      final showValue = !faint && rest >= valueHeight + minBar;
      if (showValue) rest -= valueHeight;
      final showIcon = !faint && rest >= iconHeight + minBar;
      if (showIcon) rest -= iconHeight;
      final amounts = [for (final h in hours) h.amount];
      final hi = amounts.reduce(math.max), lo = amounts.reduce(math.min);
      // Bars start below the lowest value, so the lowest still has height.
      final floor = lo - math.max(2.0, (hi - lo) * 0.6);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCaption)
            SizedBox(
              height: captionHeight,
              child: Text(
                caption!,
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: c.muted),
              ),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, h) in hours.indexed) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (showIcon)
                          SizedBox(
                            height: iconHeight,
                            child: Icon(h.icon, size: 17, color: c.climate),
                          ),
                        if (showValue)
                          SizedBox(
                            height: valueHeight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                h.value,
                                style: numberStyle(15, c.ink),
                              ),
                            ),
                          ),
                        Container(
                          height: math.max(
                            3,
                            math.max(0.0, rest) *
                                (h.amount - floor) /
                                (hi - floor),
                          ),
                          decoration: BoxDecoration(
                            color: c.climate.withValues(
                              alpha: faint ? 0.12 : (i == 0 ? 0.9 : 0.45),
                            ),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// State of charge as a ring with the number inside.
class Ring extends StatelessWidget {
  final double value;
  final Color color, track;
  final double size;
  final Metric? label;
  const Ring({
    super.key,
    required this.value,
    required this.color,
    required this.track,
    required this.size,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(value / 100, color, track),
        child: Center(
          child: label == null
              ? null
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: FittedBox(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: label!.value,
                            style: numberStyle(size * 0.3, c.ink),
                          ),
                          TextSpan(
                            text: label!.unit,
                            style: numberStyle(size * 0.13, c.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double t;
  final Color color, track;
  _RingPainter(this.t, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final r = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * t.clamp(0, 1),
      false,
      p..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.t != t || old.color != color || old.track != track;
}

/// A sparkline: line, soft area fill, dot on the latest value.
class SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;

  /// Softer, without the end dot, for behind a card's numbers.
  final bool faint;
  SparkPainter(this.values, this.color, {this.faint = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    Offset pt(int i) => Offset(
      i * size.width / (values.length - 1),
      size.height - 4 - (values[i] - lo) / span * (size.height - 8),
    );
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()..color = color.withValues(alpha: faint ? 0.08 : 0.14),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = faint ? color.withValues(alpha: 0.3) : color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    if (!faint) {
      canvas.drawCircle(pt(values.length - 1), 3.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(SparkPainter old) =>
      old.values != values || old.color != color || old.faint != faint;
}

/// The smallest size: icon, one number, a short label.
class Pill extends StatelessWidget {
  final CardModel model;
  final double height;
  const Pill(this.model, {super.key, this.height = CardMetrics.pillHeight});

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final h = model.headline;
    return Opacity(
      opacity: model.stale ? 0.55 : 1,
      child: Container(
        height: height,
        padding: const EdgeInsets.only(left: 14, right: 16),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Icon(model.icon, size: 22, color: c.tone(model.tone)),
            const SizedBox(width: 8),
            Text(
              h == null
                  ? '–'
                  : (h.unit == '%' || h.unit.startsWith('°')
                        ? '${h.value}${h.unit.replaceAll('C', '')}'
                        : h.inline),
              style: numberStyle(21, c.ink),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                model.pillLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Several pills sharing one slot. Shows as many as fit, in order.
class ChipRow extends StatelessWidget {
  final List<CardModel> items;
  const ChipRow(this.items, {super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 8.0, h = 48.0, minW = 150.0;
      final perRow = math.max(1, ((box.maxWidth + gap) / (minW + gap)).floor());
      final rows = math.max(1, ((box.maxHeight + gap) / (h + gap)).floor());
      final shown = items.take(perRow * rows).toList();
      final lines = <List<CardModel>>[
        for (var i = 0; i < shown.length; i += perRow)
          shown.sublist(i, math.min(i + perRow, shown.length)),
      ];
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final (i, line) in lines.indexed) ...[
            if (i > 0) const SizedBox(height: gap),
            Row(
              children: [
                for (final (j, m) in line.indexed) ...[
                  if (j > 0) const SizedBox(width: gap),
                  Expanded(child: Pill(m, height: h)),
                ],
                // Keep pill widths equal on a short last line.
                for (
                  var k = line.length;
                  k < perRow && lines.length > 1;
                  k++
                ) ...[
                  const SizedBox(width: gap),
                  const Expanded(child: SizedBox()),
                ],
              ],
            ),
          ],
        ],
      );
    },
  );
}

/// The clock widget. The time fills whatever space the slot gives it.
class ClockCard extends StatefulWidget {
  final CardSize size;
  const ClockCard(this.size, {super.key});

  @override
  State<ClockCard> createState() => _ClockCardState();
}

class _ClockCardState extends State<ClockCard> {
  late Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 5), (_) {
      final n = DateTime.now();
      if (n.minute != _now.minute) setState(() => _now = n);
    });
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  static const _days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final time =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final day = _days[_now.weekday - 1], month = _months[_now.month - 1];
    final long = '$day ${_now.day} $month';
    final short = '${day.substring(0, 3)} ${_now.day} ${month.substring(0, 3)}';
    if (widget.size == CardSize.pill) {
      return Center(
        child: Pill(
          CardModel(
            title: 'Clock',
            icon: Icons.schedule,
            headline: Metric('Time', time),
            pillLabel: short,
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(color: c.card, borderRadius: _radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.bottomLeft,
                child: Text(time, style: numberStyle(160, c.ink)),
              ),
            ),
            if (widget.size != CardSize.small) ...[
              const SizedBox(height: 6),
              Text(
                widget.size == CardSize.large ? long : short,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: widget.size == CardSize.large ? 22 : 17,
                  fontWeight: FontWeight.w600,
                  color: c.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
