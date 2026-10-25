import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/geometry.dart';
import 'package:lecasa/dashboard/layout.dart';

Slot s(String type) => Slot(CardSpec(type));

DashboardLayout threeColumns() => DashboardLayout(
  Split(SplitAxis.horizontal, [
    Split(SplitAxis.vertical, [s('clock'), s('solar')]),
    s('weather'),
    Split(SplitAxis.vertical, [s('tablet'), Slot()]),
  ]),
);

String shape(Node n) => switch (n) {
  Slot(:final card) => card?.type ?? '_',
  Split(:final axis, :final children) =>
    '${axis == SplitAxis.horizontal ? 'H' : 'V'}(${children.map(shape).join(' ')})',
};

void main() {
  group('editing', () {
    test('inserting between neighbours takes a quarter of each', () {
      final l = DashboardLayout(
        Split(SplitAxis.vertical, [s('a'), s('b')], [1, 1]),
      );
      final p = l.insertSlot(const [], 1);
      expect(p, [1]);
      expect(shape(l.root), 'V(a _ b)');
      expect(l.root.weights, [0.75, 0.5, 0.75]);
    });

    test('inserting at an end halves the end neighbour', () {
      final l = DashboardLayout(Split(SplitAxis.vertical, [s('a'), s('b')]));
      l.insertSlot(const [], 2);
      expect(shape(l.root), 'V(a b _)');
      expect(l.root.weights, [1, 0.5, 0.5]);
    });

    test('splitting beside a slot makes the third level, and no deeper', () {
      final l = threeColumns();
      final p = l.splitBeside([0, 1], after: true);
      expect(p, [0, 1, 1]);
      expect(shape(l.root), 'H(V(clock H(solar _)) weather V(tablet _))');
      expect(l.depth, 3);
      expect(l.canSplitBeside(p), isFalse);
      expect(() => l.splitBeside(p, after: true), throwsStateError);
    });

    test('a column with one slot can grow a second', () {
      final l = threeColumns();
      l.splitBeside([1], after: true);
      expect(shape(l.root), 'H(V(clock solar) V(weather _) V(tablet _))');
    });

    test('removing collapses one-child splits and merges same axes', () {
      final l = threeColumns();
      l.remove([2, 1]);
      expect(shape(l.root), 'H(V(clock solar) weather tablet)');
      l.remove([0, 0]);
      l.remove([0]);
      l.remove([0]);
      l.remove([0]);
      expect(shape(l.root), 'H(_)');
    });

    test('resize trades space between two neighbours only', () {
      final l = DashboardLayout(
        Split(SplitAxis.horizontal, [s('a'), s('b'), s('c')]),
      );
      l.resize(const [], 0, 0.25);
      expect(l.root.weights[0], closeTo(1.5, 1e-9));
      expect(l.root.weights[1], closeTo(0.5, 1e-9));
      expect(l.root.weights[2], 1);
      l.resize(const [], 0, 1, minFraction: 0.1);
      expect(l.root.weights[1], closeTo(0.2, 1e-9));
    });

    test('switching the root to rows flips every split', () {
      final l = threeColumns();
      l.setRootAxis(SplitAxis.vertical);
      expect(shape(l.root), 'V(H(clock solar) weather H(tablet _))');
    });

    test('take moves a card out of a slot or a chip row', () {
      final l = DashboardLayout(
        Split(SplitAxis.horizontal, [
          Slot(const CardSpec.device('x')),
          Slot(
            const CardSpec(
              'chips',
              items: [CardSpec.device('y'), CardSpec.device('z')],
            ),
          ),
        ]),
      );
      expect(l.cardKeys, {'device:x', 'device:y', 'device:z'});
      expect(l.take('device:y'), isTrue);
      expect(l.cardKeys, {'device:x', 'device:z'});
      expect(l.take('device:x'), isTrue);
      expect(l.take('device:x'), isFalse);
      expect(l.cardKeys, {'device:z'});
    });

    test('too-deep trees from storage are flattened', () {
      final l = DashboardLayout(
        Split(SplitAxis.horizontal, [
          Split(SplitAxis.vertical, [
            Split(SplitAxis.horizontal, [
              s('a'),
              Split(SplitAxis.vertical, [s('b'), s('c')]),
            ]),
            s('d'),
          ]),
          s('e'),
        ]),
      );
      expect(l.depth, 3);
      expect(shape(l.root), 'H(V(H(a b c) d) e)');
    });
  });

  test('json round trip keeps cards, pins and proportions', () {
    final l = threeColumns();
    (l.at([1]) as Slot).card = const CardSpec(
      'weather',
      pinned: CardSize.small,
    );
    l.resize(const [], 0, 0.1);
    final doc = DashboardDoc([l]);
    final back = DashboardDoc.fromJson(
      (jsonDecode(jsonEncode(doc.toJson())) as Map).cast<String, Object?>(),
    )!;
    final b = back.pages.single;
    expect(shape(b.root), shape(l.root));
    expect((b.at([1]) as Slot).card!.pinned, CardSize.small);
    expect(b.root.weights[0], closeTo(l.root.weights[0], 1e-3));
  });

  test('a document from a future version is ignored', () {
    expect(DashboardDoc.fromJson({'v': 99, 'pages': []}), isNull);
  });

  test('geometry places slots and gaps to fill the area exactly', () {
    final l = DashboardLayout(
      Split(
        SplitAxis.horizontal,
        [
          Split(SplitAxis.vertical, [s('a'), s('b')], [1, 3]),
          s('c'),
        ],
        [3, 1],
      ),
    );
    final g = computeGeometry(
      l.root,
      const Rect.fromLTWH(0, 0, 412, 212),
      gap: 12,
    );
    final byType = {for (final b in g.slots) b.slot.card!.type: b.rect};
    expect(byType['a'], const Rect.fromLTWH(0, 0, 300, 50));
    expect(byType['b'], const Rect.fromLTWH(0, 62, 300, 150));
    expect(byType['c'], const Rect.fromLTWH(312, 0, 100, 212));
    expect(g.gaps, hasLength(2));
    final root = g.gaps.firstWhere((x) => x.split.isEmpty);
    expect(root.rect, const Rect.fromLTWH(300, 0, 12, 212));
    expect(root.pairExtent, 400);
  });
}
