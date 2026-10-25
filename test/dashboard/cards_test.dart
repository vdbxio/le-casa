import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/auto_layout.dart';
import 'package:lecasa/dashboard/cards/fit.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/settings/dimmer.dart';

import 'fake_devices.dart';

void main() {
  final sources = CardSources(tracker: chloesGear());

  test('catalog offers combined solar, every device and the widgets', () {
    final keys = catalog(sources).map((e) => e.spec.key).toList();
    expect(keys.first, 'solar');
    expect(
      keys,
      containsAll(['device:luna', 'device:sol', 'clock', 'weather', 'tablet']),
    );
  });

  test('names: real names kept, module ids replaced', () {
    final byKey = {for (final e in catalog(sources)) e.spec.key: e.title};
    expect(byKey['device:luna'], 'Luna 50');
    expect(byKey['device:A4:C1:38:50:6E:3A'], 'Climate · 6E3A');
    expect(byKey['device:D2:19:08:01:C5:61'], 'Battery · C561');
  });

  test('combined solar adds the chargers up and keeps each share', () {
    final m = modelFor(const CardSpec('solar'), sources);
    expect(m.headline!.value, '648');
    expect(m.shares.map((s) => s.name), ['Luna 50', 'Sol 30']);
    expect(m.details.map((d) => d.inline), ['26.62 V', '24.2 A', '2.86 kWh']);
  });

  test('battery cards show charge, a ring and direction', () {
    final m = modelFor(const CardSpec.device('lilith'), sources);
    expect(m.headline!.inline, '87.4 %');
    expect(m.ring, 87.4);
    expect(m.state, 'Charging');
    expect(m.details.map((d) => d.inline), contains('24h 0m'));
    // Watts as well as amps: 26.58 V × 18.2 A.
    expect(m.details.map((d) => d.inline), contains('+484 W'));
  });

  test('a device that needs setup says so instead of showing numbers', () {
    final m = modelFor(const CardSpec.device('heater'), sources);
    expect(m.headline, isNull);
    expect(m.note, contains('connection'));
  });

  test('a placed device not heard since restart shows its saved name', () {
    final m = modelFor(const CardSpec.device('gone', name: 'Lilith'), sources);
    expect(m.title, 'Lilith');
    expect(m.note, 'Listening for this device…');
  });

  test('cards remember device names for after a restart', () {
    final layout = DashboardLayout(
      Split(SplitAxis.horizontal, [
        Slot(const CardSpec.device('luna')),
        Slot(const CardSpec('chips', items: [CardSpec.device('sol')])),
      ]),
    );
    final byId = {'luna': 'Luna 50', 'sol': 'Sol 30'};
    expect(layout.rememberNames((id) => byId[id]), isTrue);
    final restored = DashboardLayout.fromJson(layout.toJson());
    final cards = [for (final (_, s) in restored.slots) s.card!];
    expect(cards[0].name, 'Luna 50');
    expect(cards[1].items.single.name, 'Sol 30');
    expect(layout.rememberNames((id) => byId[id]), isFalse);
  });

  test('weather without the service offers to set it up', () {
    final m = modelFor(const CardSpec('weather'), sources);
    expect(m.setup, 'Set up weather');
  });

  group('fit', () {
    final solar = modelFor(const CardSpec('solar'), sources);
    test('steps down as the slot shrinks', () {
      expect(fitSize(solar, const Size(420, 520)), CardSize.large);
      expect(fitSize(solar, const Size(420, 220)), CardSize.medium);
      expect(fitSize(solar, const Size(200, 220)), CardSize.small);
      expect(fitSize(solar, const Size(300, 70)), CardSize.pill);
    });
    test('a tall narrow slot still gets the biggest size that fits', () {
      expect(fitSize(solar, const Size(240, 700)), CardSize.medium);
    });
  });

  test('first-run layout: clock and solar, batteries, then the rest', () {
    final l = autoLayout(catalog(sources));
    final types = [
      for (final (_, s) in l.slots)
        s.card!.type == 'device' ? s.card!.device! : s.card!.type,
    ];
    expect(types.take(4), ['clock', 'solar', 'lilith', 'D2:19:08:01:C5:61']);
    expect(types, containsAll(['weather', 'chips']));
    // Single chargers are covered by the combined card, the heater needs
    // setup: neither is placed.
    expect(types, isNot(contains('luna')));
    expect(l.cardKeys, isNot(contains('device:heater')));
    // No duplicates anywhere, chip rows included.
    final all = [
      for (final (_, s) in l.slots)
        if (s.card!.type == 'chips')
          ...s.card!.items.map((i) => i.key)
        else
          s.card!.key,
    ];
    expect(all.toSet().length, all.length);
    expect(l.depth, lessThanOrEqualTo(maxSplitDepth));
  });

  test('auto-dim maps room light to brightness', () {
    expect(brightnessForLux(0, 0.15), 0.15);
    expect(brightnessForLux(500, 0.15), closeTo(1, 1e-9));
    expect(brightnessForLux(20000, 0.15), 1);
    final mid = brightnessForLux(30, 0.15);
    expect(mid, inExclusiveRange(0.15, 1));
  });
}
