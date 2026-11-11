import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/dashboard/cards/card_model.dart';
import 'package:lecasa/dashboard/cards/tape.dart';
import 'package:lecasa/dashboard/fob_log.dart';
import 'package:lecasa/dashboard/history.dart';
import 'package:lecasa/decoders/bthome.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/registry.dart';

import '../helpers.dart';

final t0 = DateTime(2026, 11, 1, 8);
DateTime at(int minutes, [int seconds = 0]) =>
    t0.add(Duration(minutes: minutes, seconds: seconds));

List<Burst> chirps(int from, int to, int every) => [
  for (var m = from; m <= to; m += every) Burst(at(m), false),
];

final allDay = [Span(t0.subtract(const Duration(hours: 1)), at(24 * 60))];

void main() {
  group('presence', () {
    test('a fob chirping every 5 min is home, and learns the gap', () {
      final p = presenceOf(chirps(0, 60, 5), allDay, at(62));
      expect(p.home, isTrue);
      expect(p.learnt, isTrue);
      expect(p.interval, const Duration(minutes: 5));
      expect(p.timeout, const Duration(minutes: 12, seconds: 30));
    });

    test('one missed chirp is still home; three is away', () {
      final b = chirps(0, 60, 5);
      expect(presenceOf(b, allDay, at(71)).home, isTrue);
      final gone = presenceOf(b, allDay, at(76));
      expect(gone.home, isFalse);
      expect(gone.since, at(72, 30));
      expect(gone.away.single.from, at(72, 30));
    });

    test('a 60 s fob is called away much sooner', () {
      final p = presenceOf(chirps(0, 20, 1), allDay, at(23));
      expect(p.interval, const Duration(minutes: 1));
      expect(p.timeout, const Duration(minutes: 2, seconds: 30));
      expect(p.home, isFalse);
    });

    test('an absence shows as a span and the fob comes back', () {
      final b = [...chirps(0, 30, 5), ...chirps(90, 120, 5)];
      final p = presenceOf(b, allDay, at(121));
      expect(p.home, isTrue);
      expect(p.since, at(90));
      expect(p.away.single.from, at(42, 30));
      expect(p.away.single.to, at(90));
      // The hour away was not learnt as a chirp gap.
      expect(p.interval, const Duration(minutes: 5));
    });

    test('a fob that stretches its gap step by step stays home', () {
      // 1 min after presses, backing off to 2, 5, then 10.
      final b = [
        ...chirps(0, 5, 1),
        ...chirps(7, 13, 2),
        ...chirps(18, 38, 5),
        ...chirps(48, 98, 10),
      ];
      final p = presenceOf(b, allDay, at(100));
      expect(p.away, isEmpty);
      expect(p.home, isTrue);
      expect(p.interval, const Duration(minutes: 10));
    });

    test('presses count as being heard but are not chirp gaps', () {
      final b = [
        ...chirps(0, 20, 5),
        Burst(at(21), true),
        Burst(at(21, 10), true),
        Burst(at(21, 20), true),
        ...chirps(25, 30, 5),
      ];
      final p = presenceOf(b, allDay, at(31));
      expect(p.interval, const Duration(minutes: 5));
      expect(p.lastHeard, at(30));
    });

    test('a gap while the app was closed is not an absence', () {
      final listened = [Span(t0, at(30)), Span(at(120), at(24 * 60))];
      final b = [...chirps(0, 30, 5), ...chirps(125, 140, 5)];
      final p = presenceOf(b, listened, at(141));
      expect(p.away, isEmpty);
      expect(p.home, isTrue);
    });

    test('just started and not heard yet: unsure, then away', () {
      final listened = [Span(t0, at(30)), Span(at(120), at(24 * 60))];
      final b = chirps(0, 30, 5);
      expect(presenceOf(b, listened, at(125)).home, isNull);
      final later = presenceOf(b, listened, at(134));
      expect(later.home, isFalse);
      expect(later.since, at(132, 30));
    });
  });

  group('tape', () {
    test('columns: presses land on their track, away and unheard spans', () {
      final now = at(60);
      final tape = ButtonTape(
        tracks: 4,
        presses: [
          Press(at(58), 2, 'double_press'),
          Press(at(59), 2, 'hold_press'),
          Press(at(30), 4, 'press'),
        ],
        away: [Span(at(10), at(20))],
        listening: [Span(at(5), now)],
        now: now,
      );
      final cols = tapeColumns(tape, 12); // 0..60 min, 5 min each
      expect(cols.length, 12);
      expect(cols.last.$2, [null, 'hold_press', null, null]);
      expect(cols[6].$2[3], 'press');
      expect(cols[0].$1, TapeState.unknown);
      expect(cols[2].$1, TapeState.away);
      expect(cols[3].$1, TapeState.away);
      expect(cols[5].$1, TapeState.home);
    });
  });

  group('Le\'Fob adverts', () {
    final d = BtHomeDecoder();
    // From the 2026-11-01 firmware: packet id, chip temperature, rail
    // voltage, battery low, charging, status text; no name.
    const status =
        '44 00 2a 02 c1 08 0c e1 0c 15 00 16 00 53 07 62 61 74 74 65 72 79';
    const press = '44 00 2b 3a 00 3a 02 3a 00 3a 00';

    test('a status chirp with no name is still a Le\'Fob', () {
      final out = d.decode(adv(serviceData: {0xFCD2: status}))!;
      expect(out.model, "Le'Fob");
      expect(out.kind, DeviceKind.leDevice);
      final r = {for (final x in out.readings) x.label: x.value};
      expect(r['temperature'], 22.41);
      expect(r['voltage'], 3.297);
      expect(r['battery low'], false);
      expect(r['text'], 'battery');
    });

    test('a press keeps the chirp\'s readings, and is logged once', () {
      final tracker = DeviceTracker(DecoderRegistry([BtHomeDecoder()]));
      final h = History(tracker);
      tracker.addListener(h.watch);
      final id = '84:C2:E4:00:00:01';
      tracker.onAdvertisement(
        adv(id: id, mac: id, seenAt: at(0), serviceData: {0xFCD2: status}),
      );
      for (var i = 0; i < 5; i++) {
        tracker.onAdvertisement(
          adv(
            id: id,
            mac: id,
            name: 'le-fob',
            seenAt: at(1, i),
            serviceData: {0xFCD2: press},
          ),
        );
      }
      final v = tracker[id]!.decoded!;
      expect(v.model, "Le'Fob");
      expect(v.readings.map((r) => r.label), contains('temperature'));
      expect(v.events.single.toString(), 'button 2 double_press');
      final log = h.fob(id, at(2))!.$1;
      expect(log.presses.length, 1);
      expect(log.presses.single.button, 2);
      expect(log.bursts.map((b) => b.press), [false, true]);
    });
  });
}
