// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

/// A card the user has arranged: a tree of boxes, like the dashboard's
/// slots, whose leaves are parts. Each part shows one data point of the
/// card (a reading, the title, the graph...) in one style, aligned left,
/// centre or right. Pure data and operations, no widgets.
///
/// A card without a template is drawn by the automatic layouts in
/// card_view.dart. Opening card options turns that layout into a template
/// ([defaultTemplate]) for the user to change.
library;

import '../layout.dart';
import 'card_model.dart';

/// How a part shows its data point.
enum PartKind {
  /// Icon and name of the card.
  title,

  /// A reading as one large number that grows with its box.
  big,

  /// A reading as a small label over its value.
  reading,

  /// A short state ("Bulk", "Charging") in a coloured chip.
  chip,

  /// The history line.
  graph,

  /// The forecast as bars.
  bars,

  /// A percentage as a ring.
  ring,

  /// The split of a total (each solar charger) as a bar and a legend.
  split,

  /// A sentence.
  note;

  String get label => switch (this) {
    title => 'Title',
    big => 'Big number',
    reading => 'Reading',
    chip => 'State chip',
    graph => 'Graph',
    bars => 'Forecast bars',
    ring => 'Ring',
    split => 'Split bar',
    note => 'Sentence',
  };

  /// Parts that keep their natural height in a stack, rather than taking a
  /// share of the spare space.
  bool get fixed => this == title || this == chip || this == note;
}

enum PartAlign { start, center, end }

sealed class CardBox {
  Map<String, Object?> toJson();

  CardBox copy() => fromJson(toJson());

  static CardBox fromJson(Map<String, Object?> j) => j.containsKey('c')
      ? BoxSplit(
          j['a'] == 'h' ? SplitAxis.horizontal : SplitAxis.vertical,
          [
            for (final c in j['c'] as List)
              CardBox.fromJson((c as Map).cast<String, Object?>()),
          ],
          [for (final w in j['w'] as List) (w as num).toDouble()],
        )
      : BoxPart(
          PartKind.values.asNameMap()[j['k']],
          j['p'] as String?,
          PartAlign.values.asNameMap()[j['al']] ?? PartAlign.start,
        );
}

/// A box with something in it, or an empty box when [kind] is null.
class BoxPart extends CardBox {
  PartKind? kind;

  /// The data point's id (see [DataPoint.id]).
  String? point;
  PartAlign align;

  BoxPart([this.kind, this.point, this.align = PartAlign.start]);

  bool get isEmpty => kind == null;

  @override
  Map<String, Object?> toJson() => {
    'k': kind?.name,
    if (point != null) 'p': point,
    if (align != PartAlign.start) 'al': align.name,
  };
}

class BoxSplit extends CardBox {
  SplitAxis axis;
  final List<CardBox> children;
  final List<double> weights;

  BoxSplit(this.axis, this.children, [List<double>? weights])
    : weights = weights ?? List.filled(children.length, 1.0, growable: true);

  @override
  Map<String, Object?> toJson() => {
    'a': axis == SplitAxis.horizontal ? 'h' : 'v',
    'c': [for (final c in children) c.toJson()],
    'w': [for (final w in weights) double.parse(w.toStringAsFixed(3))],
  };
}

/// How deep boxes may nest, counting the card itself.
const maxBoxDepth = 4;

/// A card's arrangement and every edit the card options screen makes.
class CardTemplate {
  BoxSplit root;
  CardTemplate(this.root) {
    normalize();
  }

  factory CardTemplate.fromJson(Map<String, Object?> j) {
    final b = CardBox.fromJson(j);
    return CardTemplate(b is BoxSplit ? b : BoxSplit(SplitAxis.vertical, [b]));
  }

  Map<String, Object?> toJson() => root.toJson();

  CardTemplate copy() => CardTemplate.fromJson(toJson());

  CardBox at(NodePath path) {
    CardBox b = root;
    for (final i in path) {
      b = (b as BoxSplit).children[i];
    }
    return b;
  }

  BoxSplit parentOf(NodePath path) =>
      at(path.sublist(0, path.length - 1)) as BoxSplit;

  /// Every part with its path, in reading order.
  Iterable<(NodePath, BoxPart)> get parts sync* {
    Iterable<(NodePath, BoxPart)> walk(CardBox b, NodePath p) sync* {
      switch (b) {
        case BoxPart():
          yield (p, b);
        case BoxSplit():
          for (var i = 0; i < b.children.length; i++) {
            yield* walk(b.children[i], [...p, i]);
          }
      }
    }

    yield* walk(root, const []);
  }

  /// Whether the box at [path] can be split along [axis].
  bool canSplit(NodePath path, SplitAxis axis) {
    if (path.isEmpty) return false;
    return parentOf(path).axis == axis || path.length < maxBoxDepth;
  }

