// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

/// The dashboard layout: a tree of splits whose leaves are slots. Pure data
/// and pure operations, no widgets, so it can be tested without Flutter.
///
/// - The root is always a [Split]. Its axis says whether the screen is a
///   run of columns ([SplitAxis.horizontal]: children side by side) or a
///   run of rows ([SplitAxis.vertical]).
/// - Axes alternate with depth: a column stacks its slots vertically, and a
///   slot inside it can split again side by side.
/// - Splits can nest [maxSplitDepth] levels deep (root, group, sub-group).
/// - Sizes are proportions ([Split.weights]), so a layout fills any screen.
library;

import 'dart:math' as math;

/// The four sizes every card knows how to draw.
enum CardSize {
  large,
  medium,
  small,
  pill;

  String get short => switch (this) {
    large => 'L',
    medium => 'M',
    small => 'S',
    pill => 'pill',
  };

  CardSize? get smaller => this == pill ? null : CardSize.values[index + 1];
}

/// What goes in a slot.
class CardSpec {
  /// `device`, `solar` (all solar chargers added up), `clock`, `tablet`,
  /// `weather` or `chips`.
  final String type;

  /// The tracked device id, for [type] `device`.
  final String? device;

  /// The pills of a chip row, for [type] `chips`.
  final List<CardSpec> items;

  /// A size the user pinned, or null for "largest that fits".
  final CardSize? pinned;

  const CardSpec(this.type, {this.device, this.items = const [], this.pinned});
  const CardSpec.device(String id) : this('device', device: id);

  /// Identity for "is this already on the dashboard?". Chip rows have no
  /// identity of their own; their items do.
  String get key => type == 'device' ? 'device:$device' : type;

  CardSpec copyWith({
    List<CardSpec>? items,
    CardSize? pinned,
    bool unpin = false,
  }) => CardSpec(
    type,
    device: device,
    items: items ?? this.items,
    pinned: unpin ? null : (pinned ?? this.pinned),
  );

  Map<String, Object?> toJson() => {
    't': type,
    if (device != null) 'd': device,
    if (items.isNotEmpty) 'i': [for (final c in items) c.toJson()],
    if (pinned != null) 'p': pinned!.name,
  };

  static CardSpec fromJson(Map<String, Object?> j) => CardSpec(
    j['t'] as String,
    device: j['d'] as String?,
    items: [
      for (final c in (j['i'] as List? ?? const []))
        CardSpec.fromJson((c as Map).cast<String, Object?>()),
    ],
    pinned: CardSize.values.asNameMap()[j['p']],
  );

  @override
  bool operator ==(Object other) =>
      other is CardSpec &&
      other.type == type &&
      other.device == device &&
      other.pinned == pinned &&
      other.items.length == items.length &&
      [for (var i = 0; i < items.length; i++) other.items[i] == items[i]]
          .every((x) => x);

  @override
  int get hashCode => Object.hash(type, device, pinned, items.length);
}

enum SplitAxis {
  /// Children side by side: a run of columns.
  horizontal,

  /// Children stacked: a run of rows.
  vertical;

  SplitAxis get cross => this == horizontal ? vertical : horizontal;
}

sealed class Node {
  Map<String, Object?> toJson();

  static Node fromJson(Map<String, Object?> j) => j.containsKey('c')
      ? Split(
          j['a'] == 'v' ? SplitAxis.vertical : SplitAxis.horizontal,
          [
            for (final c in j['c'] as List)
              Node.fromJson((c as Map).cast<String, Object?>()),
          ],
          [for (final w in j['w'] as List) (w as num).toDouble()],
        )
      : Slot(
          j['card'] == null
              ? null
              : CardSpec.fromJson((j['card'] as Map).cast<String, Object?>()),
        );
}

class Slot extends Node {
  CardSpec? card;
  Slot([this.card]);

  @override
  Map<String, Object?> toJson() => {'card': card?.toJson()};
}

class Split extends Node {
  SplitAxis axis;
  final List<Node> children;
  final List<double> weights;

  Split(this.axis, this.children, [List<double>? weights])
    : weights = weights ?? List.filled(children.length, 1.0, growable: true) {
    assert(this.weights.length == children.length);
  }

  @override
  Map<String, Object?> toJson() => {
    'a': axis == SplitAxis.vertical ? 'v' : 'h',
    'c': [for (final c in children) c.toJson()],
    'w': [for (final w in weights) double.parse(w.toStringAsFixed(4))],
  };
}

