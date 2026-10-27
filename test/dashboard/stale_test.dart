import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/cards/card_view.dart';
import 'package:lecasa/dashboard/cards/template.dart';
import 'package:lecasa/dashboard/cards/template_view.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/ui/palette.dart';

import 'fake_devices.dart';

void main() {
  final later = DateTime.now().add(const Duration(hours: 5, minutes: 1));

  test('a device not heard for hours fades and says for how long', () {
    final s = CardSources(tracker: chloesGear(), now: () => later);
    final m = modelFor(const CardSpec.device('luna'), s);
    expect(m.stale, isTrue);
    expect(m.quiet, 'Not heard for 5h');
    // The last readings stay, faded.
    expect(m.headline, isNotNull);
  });

  test('a device held open counts its last read as heard', () {
    final t = chloesGear();
    final soon = DateTime.now().add(const Duration(minutes: 10));
    t.setRemote(
      'lilith',
      decoded: t['lilith']!.view!,
      at: soon.subtract(const Duration(minutes: 1)),
      by: 'iPad',
    );
    final s = CardSources(tracker: t, now: () => soon);
    expect(modelFor(const CardSpec.device('lilith'), s).stale, isFalse);
    expect(
      modelFor(const CardSpec.device('luna'), s).quiet,
      'Not heard for 10m',
    );
  });

  test('combined solar fades only when every charger is quiet', () {
    final fresh = modelFor(
      const CardSpec('solar'),
      CardSources(tracker: chloesGear()),
    );
    expect(fresh.stale, isFalse);
    final old = modelFor(
      const CardSpec('solar'),
      CardSources(tracker: chloesGear(), now: () => later),
    );
    expect(old.stale, isTrue);
    expect(old.quiet, 'Not heard for 5h');
  });

  testWidgets('a pill and a card without a message box show the time', (
    tester,
  ) async {
    final t = chloesGear();
    final fresh = modelFor(
      const CardSpec.device('luna'),
      CardSources(tracker: t),
    );
    final quiet = modelFor(
      const CardSpec.device('luna'),
      CardSources(tracker: t, now: () => later),
    );
    // A card the person built while the device was talking: no message box.
    final built = defaultTemplate(fresh);
    await tester.pumpWidget(
      MaterialApp(
        theme: leCasaTheme(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              Pill(quiet),
              SizedBox(
                width: 320,
                height: 200,
                child: TemplateCard(quiet, built),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('not heard 5h'), findsOneWidget);
    expect(find.text('Not heard for 5h'), findsOneWidget);
  });
}