  /// Puts an empty box next to the box at [path], side by side
  /// ([SplitAxis.horizontal]) or above and below. Returns the new box's
  /// path. Next to a sibling on the same axis it takes half of the box's
  /// share; otherwise the box becomes a split of two.
  NodePath split(NodePath path, SplitAxis axis, {bool after = true}) {
    final parent = parentOf(path);
    final i = path.last;
    if (parent.axis == axis) {
      final half = parent.weights[i] / 2;
      parent.weights[i] = half;
      final at = after ? i + 1 : i;
      parent.children.insert(at, BoxPart());
      parent.weights.insert(at, half);
      return [...path.sublist(0, path.length - 1), at];
    }
    final old = parent.children[i];
    parent.children[i] = BoxSplit(
      axis,
      after ? [old, BoxPart()] : [BoxPart(), old],
    );
    return [...path, after ? 1 : 0];
  }

  /// Removes the box at [path]. The last box of a card is emptied instead.
  void remove(NodePath path) {
    if (path.isEmpty) return;
    final parent = parentOf(path);
    if (identical(parent, root) && root.children.length == 1) {
      root.children[0] = BoxPart();
      return;
    }
    parent.children.removeAt(path.last);
    parent.weights.removeAt(path.last);
    normalize();
  }

  /// Trades space between children [i] and [i + 1] of the split at
  /// [splitPath], like the dashboard's slot handles.
  void resize(
    NodePath splitPath,
    int i,
    double delta, {
    double minFraction = 0.1,
  }) {
    final w = (at(splitPath) as BoxSplit).weights;
    final pair = w[i] + w[i + 1];
    final a = (w[i] / pair + delta).clamp(minFraction, 1 - minFraction);
    w[i] = pair * a;
    w[i + 1] = pair - w[i];
  }

  /// A split with one child becomes that child; same-axis splits merge.
  void normalize() {
    CardBox tidy(CardBox b) {
      if (b is! BoxSplit) return b;
      for (var i = 0; i < b.children.length; i++) {
        b.children[i] = tidy(b.children[i]);
      }
      for (var i = 0; i < b.children.length; i++) {
        final c = b.children[i];
        if (c is BoxSplit && c.axis == b.axis) {
          final total = c.weights.fold(0.0, (a, w) => a + w);
          final scaled = [for (final w in c.weights) w / total * b.weights[i]];
          b.children
            ..removeAt(i)
            ..insertAll(i, c.children);
          b.weights
            ..removeAt(i)
            ..insertAll(i, scaled);
          i += c.children.length - 1;
        }
      }
      if (b.children.length == 1) return b.children.single;
      return b;
    }

    final t = tidy(root);
    root = t is BoxSplit ? t : BoxSplit(root.axis, [t]);
    if (root.children.isEmpty) {
      root.children.add(BoxPart());
      root.weights.add(1);
    }
  }
}

/// One thing a card can show.
class DataPoint {
  /// Stable across readings: `title`, `state`, `note`, `graph`, `bars`,
  /// `ring`, `split`, `m:<label>` for a reading, `s:<name>` for one part
  /// of a split total.
  final String id;
  final String label;

  /// The styles it can be shown in, the usual one first.
  final List<PartKind> kinds;

  /// A short sample of what it shows now ("412 W").
  final String preview;
  final Metric? metric;

  const DataPoint(
    this.id,
    this.label,
    this.kinds, {
    this.preview = '',
    this.metric,
  });
}

String metricId(Metric m) => 'm:${m.label.toLowerCase()}';

/// Everything [m] can show, in the order it shows it by default: the
/// title, the headline, its state, the graph, then the other readings.
List<DataPoint> dataPoints(CardModel m) {
  final seen = <String>{};
  final out = <DataPoint>[];
  void add(DataPoint p) {
    if (seen.add(p.id)) out.add(p);
  }

  add(
    DataPoint('title', 'Card name', const [PartKind.title], preview: m.title),
  );
  if (m.headline case final h?) {
    add(
      DataPoint(
        metricId(h),
        h.label.isEmpty ? 'Main reading' : h.label,
        const [PartKind.big, PartKind.reading],
        preview: h.inline,
        metric: h,
      ),
    );
  }
  if (m.state != null) {
    add(
      DataPoint('state', 'State', const [
        PartKind.chip,
        PartKind.note,
      ], preview: m.state!),
    );
  }
  if (m.series != null) {
    add(
      DataPoint(
        'graph',
        m.headline == null || m.headline!.label.isEmpty
            ? 'History'
            : '${m.headline!.label}, last 6 hours',
        const [PartKind.graph],
      ),
    );
  }
  if (m.hours.isNotEmpty) {
    add(DataPoint('bars', m.hoursLabel ?? 'Forecast', const [PartKind.bars]));
  }
  if (m.ring != null) {
    add(
      DataPoint('ring', '${m.headline?.label ?? 'Level'} ring', const [
        PartKind.ring,
      ], preview: '${m.ring!.round()} %'),
    );
  }
  if (m.shares.isNotEmpty) {
    add(
      DataPoint(
        'split',
        'Split by ${m.shares.length == 2 ? 'charger' : 'part'}',
        const [PartKind.split],
      ),
    );
  }
  for (final d in m.details) {
    add(
      DataPoint(
        metricId(d),
        d.label,
        const [PartKind.reading, PartKind.big],
        preview: d.inline,
        metric: d,
      ),
    );
  }
  for (final s in m.shares) {
    final metric = Metric(s.name, s.value.split(' ').first, _unitOf(s.value));
    add(
      DataPoint(
        's:${s.name.toLowerCase()}',
        s.name,
        const [PartKind.reading, PartKind.big],
        preview: s.value,
        metric: metric,
      ),
    );
  }
  if (m.note != null) {
    add(DataPoint('note', 'Message', const [PartKind.note], preview: m.note!));
  }
  return out;
}

