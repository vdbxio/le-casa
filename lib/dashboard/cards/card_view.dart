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
    return Opacity(
      opacity: model.stale ? 0.55 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.card, borderRadius: _radius),
        child: ClipRRect(
          borderRadius: _radius,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: pad + 2, vertical: pad),
            child: LayoutBuilder(
              builder: (context, box) => switch (size) {
                CardSize.small => _small(context, c),
                CardSize.medium => _medium(context, c, box.maxWidth),
                _ => _large(context, c, box.maxWidth),
              },
            ),
          ),
        ),
      ),
    );
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

  Widget _small(BuildContext context, LeColors c) {
    final second =
        model.note ??
        model.state ??
        model.details.where((d) => !d.minor).firstOrNull?.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, c),
        const Spacer(),
        if (model.headline != null)
          _headline(c, CardMetrics.headlineSize(CardSize.small)),
        if (second != null) ...[const SizedBox(height: 4), _line(c, second)],
      ],
    );
  }

  Widget _medium(BuildContext context, LeColors c, double w) {
    final showRing = model.ring != null && w >= ringMediumMinWidth;
    if (showRing) {
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
                  child: _detailGrid(
                    c,
                    model.details.take(2).toList(),
                    w - 112,
                    maxCols: 1,
                  ),
                ),
              ],
            ),
          ),
          _noteOrNothing(c),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, c),
        const SizedBox(height: CardMetrics.gap),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: _headline(c, CardMetrics.headlineSize(CardSize.medium)),
            ),
            if (model.state != null) ...[
              const SizedBox(width: 10),
              _chip(c, model.state!),
            ],
          ],
        ),
        const Spacer(),
        if (model.shares.isNotEmpty) ...[
          ShareBar(model.shares, c),
          const SizedBox(height: 8),
          ShareLine(model.shares, c),
        ] else if (model.note != null)
          _line(c, model.note!)
        else
          _line(
            c,
            model.details
                .where((d) => !d.minor)
                .take(3)
                .map((d) => d.summary)
                .join(' · '),
            size: 14,
          ),
      ],
    );
  }

  Widget _large(BuildContext context, LeColors c, double w) {
    final showRing = model.ring != null && w >= ringLargeMinWidth;
    final top = <Widget>[
      _header(context, c, showSubtitle: true),
      const SizedBox(height: CardMetrics.gap),
    ];
    if (showRing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...top,
          Row(
            children: [
              Ring(
                value: model.ring!,
                color: _tone(c),
                track: c.card2,
                size: CardMetrics.ringLarge,
                label: model.headline,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (model.state != null) ...[
                      _chip(c, model.state!),
                      const SizedBox(height: 10),
                    ],
                    _detailGrid(
                      c,
                      model.details,
                      w - CardMetrics.ringLarge - 20,
                      maxCols: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
          Expanded(child: _spark(c)),
          _noteOrNothing(c),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...top,
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: _headline(c, CardMetrics.headlineSize(CardSize.large)),
            ),
            if (model.state != null) ...[
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _chip(c, model.state!),
              ),
            ],
          ],
        ),
        if (model.shares.isNotEmpty) ...[
          const SizedBox(height: 12),
          ShareBar(model.shares, c),
          const SizedBox(height: 6),
          for (final (i, s) in model.shares.indexed) _shareRow(c, s, i),
        ],
        Expanded(child: _spark(c)),
        if (model.hours.isNotEmpty) ...[
          HoursStrip(model.hours, c),
          const SizedBox(height: CardMetrics.gap),
        ],
        _detailGrid(c, model.details, w),
        if (model.note != null) ...[
          const SizedBox(height: 6),
          _line(c, model.note!),
        ],
      ],
    );
  }

  Widget _spark(LeColors c) => LayoutBuilder(
    builder: (context, box) {
      final s = model.series;
      if (s == null || box.maxHeight < 32) return const SizedBox.expand();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: math.min(box.maxHeight - 16, 90),
            width: double.infinity,
            child: CustomPaint(painter: SparkPainter(s, _tone(c))),
          ),
        ),
      );
    },
  );

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
  Widget build(BuildContext context) {
    final total = shares.fold(0.0, (a, s) => a + s.amount);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 10,
        child: total <= 0
            ? ColoredBox(color: c.card2)
            : Row(
                children: [
                  for (final (i, s) in shares.indexed) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: math.max(1, (s.amount / total * 1000).round()),
                      child: ColoredBox(color: shareColor(c, i)),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
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

class HoursStrip extends StatelessWidget {
  final List<HourCell> hours;
  final LeColors c;
  const HoursStrip(this.hours, this.c, {super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: CardMetrics.hoursHeight,
    child: Row(
      children: [
        for (final (i, h) in hours.indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: c.card2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(h.label, style: TextStyle(fontSize: 12, color: c.muted)),
                  const SizedBox(height: 3),
                  Icon(h.icon, size: 20, color: c.climate),
                  const SizedBox(height: 3),
                  Text(h.value, style: numberStyle(17, c.ink)),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
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
  SparkPainter(this.values, this.color);

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
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(pt(values.length - 1), 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparkPainter old) =>
      old.values != values || old.color != color;
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
