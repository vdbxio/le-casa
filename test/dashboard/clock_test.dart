import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/card_options.dart';
import 'package:lecasa/dashboard/card_picker.dart';
import 'package:lecasa/dashboard/cards/clock.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/ui/palette.dart';

import 'fake_devices.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  final sunday = DateTime(2026, 10, 25, 9, 5);

  group('clock style', () {
    test('12 and 24 hour time', () {
      expect(const ClockStyle().time(sunday), ('09:05', ''));
      const h12 = ClockStyle(h24: false);
      expect(h12.time(sunday), ('9:05', 'AM'));
      expect(h12.time(DateTime(2026, 1, 1, 0, 30)), ('12:30', 'AM'));
      expect(h12.time(DateTime(2026, 1, 1, 12, 0)), ('12:00', 'PM'));
      expect(h12.time(DateTime(2026, 1, 1, 23, 59)), ('11:59', 'PM'));
    });

    test('date words, numbers, order, year and capitals', () {
      const s = ClockStyle();
      expect(s.dateLine(sunday, roomy: true), 'Sunday 25 October');
      expect(s.dateLine(sunday, roomy: false), 'Sun 25 Oct');
      expect(
        const ClockStyle(
          date: DateWords.full,
          caps: true,
        ).dateLine(sunday, roomy: false),
        'SUNDAY 25 OCTOBER',
      );
      expect(
        const ClockStyle(
          date: DateWords.full,
          order: DateOrder.mdy,
          year: true,
        ).dateLine(sunday, roomy: false),
        'Sunday, October 25, 2026',
      );
      expect(
        const ClockStyle(
          date: DateWords.numeric,
          order: DateOrder.ymd,
          year: true,
          weekday: false,
        ).dateLine(sunday, roomy: true),
        '2026-10-25',
      );
      expect(
        const ClockStyle(date: DateWords.none).dateLine(sunday, roomy: true),
        '',
      );
    });

    test('saved on the card spec, and the default saves nothing', () {
      const style = ClockStyle(
        h24: false,
        date: DateWords.full,
        caps: true,
        dateFont: ClockFont.mono,
      );
      final spec = const CardSpec('clock').copyWith(clock: style);
      final back = CardSpec.fromJson(
        (jsonDecode(jsonEncode(spec.toJson())) as Map).cast(),
      );
      expect(back.clock, style);
      expect(back, spec);
      final plain = spec.copyWith(clock: const ClockStyle());
      expect(plain.clock, isNull);
      expect(plain.toJson().containsKey('ck'), isFalse);
    });
  });

  testWidgets(
    'the time never moves up or down or rescales as the digits change',
    (t) async {
      Future<(Rect, double)> measure(DateTime at, ClockStyle style) async {
        await t.pumpWidget(
          MaterialApp(
            theme: leCasaTheme(Brightness.dark),
            home: Center(
              child: SizedBox(
                width: 420,
                height: 300,
                child: ClockCard(CardSize.large, style: style, at: at),
              ),
            ),
          ),
        );
        final face = find.byType(ClockFace);
        final firstDigit = find
            .descendant(of: face, matching: find.byType(Text))
            .first;
        return (t.getRect(face), t.getSize(firstDigit).height);
      }

      for (final font in ClockFont.values) {
        for (final h24 in [true, false]) {
          final style = ClockStyle(font: font, h24: h24);
          final times = [
            DateTime(2026, 1, 1, 11, 11),
            DateTime(2026, 1, 1, 10, 48),
            DateTime(2026, 1, 1, 0, 0),
            DateTime(2026, 1, 1, 23, 59),
          ];
          final first = await measure(times.first, style);
          for (final at in times.skip(1)) {
            final m = await measure(at, style);
            expect(m.$1.bottom, first.$1.bottom, reason: '$font $h24 $at');
            expect(m.$1.top, first.$1.top, reason: '$font $h24 $at');
            expect(m.$2, first.$2, reason: '$font $h24 $at');
            // Never wider than the space it was sized for.
            expect(m.$1.width, lessThanOrEqualTo(384), reason: '$font $at');
          }
        }
      }
    },
  );

  testWidgets('clock options change the clock in the preview', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final previewDir = Platform.environment['PREVIEW_DIR'];
    final sources = CardSources(tracker: chloesGear());
    Pick? result;
    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          theme: leCasaTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async => result = await showCardOptions(
                  context,
                  spec: const CardSpec('clock'),
                  slotSize: const Size(420, 300),
                  sources: sources,
                  entries: catalog(sources),
                  onDashboard: {'clock'},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    await t.tap(find.text('24-hour time'));
    await t.tap(find.text('Full words'));
    await t.ensureVisible(find.text('Capitals'));
    await t.tap(find.text('Capitals'));
    // The date's fonts are below the fold.
    final dateMono = find.byKey(const ValueKey('date-font.Monospace'));
    await t.dragUntilVisible(
      dateMono,
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await t.pumpAndSettle();
    await t.tap(dateMono);
    await t.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^[A-Z]+DAY ')), findsOneWidget);

    if (previewDir != null) {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final image = await t.runAsync(() => boundary.toImage());
      final bytes = await t.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      File('$previewDir/options-clock.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    final clock = (result as PickCard).spec.clock!;
    expect(clock.h24, isFalse);
    expect(clock.date, DateWords.full);
    expect(clock.caps, isTrue);
    expect(clock.dateFont, ClockFont.mono);
    expect(clock.font, ClockFont.spartan);
  });
}
