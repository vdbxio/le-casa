import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/appliances.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/drivers/alpicool_driver.dart';
import 'package:lecasa/drivers/alpicool_protocol.dart';
import 'package:lecasa/drivers/driver.dart';

import 'fake_session.dart';
import 'helpers.dart';

Uint8List _h(String s) => fromHex(s.replaceAll(' ', ''));

/// Chloe's AK1 fridge, 2026-10-25, read from a Mac: on, 48 °F against a
/// 48 °F target, settable -4..68 °F, 26.3 V supply. Long frame, one zone.
final _ak1 = _h(
  'fe fe 21 01 00 01 00 00 30 44 fc 02 00 01 00 00 fb 00 30 64 1a 03 '
  '00 00 00 00 00 00 00 00 00 00 01 00 05 3f',
);

/// fridgekit's sample: single zone, -3 °C target, -4 °C inside, 14.4 V.
final _fridgekit = _h(
  'fe fe 15 01 00 01 00 00 fd 14 ec 02 00 00 00 00 00 00 fc 64 0e 04 05 84',
);

void main() {
  group('frames', () {
    test('query and set-target frames', () {
      expect(hex(alpicoolQuery(), sep: ''), 'fefe03010200');
      // BrassMonkeyFridgeMonitor's example sets the left target to -20 and
      // prints the length as 03, but its checksum (02 f1) only adds up with
      // a length of 04, which is also what the rule gives.
      expect(hex(alpicoolSetTarget(1, -20), sep: ''), 'fefe0405ec02f1');
    });

    test('checksums, including units that send twice the sum', () {
      expect(alpicoolValid(_ak1), isTrue);
      expect(alpicoolValid(_fridgekit), isTrue);
      final doubled = Uint8List.fromList(_fridgekit);
      final sum = doubled
          .sublist(0, doubled.length - 2)
          .fold<int>(0, (a, b) => a + b);
      doubled[doubled.length - 2] = (sum * 2) >> 8 & 0xFF;
      doubled[doubled.length - 1] = (sum * 2) & 0xFF;
      expect(alpicoolValid(doubled), isTrue);
      final bad = Uint8List.fromList(_ak1)..[10] ^= 1;
      expect(alpicoolValid(bad), isFalse);
    });

    test('framer joins split notifications and skips junk', () {
      final f = AlpicoolFramer();
      expect(f.add([0x00, 0x11, ..._ak1.sublist(0, 7)]), isEmpty);
      expect(f.add(_ak1.sublist(7, 20)), isEmpty);
      final out = f.add([..._ak1.sublist(20), ..._fridgekit]);
      expect(out.map((x) => hex(x, sep: '')), [
        hex(_ak1, sep: ''),
        hex(_fridgekit, sep: ''),
      ]);
    });
  });

  group('status', () {
    test('Chloe\'s fridge: Fahrenheit, one zone in a long frame', () {
      final s = parseAlpicoolStatus(_ak1)!;
      expect(s.on, isTrue);
      expect(s.locked, isFalse);
      expect(s.eco, isFalse);
      expect(s.fahrenheit, isTrue);
      expect(s.unit, '°F');
      expect(s.zone1.target, 48);
      expect(s.zone1.current, 48);
      expect((s.minTemp, s.maxTemp), (-4, 68));
      expect(s.zone1.calibration, [0, 0, -5 & 0xFF, 0]);
      expect(s.zone2, isNull, reason: 'second zone is all zero');
      expect(s.batteryPercent, 100);
      expect(s.batteryVoltage, closeTo(26.3, 1e-9));
    });

    test('fridgekit sample', () {
      final s = parseAlpicoolStatus(_fridgekit)!;
      expect(s.fahrenheit, isFalse);
      expect(s.zone1.target, -3);
      expect(s.zone1.current, -4);
      expect((s.minTemp, s.maxTemp), (-20, 20));
      expect(s.batteryVoltage, closeTo(14.4, 1e-9));
    });

    test('settings block writes everything back with one change', () {
      final short = parseAlpicoolStatus(_fridgekit)!;
      expect(
        hex(short.settings(eco: true), sep: ''),
        '00010100fd14ec02000000000000',
      );
      final long = parseAlpicoolStatus(_ak1)!;
      final b = long.settings(on: false);
      expect(b.length, 25, reason: 'long frame gets the long block back');
      expect(
        hex(b.sublist(0, 14), sep: ''),
        '0000000030'
        '44fc02000100'
        '00fb00',
      );
    });

    test('decoded readings', () {
      final d = alpicoolToDecoded(parseAlpicoolStatus(_ak1)!, module: 'AK1-X');
      String r(String l) => d.readings.firstWhere((x) => x.label == l).display;
      expect(r('temperature'), '48 °F');
      expect(r('target'), '48 °F');
      expect(r('power'), 'on');
      expect(r('mode'), 'Max');
      expect(r('battery voltage'), '26.3 V');
      expect(r('battery protection'), 'Low');
      expect(d.info['settable range'], '-4 to 68 °F');
    });
  });

  group('recognition', () {
    test('by name or by the 1234567890 manufacturer data', () {
      const dec = AlpicoolDecoder();
      expect(dec.matches(adv(name: 'AK1-AAFE13156431')), isTrue);
      expect(
        dec.matches(adv(manufacturerData: {0x3231: '333435363738393031'})),
        isTrue,
      );
      expect(dec.matches(adv(manufacturerData: {0x3231: '3334'})), isFalse);
      expect(dec.decode(adv(name: 'AK1-X'))!.needs, contains('Alpicool app'));
    });
  });

  group('driver', () {
    late List<Uint8List> writes;
    late Uint8List state;

    FakeSession fridge() => FakeSession(
      characteristics: const [
        GattChar(alpicoolWrite, canWrite: true, canWriteWithoutResponse: true),
        GattChar(alpicoolNotify, canRead: true, canNotify: true),
      ],
      onWrite: (c, data) {
        writes.add(data);
        if (data[3] == AlpicoolCmd.query) {
          // answer in two chunks, as a small MTU would
          return [state.sublist(0, 10), state.sublist(10)];
        }
        if (data[3] == AlpicoolCmd.setZone1) {
          final d = Uint8List.fromList(state);
          d[8] = data[4];
          final sum = d.sublist(0, d.length - 2).fold<int>(0, (a, b) => a + b);
          d[d.length - 2] = sum >> 8 & 0xFF;
          d[d.length - 1] = sum & 0xFF;
          state = d;
          return [data]; // the fridge echoes it
        }
        return const [];
      },
    );

    setUp(() {
      writes = [];
      state = Uint8List.fromList(_ak1);
    });

    final a = adv(name: 'AK1-AAFE13156431');

    test('reads the status', () async {
      final d = await const AlpicoolDriver().read(fridge(), a);
      expect(d.model, 'Alpicool fridge');
      expect(d.readings.first.display, '48 °F');
      expect(writes.map((w) => hex(w, sep: '')), ['fefe03010200']);
    });

    test('sets the target and reads it back', () async {
      final d = await const AlpicoolDriver().control(
        fridge(),
        a,
        const DeviceCommand(FridgeSetting.target, 40),
      );
      expect(writes.map((w) => hex(w, sep: '')), [
        'fefe03010200',
        hex(alpicoolSetTarget(1, 40), sep: ''),
        'fefe03010200',
      ]);
      expect(
        d.readings.firstWhere((r) => r.label == 'target').display,
        '40 °F',
      );
    });

    test('keeps the target inside the fridge\'s range', () async {
      await const AlpicoolDriver().control(
        fridge(),
        a,
        const DeviceCommand(FridgeSetting.target, -30),
      );
      expect(writes[1], alpicoolSetTarget(1, -4));
    });

    test('power off sends the whole settings block', () async {
      await const AlpicoolDriver().control(
        fridge(),
        a,
        const DeviceCommand(FridgeSetting.power, false),
      );
      final set = writes[1];
      expect(set[3], AlpicoolCmd.set);
      expect(alpicoolValid(set), isTrue);
      final block = set.sublist(4, set.length - 2);
      expect(block, parseAlpicoolStatus(_ak1)!.settings(on: false));
      expect(block[1], 0);
    });
  });
}
