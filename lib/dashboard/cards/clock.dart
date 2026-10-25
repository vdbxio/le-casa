// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/palette.dart';
import '../layout.dart' show CardSize;
import 'card_model.dart';
import 'card_view.dart' show Pill;

/// A typeface for the clock's time or date.
enum ClockFont {
  spartan('League Spartan'),
  system('System'),
  serif('Serif'),
  mono('Monospace');

  final String label;
  const ClockFont(this.label);

  TextStyle style({required double size, required Color color}) {
    final base = TextStyle(fontSize: size, height: 1, color: color);
    return switch (this) {
      spartan => base.copyWith(
        fontFamily: displayFont,
        fontWeight: FontWeight.w600,
        fontVariations: const [FontVariation.weight(600)],
      ),
      system => base.copyWith(fontWeight: FontWeight.w500),
      serif => base.copyWith(fontFamily: 'DMSerifDisplay'),
      mono => base.copyWith(
        fontFamily: 'JetBrainsMono',
        fontVariations: const [FontVariation.weight(500)],
      ),
    };
  }
}

/// How the date under the time is written.
enum DateWords {
  /// Full words when the card is large, short words otherwise.
  auto('Fit the card'),
  full('Full words'),
  short('Short words'),
  numeric('Numbers'),
  none('No date');

  final String label;
  const DateWords(this.label);
}

/// The order of day, month and year.
enum DateOrder {
  dmy('Day month'),
  mdy('Month day'),
  ymd('Year first');

  final String label;
  const DateOrder(this.label);
}

/// The clock card's choices from card options.
class ClockStyle {
  final bool h24;
  final ClockFont font;
  final DateWords date;
  final DateOrder order;
  final bool weekday;
  final bool year;
  final bool caps;
  final ClockFont dateFont;

  const ClockStyle({
    this.h24 = true,
    this.font = ClockFont.spartan,
    this.date = DateWords.auto,
    this.order = DateOrder.dmy,
    this.weekday = true,
    this.year = false,
    this.caps = false,
    this.dateFont = ClockFont.system,
  });

  ClockStyle copyWith({
    bool? h24,
    ClockFont? font,
    DateWords? date,
    DateOrder? order,
    bool? weekday,
    bool? year,
    bool? caps,
    ClockFont? dateFont,
  }) => ClockStyle(
    h24: h24 ?? this.h24,
    font: font ?? this.font,
    date: date ?? this.date,
    order: order ?? this.order,
    weekday: weekday ?? this.weekday,
    year: year ?? this.year,
    caps: caps ?? this.caps,
    dateFont: dateFont ?? this.dateFont,
  );

  /// Only what differs from the default, so plain clocks save nothing.
  Map<String, Object?> toJson() {
    const d = ClockStyle();
    return {
      if (h24 != d.h24) 'h24': h24,
      if (font != d.font) 'f': font.name,
      if (date != d.date) 'd': date.name,
      if (order != d.order) 'o': order.name,
      if (weekday != d.weekday) 'w': weekday,
      if (year != d.year) 'y': year,
      if (caps != d.caps) 'c': caps,
      if (dateFont != d.dateFont) 'df': dateFont.name,
    };
  }

  static ClockStyle fromJson(Map<String, Object?> j) {
    const d = ClockStyle();
    return ClockStyle(
      h24: j['h24'] as bool? ?? d.h24,
      font: ClockFont.values.asNameMap()[j['f']] ?? d.font,
      date: DateWords.values.asNameMap()[j['d']] ?? d.date,
      order: DateOrder.values.asNameMap()[j['o']] ?? d.order,
      weekday: j['w'] as bool? ?? d.weekday,
      year: j['y'] as bool? ?? d.year,
      caps: j['c'] as bool? ?? d.caps,
      dateFont: ClockFont.values.asNameMap()[j['df']] ?? d.dateFont,
    );
  }

  bool get isDefault => toJson().isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ClockStyle && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  /// The time as digits and an AM/PM suffix (empty in 24 hour mode).
  (String, String) time(DateTime t) {
    final m = t.minute.toString().padLeft(2, '0');
    if (h24) return ('${t.hour.toString().padLeft(2, '0')}:$m', '');
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return ('$h:$m', t.hour < 12 ? 'AM' : 'PM');
  }

