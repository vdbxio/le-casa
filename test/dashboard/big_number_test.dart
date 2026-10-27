import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/cards/card_model.dart';
import 'package:lecasa/dashboard/cards/card_view.dart';
import 'package:lecasa/dashboard/cards/template.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/ui/palette.dart';

CardModel _solar(String watts, {String? state = 'Bulk'}) => CardModel(
  title: 'Solar',
  icon: Icons.wb_sunny_outlined,
  tone: Tone.solar,
  headline: Metric('Solar', watts, 'W'),
  state: state,
);

Future<void> _pump(WidgetTester t, CardModel m, Size slot) => t.pumpWidget(
  MaterialApp(
    theme: leCasaTheme(Brightness.light),
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(size: slot, child: DashCard(m, CardSize.medium)),
    ),
  ),
);

/// The font size of the big number on screen.
double _numberSize(WidgetTester t, String value) {
  final rich = t.widget<RichText>(
    find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().startsWith(value),
    ),
  );
  double? size;
  rich.text.visitChildren((s) {
    if (s is TextSpan && s.text == value) size = s.style!.fontSize;
    return size == null;
  });
  return size!;
}

void main() {
  testWidgets('the big number keeps its size whatever its digits', (t) async {
    // Narrow enough that the number has to shrink to fit.
    const slot = Size(150, 220);
    final sizes = <double>[];
    for (final w in ['111', '888', '407', '1111', '8888', '1000']) {
      await _pump(t, _solar(w), slot);
      sizes.add(_numberSize(t, w));
    }
    // Same number of digits, same size; League Spartan's 1 is half as wide
    // as its 0, which used to make the number jump with each reading.
    expect(sizes[0], sizes[1]);
    expect(sizes[1], sizes[2]);
    expect(sizes[3], sizes[4]);
    expect(sizes[4], sizes[5]);
    expect(t.takeException(), isNull);
  });

  testWidgets('the state chip sits at the right of the title line', (t) async {
    await _pump(t, _solar('648'), const Size(320, 220));
    final title = t.getRect(find.text('Solar').first);
    final chip = t.getRect(find.text('Bulk'));
    expect(chip.center.dy, closeTo(title.center.dy, 2));
    expect(chip.right, greaterThan(285));
    expect(t.takeException(), isNull);
  });

  test('the default card layout puts the state on the title line', () {
    final top = defaultTemplate(_solar('648')).root.children.first;
    expect(top, isA<BoxSplit>());
    final parts = (top as BoxSplit).children.cast<BoxPart>();
    expect(parts.map((p) => p.kind), [PartKind.title, PartKind.chip]);
    expect(parts.last.align, PartAlign.end);
  });
}
