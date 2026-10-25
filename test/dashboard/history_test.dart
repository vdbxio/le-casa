import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/history.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_devices.dart';

void main() {
  test('history survives a save and reload', () async {
    SharedPreferences.setMockInitialValues({});
    final h = History(chloesGear());
    for (var i = 0; i < 4; i++) {
      h.sample();
    }
    await h.save();

    final again = History(chloesGear());
    await again.load();
    expect(again.of(History.solarTotal), h.of(History.solarTotal));
    expect(again.of(History.solarTotal)!.length, 4);
  });

  test('samples that fell out of the 24 h window are dropped', () {
    final saved = {
      'at': DateTime(2026, 10, 24, 12).millisecondsSinceEpoch,
      'series': {'a': List<num>.generate(History.keep, (i) => i)},
    };
    final h = History(chloesGear());
    // Off for an hour: 30 two-minute samples have aged out.
    h.restore(saved, DateTime(2026, 10, 24, 13));
    final a = h.of('a')!;
    expect(a.length, History.keep - 30);
    expect(a.first, 30);

    final old = History(chloesGear());
    old.restore(saved, DateTime(2026, 10, 26));
    expect(old.of('a'), isNull);
  });
}