  /// The date line, or '' for none. [roomy] picks full words for [auto].
  String dateLine(DateTime t, {required bool roomy}) {
    final words = date == DateWords.auto
        ? (roomy ? DateWords.full : DateWords.short)
        : date;
    if (words == DateWords.none) return '';
    final long = words == DateWords.full;
    var wd = _days[t.weekday - 1];
    if (!long) wd = wd.substring(0, 3);
    final String s;
    if (words == DateWords.numeric) {
      String two(int n) => n.toString().padLeft(2, '0');
      final d = two(t.day), mo = two(t.month), y = '${t.year}';
      final digits = switch (order) {
        DateOrder.dmy => year ? '$d/$mo/$y' : '$d/$mo',
        DateOrder.mdy => year ? '$mo/$d/$y' : '$mo/$d',
        DateOrder.ymd => year ? '$y-$mo-$d' : '$mo-$d',
      };
      s = weekday ? '$wd $digits' : digits;
    } else {
      var mo = _months[t.month - 1];
      if (!long) mo = mo.substring(0, 3);
      final d = t.day, y = t.year;
      s = switch (order) {
        DateOrder.dmy => '${weekday ? '$wd ' : ''}$d $mo${year ? ' $y' : ''}',
        DateOrder.mdy => '${weekday ? '$wd, ' : ''}$mo $d${year ? ', $y' : ''}',
        DateOrder.ymd => '${year ? '$y ' : ''}$mo $d${weekday ? ', $wd' : ''}',
      };
    }
    return caps ? s.toUpperCase() : s;
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
}

/// The clock widget. The time fills whatever space the slot gives it.
class ClockCard extends StatefulWidget {
  final CardSize size;
  final ClockStyle style;

  /// A fixed time instead of now, for previews and tests.
  final DateTime? at;

  const ClockCard(
    this.size, {
    this.style = const ClockStyle(),
    this.at,
    super.key,
  });

  @override
  State<ClockCard> createState() => _ClockCardState();
}

class _ClockCardState extends State<ClockCard> {
  Timer? _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    if (widget.at != null) return;
    _t = Timer.periodic(const Duration(seconds: 5), (_) {
      final n = DateTime.now();
      if (n.minute != _now.minute) setState(() => _now = n);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final style = widget.style;
    final now = widget.at ?? _now;
    final (time, suffix) = style.time(now);
    if (widget.size == CardSize.pill) {
      return Center(
        child: Pill(
          CardModel(
            title: 'Clock',
            icon: Icons.schedule,
            headline: Metric('Time', time, suffix),
            pillLabel: style.dateLine(now, roomy: false),
          ),
        ),
      );
    }
    final date = widget.size == CardSize.small
        ? ''
        : style.dateLine(now, roomy: widget.size == CardSize.large);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ClockFace(
                  time: time,
                  suffix: suffix,
                  font: style.font,
                  color: c.ink,
                ),
              ),
            ),
            if (date.isNotEmpty) ...[
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  date,
                  maxLines: 1,
                  style: style.dateFont
                      .style(
                        size: widget.size == CardSize.large ? 22 : 17,
                        color: c.muted,
                      )
                      .copyWith(
                        height: 1.2,
                        letterSpacing: style.caps ? 1.5 : 0,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The time, sized from the widest it could ever be ("88:88 PM") and drawn
/// one character per fixed-width cell, so it never grows, shrinks or moves
/// as the digits change.
class ClockFace extends StatelessWidget {
  final String time;
  final String suffix;
  final ClockFont font;
  final Color color;

  const ClockFace({
    super.key,
    required this.time,
    required this.suffix,
    required this.font,
    required this.color,
  });

  static const _ref = 100.0;
  static const _suffixScale = 0.3;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final ref = font.style(size: _ref, color: color);
      double width(String s, TextStyle st) {
        final p = TextPainter(
          text: TextSpan(text: s, style: st),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        )..layout();
        final w = p.width;
        p.dispose();
        return w;
      }

      final digit = [for (var i = 0; i < 10; i++) width('$i', ref)]
          .reduce((a, b) => a > b ? a : b);
      final colon = width(':', ref);
      final small = ref.copyWith(fontSize: _ref * _suffixScale);
      final gap = _ref * 0.06;
      final tail = suffix.isEmpty
          ? 0.0
          : gap + [width('AM', small), width('PM', small)].reduce(math.max);
      final full = digit * 4 + colon + tail;
      // A hair under the exact fit, so rounding never overflows.
      final scale = math.min(box.maxWidth / full, box.maxHeight / _ref) * 0.995;
      final size = _ref * scale;
      final cell = digit * scale;
      final st = font.style(size: size, color: color);

      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          for (final ch in time.split(''))
            SizedBox(
              width: ch == ':' ? colon * scale : cell,
              child: Text(
                ch,
                textAlign: TextAlign.center,
                textScaler: TextScaler.noScaling,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: st,
              ),
            ),
          if (suffix.isNotEmpty) ...[
            SizedBox(width: gap * scale),
            Text(
              suffix,
              textScaler: TextScaler.noScaling,
              style: st.copyWith(fontSize: size * _suffixScale),
            ),
          ],
        ],
      );
    },
  );
}