/// Where a node sits: child indexes from the root. `[]` is the root.
typedef NodePath = List<int>;

/// How many levels of splits may nest, counting the root.
const maxSplitDepth = 3;

/// One page of the dashboard and every edit you can make to it.
class DashboardLayout {
  Split root;
  DashboardLayout(this.root) {
    normalize();
  }

  factory DashboardLayout.empty() =>
      DashboardLayout(Split(SplitAxis.horizontal, [Slot()]));

  factory DashboardLayout.fromJson(Map<String, Object?> j) {
    final n = Node.fromJson(j);
    return DashboardLayout(n is Split ? n : Split(SplitAxis.horizontal, [n]));
  }

  Map<String, Object?> toJson() => root.toJson();

  Node at(NodePath path) {
    Node n = root;
    for (final i in path) {
      n = (n as Split).children[i];
    }
    return n;
  }

  Split parentOf(NodePath path) =>
      at(path.sublist(0, path.length - 1)) as Split;

  /// Every slot with its path, in reading order.
  Iterable<(NodePath, Slot)> get slots sync* {
    Iterable<(NodePath, Slot)> walk(Node n, NodePath p) sync* {
      switch (n) {
        case Slot():
          yield (p, n);
        case Split():
          for (var i = 0; i < n.children.length; i++) {
            yield* walk(n.children[i], [...p, i]);
          }
      }
    }

    yield* walk(root, const []);
  }

  /// Keys of every card on the page, chip row items included.
  Set<String> get cardKeys => {
    for (final (_, s) in slots)
      if (s.card case final c?) ...[
        if (c.type == 'chips') ...c.items.map((i) => i.key) else c.key,
      ],
  };

  /// Inserts an empty slot into the split at [splitPath] before child
  /// [index] (`index == length` appends). Between two neighbours it takes a
  /// quarter of each one's share; at an end it halves the end neighbour.
  NodePath insertSlot(NodePath splitPath, int index) {
    final s = at(splitPath) as Split;
    final w = s.weights;
    double share;
    if (index > 0 && index < w.length) {
      final a = w[index - 1] / 4, b = w[index] / 4;
      w[index - 1] -= a;
      w[index] -= b;
      share = a + b;
    } else {
      final n = index == 0 ? 0 : w.length - 1;
      share = w[n] / 2;
      w[n] = share;
    }
    s.children.insert(index, Slot());
    w.insert(index, share);
    return [...splitPath, index];
  }

  /// Whether [splitBeside] can nest one more level at [slotPath].
  bool canSplitBeside(NodePath slotPath) => slotPath.length < maxSplitDepth;

  /// Puts an empty slot next to the slot at [slotPath], across its parent's
  /// axis (beside a slot in a column, above/below one in a row). This is how
  /// the third level gets made. [after] picks which side.
  NodePath splitBeside(NodePath slotPath, {required bool after}) {
    if (!canSplitBeside(slotPath)) {
      throw StateError('Layout is already $maxSplitDepth levels deep here');
    }
    final parent = parentOf(slotPath);
    final i = slotPath.last;
    final old = parent.children[i];
    final fresh = Slot();
    parent.children[i] = Split(
      parent.axis.cross,
      after ? [old, fresh] : [fresh, old],
    );
    return [...slotPath, after ? 1 : 0];
  }

  /// Removes the slot at [path] and tidies up what is left.
  void remove(NodePath path) {
    if (path.isEmpty) return;
    final parent = parentOf(path);
    parent.children.removeAt(path.last);
    parent.weights.removeAt(path.last);
    normalize();
  }

  /// Trades space between children [i] and [i + 1] of the split at
  /// [splitPath]. [delta] is the fraction of the pair's combined size to
  /// move from the second to the first (negative moves it back). Neither
  /// may drop below [minFraction] of the pair.
  void resize(
    NodePath splitPath,
    int i,
    double delta, {
    double minFraction = 0.08,
  }) {
    final w = (at(splitPath) as Split).weights;
    final pair = w[i] + w[i + 1];
    final a = (w[i] / pair + delta).clamp(minFraction, 1 - minFraction);
    w[i] = pair * a;
    w[i + 1] = pair - w[i];
  }

  /// Switches the root between columns and rows. Every split flips, so the
  /// columns become rows and the cards keep their places.
  void setRootAxis(SplitAxis axis) {
    if (root.axis == axis) return;
    void flip(Node n) {
      if (n is Split) {
        n.axis = n.axis.cross;
        n.children.forEach(flip);
      }
    }

    flip(root);
  }

