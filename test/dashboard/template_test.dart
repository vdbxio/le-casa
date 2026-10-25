import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Split;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/card_options.dart';
import 'package:lecasa/dashboard/card_picker.dart';
import 'package:lecasa/dashboard/cards/template.dart';
import 'package:lecasa/dashboard/cards/template_view.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/ui/palette.dart';

import 'fake_devices.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  final sources = CardSources(tracker: chloesGear());
  final solar = sources.model(const CardSpec('solar'));
  final lilith = sources.model(const CardSpec.device('lilith'));

  group('data points', () {
    test('a card offers its readings, state, graph and each share', () {
      final ids = dataPoints(solar).map((p) => p.id).toList();
      expect(ids.first, 'title');
      expect(ids, containsAll(['m:solar', 'state', 'split', 'm:today']));
      expect(ids, containsAll(['s:luna 50', 's:sol 30']));
      final luna = pointById(dataPoints(solar), 's:luna 50')!;
      expect(luna.metric!.inline, '412 W');
    });

    test('every box of the default arrangement shows something real', () {
      for (final m in [solar, lilith]) {
        final points = dataPoints(m);
        for (final (_, p) in defaultTemplate(m).parts) {
          expect(pointById(points, p.point), isNotNull, reason: p.point);
        }
      }
    });

    test('suggestions lead with points of the same kind', () {
      final t = defaultTemplate(solar);
      final (path, _) = t.parts.firstWhere(
        (e) => e.$2.kind == PartKind.reading,
      );
      final s = suggestedFor(t, path, dataPoints(solar));
      expect(s.first.kinds.first, PartKind.reading);
    });
  });

  group('boxes', () {
    test('round trip through JSON, including on the card spec', () {
      final t = defaultTemplate(solar);
      final spec = const CardSpec('solar').copyWith(template: t);
      final back = CardSpec.fromJson(
        (jsonDecode(jsonEncode(spec.toJson())) as Map).cast(),
      );
      expect(back, spec);
      expect(jsonEncode(back.template!.toJson()), jsonEncode(t.toJson()));
      expect(back.copyWith(clearTemplate: true).template, isNull);
    });

    test('adding beside a box in a stack nests a row; in a row it shares', () {
      final t = CardTemplate(
        BoxSplit(SplitAxis.vertical, [
          BoxPart(PartKind.title, 'title'),
          BoxPart(PartKind.big, 'm:solar'),
        ]),
      );
      final p = t.split(const [1], SplitAxis.horizontal);
      expect(p, [1, 1]);
      expect((t.at(const [1]) as BoxSplit).axis, SplitAxis.horizontal);
      final q = t.split(const [1, 1], SplitAxis.horizontal);
      expect(q, [1, 2]);
      expect((t.at(const [1]) as BoxSplit).children, hasLength(3));
      expect((t.at(q) as BoxPart).isEmpty, isTrue);
    });

    test('removing tidies up, and the last box is emptied not removed', () {
      final t = CardTemplate(
        BoxSplit(SplitAxis.vertical, [
          BoxPart(PartKind.title, 'title'),
          BoxSplit(SplitAxis.horizontal, [
            BoxPart(PartKind.big, 'm:solar'),
            BoxPart(PartKind.chip, 'state'),
          ]),
        ]),
      );
      t.remove(const [1, 1]);
      expect(t.at(const [1]), isA<BoxPart>());
      t.remove(const [0]);
      expect(t.root.children, hasLength(1));
      t.remove(const [0]);
      expect((t.root.children.single as BoxPart).isEmpty, isTrue);
    });

    test('boxes drop from the end when the slot is too short', () {
      final t = defaultTemplate(solar);
      final roomy = planTemplate(t, const Rect.fromLTWH(0, 0, 400, 400));
      expect(roomy.hidden, isEmpty);
      final short = planTemplate(t, const Rect.fromLTWH(0, 0, 400, 90));
      expect(short.hidden, isNotEmpty);
      expect(short.parts.first.part.kind, PartKind.title);
      final kept = planTemplate(
        t,
        const Rect.fromLTWH(0, 0, 400, 90),
        keepAll: true,
      );
      expect(kept.hidden, isEmpty);
    });
  });

  testWidgets('card options: tap a box, pick a reading, add a box, save', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final previewDir = Platform.environment['PREVIEW_DIR'];

    Pick? result;
    var current = const CardSpec('solar');
    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          theme: leCasaTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async => result = await showCardOptions(
                  context,
                  spec: current,
                  slotSize: const Size(420, 300),
                  sources: sources,
                  entries: catalog(sources),
                  onDashboard: {'solar'},
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

    Future<void> shot(String name) async {
      if (previewDir == null) return;
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final image = await t.runAsync(() => boundary.toImage());
      final bytes = await t.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      File('$previewDir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    await shot('options-cards');

    // Tap the big number.
    await t.tap(
      find.descendant(
        of: find.byType(TemplateCard),
        matching: find.textContaining('648'),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Big number'), findsWidgets);
    expect(find.text('SUGGESTED FOR THIS BOX'), findsOneWidget);
    await shot('options-box');

    // Show the battery voltage instead, centred.
    await t.tap(find.text('Battery').last);
    await t.pump();
    await t.tap(find.byTooltip('Align centre'));
    await t.pump();
    // And add a box beside it.
    await t.tap(find.text('Add beside'));
    await t.pumpAndSettle();
    expect(find.text('Empty box'), findsOneWidget);
    await shot('options-added');

    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    final spec = (result as PickCard).spec;
    final parts = spec.template!.parts.map((e) => e.$2).toList();
    final big = parts.firstWhere((p) => p.kind == PartKind.big);
    expect(big.point, 'm:battery');
    expect(big.align, PartAlign.center);
    expect(parts.where((p) => p.isEmpty), hasLength(1));
    current = spec;

    // Reset goes back to the automatic layout.
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('Reset to default'));
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect((result as PickCard).spec.template, isNull);
  });

  testWidgets('a templated card draws at many sizes without overflow', (
    t,
  ) async {
    for (final size in const [
      Size(460, 380),
      Size(300, 170),
      Size(600, 120),
      Size(180, 220),
    ]) {
      await t.pumpWidget(
        MaterialApp(
          theme: leCasaTheme(Brightness.dark),
          home: Material(
            child: Center(
              child: SizedBox.fromSize(
                size: size,
                child: TemplateCard(solar, defaultTemplate(solar)),
              ),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull, reason: '$size');
    }
  });
}
