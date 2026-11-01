// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/palette.dart';
import '../fob_log.dart';
import 'card_model.dart';

/// How long one column of the tape covers.
const tapeColumn = Duration(minutes: 5);

/// The colour of a kind of press.
Color pressColor(LeColors c, String kind) => switch (kind) {
  'press' => c.accent,
  'double_press' => c.climate,
  'triple_press' => c.battery,
  'long_press' => c.solar,
  'long_double_press' || 'long_triple_press' => c.solar2,
  'hold_press' => c.heat,
  _ => c.muted,
};

/// Short names for the legend.
String pressName(String kind) => switch (kind) {
  'press' => 'tap',
  'double_press' => 'double',
  'triple_press' => 'triple',
  'long_press' => 'long',
  'long_double_press' => 'long ×2',
  'long_triple_press' => 'long ×3',
  'hold_press' => 'hold',
  _ => kind.replaceAll('_', ' '),
};

/// What the tape shows in one column.
enum TapeState { home, away, unknown }

/// The columns of [tape] for [count] columns ending now, oldest first: the
/// state of each and, per track, the kind of the last press in it.
List<(TapeState, List<String?>)> tapeColumns(ButtonTape tape, int count) {
  final out = <(TapeState, List<String?>)>[];
  final end = tape.now;
  for (var i = 0; i < count; i++) {
    final to = end.subtract(tapeColumn * (count - 1 - i));
    final span = Span(to.subtract(tapeColumn), to);
    final half = span.length ~/ 2;
    final heard = tape.listening.fold(
      Duration.zero,
      (a, l) => a + span.overlap(l),
    );
    final gone = tape.away.fold(Duration.zero, (a, l) => a + span.overlap(l));
    final state = heard < half && i < count - 1
        ? TapeState.unknown
        : gone > half
        ? TapeState.away
        : TapeState.home;
    final cells = List<String?>.filled(tape.tracks, null);
    for (final p in tape.presses) {
      if (p.at.isBefore(span.from) || p.at.isAfter(span.to)) continue;
      if (p.button < 1 || p.button > tape.tracks) continue;
      cells[p.button - 1] = p.kind; // last press in the column wins
    }
    out.add((state, cells));
  }
  return out;
}

/// The tape: tracks of squares, newest on the right, with a caption line
/// ("Last 3h", and a legend of the kinds of press on it) when there is
/// room. [faint] draws just the tape, for behind the numbers.
class TapeStrip extends StatelessWidget {
  final ButtonTape tape;
  final LeColors c;
  final bool faint;
  const TapeStrip(this.tape, this.c, {super.key, this.faint = false});

  static const captionHeight = 16.0;
  static const gap = 2.0;
  static const minCell = 5.0;
  static const maxCell = 14.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final tracks = tape.tracks;
      double cellFor(double h) =>
          ((h - gap * (tracks - 1)) / tracks).clamp(minCell, maxCell);
      final wantCaption =
          !faint &&
          box.maxHeight >=
              captionHeight + 4 + minCell * tracks + gap * (tracks - 1);
      final cell = cellFor(
        box.maxHeight - (wantCaption ? captionHeight + 4 : 0),
      );
      final labels = !faint && cell >= 8;
      final labelWidth = labels ? 12.0 : 0.0;
      final step = cell + gap;
      final count = math.max(
        1,
        ((box.maxWidth - labelWidth + gap) / step).floor(),
      );
      final columns = tapeColumns(tape, count);
      final kinds = <String>{
        for (final (_, cells) in columns)
          for (final k in cells) ?k,
      };
      final style = TextStyle(fontSize: 11, color: c.muted);
      double textWidth(String t) => (TextPainter(
        text: TextSpan(text: t, style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout()).width;
      final caption = 'Last ${_span(tapeColumn * count)}';
      // As many legend entries as fit beside the caption, in order.
      var room = box.maxWidth - textWidth(caption) - 12;
      final legend = <String>[];
      for (final k in _order.where(kinds.contains)) {
        final w = 8 + 7 + 3 + textWidth(pressName(k)) + 1;
        if (w > room) break;
        room -= w;
        legend.add(k);
      }
      final showCaption = wantCaption && room >= 0;
      final strip = SizedBox(
        height: cell * tracks + gap * (tracks - 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (labels)
              SizedBox(
                width: labelWidth,
                child: Column(
                  children: [
                    for (var t = 0; t < tracks; t++)
                      SizedBox(
                        height: cell + (t < tracks - 1 ? gap : 0),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            '${t + 1}',
                            style: TextStyle(
                              fontSize: math.min(10, cell),
                              height: 1,
                              color: c.muted,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: CustomPaint(
                size: Size.infinite,
                painter: _TapePainter(columns, tracks, cell, c, faint: faint),
              ),
            ),
          ],
        ),
      );
      return Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCaption) ...[
            SizedBox(
              height: captionHeight,
              child: Row(
                children: [
                  Text(caption, maxLines: 1, style: style),
                  const Spacer(),
                  for (final k in legend) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: pressColor(c, k),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Text(pressName(k), maxLines: 1, style: style),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
          strip,
        ],
      );
    },
  );

  static const _order = [
    'press',
    'double_press',
    'triple_press',
    'long_press',
    'long_double_press',
    'long_triple_press',
    'hold_press',
  ];

  static String _span(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    final h = m ~/ 60, r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }
}

class _TapePainter extends CustomPainter {
  final List<(TapeState, List<String?>)> columns;
  final int tracks;
  final double cell;
  final LeColors c;
  final bool faint;

  _TapePainter(
    this.columns,
    this.tracks,
    this.cell,
    this.c, {
    this.faint = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const gap = TapeStrip.gap;
    final step = cell + gap;
    // Right-aligned: now is the right edge.
    final left = size.width - columns.length * step + gap;
    final tapePaint = Paint()..color = c.card2;
    final linePaint = Paint()
      ..color = c.line
      ..strokeWidth = 1;
    final r = Radius.circular(math.min(2.5, cell * 0.25));
    for (final (i, (state, cells)) in columns.indexed) {
      final x = left + i * step;
      for (var t = 0; t < tracks; t++) {
        final y = t * step;
        final rect = Rect.fromLTWH(x, y, cell, cell);
        final kind = cells[t];
        if (kind != null) {
          final col = pressColor(c, kind);
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, r),
            Paint()..color = faint ? col.withValues(alpha: 0.3) : col,
          );
          continue;
        }
        switch (state) {
          case TapeState.home:
            canvas.drawRRect(
              RRect.fromRectAndRadius(rect, r),
              faint
                  ? (Paint()..color = c.card2.withValues(alpha: 0.5))
                  : tapePaint,
            );
          case TapeState.away:
            // The tape runs out: a thin line where it would be.
            canvas.drawLine(
              Offset(x, y + cell / 2),
              Offset(x + step, y + cell / 2),
              linePaint,
            );
          case TapeState.unknown:
            break;
        }
      }
    }
  }

  @override
  bool shouldRepaint(_TapePainter old) =>
      old.columns != columns || old.cell != cell || old.c != c;
}