  /// Takes the card with [key] out of wherever it is (a slot, or a chip
  /// row). Returns whether it was found.
  bool take(String key) {
    for (final (_, s) in slots) {
      final c = s.card;
      if (c == null) continue;
      if (c.type == 'chips') {
        final left = [
          for (final i in c.items)
            if (i.key != key) i,
        ];
        if (left.length != c.items.length) {
          s.card = left.isEmpty ? null : c.copyWith(items: left);
          return true;
        }
      } else if (c.key == key) {
        s.card = null;
        return true;
      }
    }
    return false;
  }

  /// Keeps the tree tidy after edits:
  /// - a split with one child is replaced by that child,
  /// - a split inside a split of the same axis is merged into it,
  /// - nothing nests deeper than [maxSplitDepth],
  /// - the root is always a split with at least one slot,
  /// - weights are positive and average 1.
  void normalize() {
    Node tidy(Node n) {
      if (n is! Split) return n;
      for (var i = 0; i < n.children.length; i++) {
        n.children[i] = tidy(n.children[i]);
      }
      // Merge same-axis children up into this split.
      for (var i = 0; i < n.children.length; i++) {
        final c = n.children[i];
        if (c is Split && c.axis == n.axis) {
          final total = c.weights.fold(0.0, (a, b) => a + b);
          final scaled = [for (final w in c.weights) w / total * n.weights[i]];
          n.children
            ..removeAt(i)
            ..insertAll(i, c.children);
          n.weights
            ..removeAt(i)
            ..insertAll(i, scaled);
          i += c.children.length - 1;
        }
      }
      if (n.children.length == 1) return n.children.single;
      return n;
    }

    final t = tidy(root);
    root = switch (t) {
      Split() => t,
      Slot() => Split(root.axis, [t]),
    };
    if (root.children.isEmpty) {
      root.children.add(Slot());
      root.weights.add(1);
    }
    _flattenBelow(root, 1);
    _rescale(root);
  }

  // Anything deeper than allowed is flattened into its parent.
  void _flattenBelow(Split s, int depth) {
    for (var i = 0; i < s.children.length; i++) {
      final c = s.children[i];
      if (c is! Split) continue;
      if (depth >= maxSplitDepth) {
        // Too deep: keep the first slot, drop the rest of this branch's
        // structure but not its cards (they collapse into one stack).
        final leaves = DashboardLayout._leaves(c);
        s.children[i] = leaves.first;
        s.children.insertAll(i + 1, leaves.skip(1));
        final share = s.weights[i] / leaves.length;
        s.weights
          ..removeAt(i)
          ..insertAll(i, List.filled(leaves.length, share));
        i += leaves.length - 1;
      } else {
        _flattenBelow(c, depth + 1);
      }
    }
  }

  static List<Slot> _leaves(Node n) => switch (n) {
    Slot() => [n],
    Split() => [for (final c in n.children) ..._leaves(c)],
  };

  void _rescale(Split s) {
    final n = s.weights.length;
    for (var i = 0; i < n; i++) {
      if (!(s.weights[i] > 0)) s.weights[i] = 0.01;
    }
    final total = s.weights.fold(0.0, (a, b) => a + b);
    for (var i = 0; i < n; i++) {
      s.weights[i] = s.weights[i] / total * n;
    }
    for (final c in s.children) {
      if (c is Split) _rescale(c);
    }
  }

  /// Depth of the deepest split, the root counting as 1.
  int get depth {
    int d(Node n) => n is Split ? 1 + n.children.map(d).fold(0, math.max) : 0;
    return d(root);
  }
}

/// All pages of the dashboard. One page for now; the format is ready for
/// more so swiping between pages can come later without a migration.
class DashboardDoc {
  static const version = 1;
  final List<DashboardLayout> pages;
  DashboardDoc(this.pages);

  Map<String, Object?> toJson() => {
    'v': version,
    'pages': [for (final p in pages) p.toJson()],
  };

  static DashboardDoc? fromJson(Map<String, Object?> j) {
    if (j['v'] != version) return null;
    final pages = [
      for (final p in j['pages'] as List)
        DashboardLayout.fromJson((p as Map).cast<String, Object?>()),
    ];
    return pages.isEmpty ? null : DashboardDoc(pages);
  }
}
