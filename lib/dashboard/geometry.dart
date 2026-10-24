// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:ui';

import 'layout.dart';

class SlotBox {
  final NodePath path;
  final Slot slot;
  final Rect rect;
  const SlotBox(this.path, this.slot, this.rect);
}

/// The gap between children [index] and [index] + 1 of the split at
/// [split]. Dragging it trades space between exactly those two.
class GapBox {
  final NodePath split;
  final int index;

  /// The split's axis: horizontal gaps are vertical strips you drag sideways.
  final SplitAxis axis;
  final Rect rect;

  /// Combined length of the two neighbours along [axis], for turning a drag
  /// distance into a share of the pair.
  final double pairExtent;
  const GapBox(this.split, this.index, this.axis, this.rect, this.pairExtent);
}

class Geometry {
  final List<SlotBox> slots;
  final List<GapBox> gaps;
  const Geometry(this.slots, this.gaps);
}

/// Places every slot and gap of [root] inside [area]. Pure arithmetic: the
/// dashboard positions widgets from this, and edit tools (handles, + buttons)
/// can sit anywhere without being clipped by a parent.
Geometry computeGeometry(Split root, Rect area, {double gap = 12}) {
  final slots = <SlotBox>[];
  final gaps = <GapBox>[];

  void place(Node n, NodePath path, Rect r) {
    switch (n) {
      case Slot():
        slots.add(SlotBox(path, n, r));
      case Split():
        final horizontal = n.axis == SplitAxis.horizontal;
        final main = horizontal ? r.width : r.height;
        final avail = (main - gap * (n.children.length - 1)).clamp(
          0.0,
          double.infinity,
        );
        final total = n.weights.fold(0.0, (a, b) => a + b);
        final extents = [
          for (final w in n.weights) total == 0 ? 0.0 : w / total * avail,
        ];
        var pos = horizontal ? r.left : r.top;
        for (var i = 0; i < n.children.length; i++) {
          final e = extents[i];
          final cr = horizontal
              ? Rect.fromLTWH(pos, r.top, e, r.height)
              : Rect.fromLTWH(r.left, pos, r.width, e);
          place(n.children[i], [...path, i], cr);
          pos += e;
          if (i < n.children.length - 1) {
            final gr = horizontal
                ? Rect.fromLTWH(pos, r.top, gap, r.height)
                : Rect.fromLTWH(r.left, pos, r.width, gap);
            gaps.add(GapBox(path, i, n.axis, gr, e + extents[i + 1]));
            pos += gap;
          }
        }
    }
  }

  place(root, const [], area);
  return Geometry(slots, gaps);
}
