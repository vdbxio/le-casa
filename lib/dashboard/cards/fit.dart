// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;
import 'dart:ui';

import '../layout.dart';
import 'card_model.dart';

/// Layout constants shared by [fitSize] and the card renderer, so "does it
/// fit" and "how it is drawn" cannot drift apart.
abstract final class CardMetrics {
  static const pad = 16.0;
  static const padSmall = 12.0;
  static const header = 24.0;
  static const gap = 8.0;
  static const detailWidth = 112.0;
  static const detailHeight = 46.0;
  static const detailGap = 12.0;
  static const shareRow = 26.0;
  static const ringLarge = 132.0;
  static const ringMedium = 96.0;
  static const pillHeight = 52.0;

  static double headlineSize(CardSize s) => switch (s) {
    CardSize.large => 68,
    CardSize.medium => 46,
    CardSize.small => 34,
    CardSize.pill => 21,
  };

  /// Detail columns for a content width.
  static int detailColumns(double w) => math.max(
    1,
    math.min(4, ((w + detailGap) / (detailWidth + detailGap)).floor()),
  );
}

/// Content widths from which large and medium cards draw a ring.
const ringLargeMinWidth = 340.0;
const ringMediumMinWidth = 260.0;

/// The space a model needs at [size], for slot width [w].
double minHeight(CardModel m, CardSize size, double w) {
  const p = CardMetrics.pad * 2;
  switch (size) {
    case CardSize.pill:
      return 0;
    case CardSize.small:
      return CardMetrics.padSmall * 2 + CardMetrics.header + 34 + 22 + 8;
    case CardSize.medium:
      if (m.ring != null && w - p - 4 >= ringMediumMinWidth) {
        return p +
            CardMetrics.header +
            CardMetrics.gap +
            CardMetrics.ringMedium;
      }
      return p +
          CardMetrics.header +
          CardMetrics.gap +
          46 +
          CardMetrics.gap +
          22 +
          (m.shares.isNotEmpty ? 18 : 0);
    case CardSize.large:
      final cw = w - p - 4;
      if (m.ring != null && cw >= ringLargeMinWidth) {
        // Ring on the left, state chip and a two-column grid beside it.
        final rows = (m.details.length / 2).ceil();
        final grid =
            (m.state == null ? 0 : 34) +
            rows * CardMetrics.detailHeight +
            math.max(0, rows - 1) * CardMetrics.detailGap;
        return p +
            CardMetrics.header +
            CardMetrics.gap +
            math.max(CardMetrics.ringLarge, grid) +
            (m.note == null ? 0 : 20);
      }
      final cols = CardMetrics.detailColumns(cw);
      final rows = (m.details.length / cols).ceil();
      return p +
          CardMetrics.header +
          CardMetrics.gap +
          68 +
          CardMetrics.gap +
          (m.shares.isEmpty ? 0 : 18 + m.shares.length * CardMetrics.shareRow) +
          rows * CardMetrics.detailHeight +
          math.max(0, rows - 1) * CardMetrics.detailGap +
          (m.note == null ? 0 : 20);
  }
}

double minWidth(CardModel m, CardSize size) => switch (size) {
  CardSize.pill => 0,
  CardSize.small => 136,
  CardSize.medium => 210,
  CardSize.large => 290,
};

/// The largest size whose content fits [space]. A card never clips: if a
/// size does not fit, it steps down to the next.
CardSize fitSize(CardModel m, Size space) {
  if (space.height < 84 || space.width < 136) return CardSize.pill;
  bool fits(CardSize s) =>
      space.width >= minWidth(m, s) &&
      space.height >= minHeight(m, s, space.width);
  for (final s in CardSize.values) {
    if (s == CardSize.pill) return s;
    if (!fits(s)) continue;
    // Keep the graph in view: when a large card would push it behind the
    // numbers but a medium one has room for it, go medium.
    if (s == CardSize.large &&
        hasChart(m) &&
        !chartInline(m, s, space) &&
        fits(CardSize.medium) &&
        chartInline(m, CardSize.medium, space)) {
      return CardSize.medium;
    }
    return s;
  }
  return CardSize.pill;
}

/// Whether the card has a graph: a history line or forecast bars. A graph
/// takes whatever height is spare; it is never the reason a size is chosen.
bool hasChart(CardModel m) => m.series != null || m.hours.isNotEmpty;

/// The least height a graph is drawn in. Below this it goes behind the
/// card's numbers instead.
double chartMinHeight(CardModel m) => m.hours.isNotEmpty ? 34 : 28;

/// Wide, short slots put the numbers on the left and the graph (or more
/// readings) on the right, instead of stacking them.
bool sideBySide(CardModel m, CardSize size, Size slot) =>
    (size == CardSize.small || size == CardSize.medium) &&
    slot.width >= 380 &&
    slot.width >= slot.height * 2 &&
    (hasChart(m) || m.details.length > 1);

/// Whether the graph gets its own space in [slot] (otherwise it is drawn
/// faintly behind the numbers).
bool chartInline(CardModel m, CardSize size, Size slot) {
  if (!hasChart(m) || size == CardSize.pill) return false;
  if (sideBySide(m, size, slot)) return true;
  final content = slot.width - CardMetrics.pad * 2 - 4;
  if (size == CardSize.medium &&
      m.ring != null &&
      content >= ringMediumMinWidth) {
    return false;
  }
  return slot.height - minHeight(m, size, slot.width) >=
      chartMinHeight(m) + CardMetrics.gap;
}