String _unitOf(String value) {
  final i = value.indexOf(' ');
  return i < 0 ? '' : value.substring(i + 1);
}

/// The data point with [id] in [points], if the card has it right now.
DataPoint? pointById(List<DataPoint> points, String? id) {
  if (id == null) return null;
  for (final p in points) {
    if (p.id == id) return p;
  }
  return null;
}

/// The automatic layout as a template, the starting point for options:
/// the title, the big number with its state, the graph (or ring or split),
/// and a row of up to three readings.
CardTemplate defaultTemplate(CardModel m) {
  final rows = <CardBox>[BoxPart(PartKind.title, 'title')];
  final weights = <double>[1];
  if (m.headline == null) {
    if (m.note != null) {
      rows.add(BoxPart(PartKind.note, 'note'));
      weights.add(1);
    }
    return CardTemplate(BoxSplit(SplitAxis.vertical, rows, weights));
  }
  final big = BoxPart(PartKind.big, metricId(m.headline!));
  final ring = m.ring != null;
  if (ring) {
    rows.add(
      BoxSplit(
        SplitAxis.horizontal,
        [
          BoxPart(PartKind.ring, 'ring'),
          BoxSplit(SplitAxis.vertical, [
            if (m.state != null) BoxPart(PartKind.chip, 'state'),
            for (final d in m.details.where((d) => !d.minor).take(2))
              BoxPart(PartKind.reading, metricId(d)),
          ]),
        ],
        [1, 1.4],
      ),
    );
    weights.add(3);
  } else {
    rows.add(
      m.state == null
          ? big
          : BoxSplit(
              SplitAxis.horizontal,
              [big, BoxPart(PartKind.chip, 'state', PartAlign.end)],
              [2.2, 1],
            ),
    );
    weights.add(1.6);
  }
  if (m.series != null && !ring) {
    rows.add(BoxPart(PartKind.graph, 'graph'));
    weights.add(2);
  } else if (m.hours.isNotEmpty) {
    rows.add(BoxPart(PartKind.bars, 'bars'));
    weights.add(2.2);
  }
  if (m.shares.isNotEmpty) {
    rows.add(BoxPart(PartKind.split, 'split'));
    weights.add(0.9);
  }
  final readings = ring
      ? const <Metric>[]
      : m.details.where((d) => !d.minor).take(3).toList();
  if (readings.isNotEmpty) {
    rows.add(
      BoxSplit(SplitAxis.horizontal, [
        for (final d in readings) BoxPart(PartKind.reading, metricId(d)),
      ]),
    );
    weights.add(1);
  }
  return CardTemplate(BoxSplit(SplitAxis.vertical, rows, weights));
}

/// The data points to offer first for the part at [path]: whatever is
/// near it on the card, then the card's main readings, so the list leads
/// with what fits what is already there.
List<DataPoint> suggestedFor(
  CardTemplate t,
  NodePath path,
  List<DataPoint> points,
) {
  final part = t.at(path);
  final kind = part is BoxPart ? part.kind : null;
  final used = {for (final (_, p) in t.parts) p.point};
  int score(DataPoint p) {
    var s = 0;
    if (kind != null && p.kinds.first == kind) s += 4;
    if (kind != null && p.kinds.contains(kind)) s += 2;
    if (!used.contains(p.id)) s += 1;
    return s;
  }

  final order = {for (final (i, p) in points.indexed) p.id: i};
  final ranked = [...points]
    ..sort((a, b) {
      final d = score(b).compareTo(score(a));
      return d != 0 ? d : order[a.id]!.compareTo(order[b.id]!);
    });
  return ranked.take(4).toList();
}
