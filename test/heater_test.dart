import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/drivers/hcalory_protocol.dart';
import 'package:lecasa/drivers/heater_driver.dart';
import 'package:lecasa/drivers/heater_protocol.dart';

import 'fake_session.dart';
import 'helpers.dart';

// Status frames from homeassistant-diesel-heater's tests (MIT).

/// Level mode: on, running, level 8, 12.6 V, exchanger 200, air 25, fault 3.
final _aa55Level = fromHex('aa5500010303e8030108007e00c800190000');

/// Thermostat: on, running, 23 °C target, 24 V, exchanger -100, air -5.
final _aa55Temp = fromHex('aa5500010003d204021704f0009cfffbff00');

/// Manual mode, off, level 7 from byte 10, 12 V, air 18.
final _aa55Manual = fromHex('aa5500002a00000000000678000000120000');

final _aa66Level = fromHex('aa6600010003e8030108007e00c8001900030000');
final _aa66Temp = fromHex('aa6600010003d204021704f000c800fbff000000');

/// A 48-byte AA 55 status in the clear: on, running, thermostat at 21 °C,
/// level 6, 13.2 V, exchanger 160, air 19.5, a CO sensor reading 12 ppm.
Uint8List _aa55EncClear() {
  final d = Uint8List(48);
  d.setAll(0, [0xAA, 0x55, 0x0C, 0x22, 0x01, 0x00, 0x03, 0x00, 0x00]);
  d[3] = 1; // on
  d[4] = 0; // no fault
  d[8] = HeaterMode.temperature;
  d[9] = 21;
  d[10] = 6;
  d[11] = 0x00;
  d[12] = 0x84; // 132 -> 13.2 V
  d[13] = 0x00;
  d[14] = 0xA0; // 160
  d[32] = 0x00;
  d[33] = 0xC3; // 195 -> 19.5
  d[37] = 1;
  d[38] = 0;
  d[39] = 12;
  return d;
}

// Chloe's Hcalory heater (MVP2 module), read from a Mac on 2026-10-31.

/// Running at level 2: cabin 21 °C, exchanger 230 °C, 26.0 V.
final _mvp2Running = fromHex(
  '00010001000100230300001effff01f4000000008502020201040008fc0000d2008cf9'
  '0001000100000001',
);

/// The PIN replies: 1234 refused (02), 0000 accepted (01).
final _pinRefused = fromHex('000300010001000b0c0000060101020304021f');
final _pinAccepted = fromHex('000300010001000b0c00000601000000000114');

void main() {
  group('Hcalory MVP2', () {
    test('frames match what Chloe\'s heater accepted', () {
      expect(
        hex(hcaloryPin('0000'), sep: ''),
        '000200010001000a0c000005010000000012',
      );
      expect(
        hex(hcaloryPin('1234'), sep: ''),
        '000200010001000a0c00000501010203041c',
      );
      expect(
        hex(hcaloryPress(HcaloryButton.query), sep: ''),
        '000200010001000e040000090000000000000000000d',
      );
      // hcalory-control's start and stop presses.
      expect(
        hex(hcaloryPress(HcaloryButton.on), sep: '').substring(40),
        '020f',
      );
      expect(
        hex(hcaloryPress(HcaloryButton.off), sep: '').substring(40),
        '010e',
      );
      // The set-temperature example from diesel-heater-ble: 20 °C.
      expect(hex(hcaloryTarget(20), sep: ''), '00020001000100070600000214001c');
    });

    test('PIN replies', () {
      expect(hcaloryPinAccepted(_pinAccepted), isTrue);
      expect(hcaloryPinAccepted(_pinRefused), isFalse);
      expect(hcaloryPinAccepted(_mvp2Running), isNull);
    });

    test('status', () {
      final s = parseHcaloryStatus(_mvp2Running)!;
      expect(s.on, isTrue);
      expect(s.stepName, 'Running');
      expect(s.mode, HeaterMode.level);
      expect(s.level, 2);
      expect(s.target, isNull);
      expect(s.voltage, closeTo(26.0, 1e-9));
      expect(s.caseTemp, 230);
      expect(s.cabinTemp, 21);
      expect(s.errorName, isNull);
      expect((s.minTarget, s.maxTarget), (0, 40));
      final bad = Uint8List.fromList(_mvp2Running)..[30] ^= 1;
      expect(parseHcaloryStatus(bad), isNull, reason: 'checksum');
    });

    test('off, stopping and fault', () {
      Uint8List withState(int b20, [int b22 = 2]) {
        final f = Uint8List.fromList(_mvp2Running)
          ..[20] = b20
          ..[22] = b22;
        f[f.length - 1] =
            f.sublist(8, f.length - 1).fold<int>(0, (a, b) => a + b) & 0xFF;
        return f;
      }

      final off = parseHcaloryStatus(withState(0x00))!;
      expect((off.on, off.stepName, off.level), (false, 'Standby', null));
      final stopping = parseHcaloryStatus(withState(0x45))!;
      expect((stopping.on, stopping.stepName), (false, 'Cooling down'));
      final fault = parseHcaloryStatus(withState(0xF0, 7))!;
      expect(fault.errorName, 'E07 low voltage');
    });

    test('framer joins a status split by a small MTU', () {
      final f = HcaloryFramer();
      expect(f.add(_mvp2Running.sublist(0, 20)), isEmpty);
      expect(f.add(_mvp2Running.sublist(20, 40)), isEmpty);
      expect(f.add(_mvp2Running.sublist(40)).single, _mvp2Running);
      expect(f.add(_pinAccepted).single, _pinAccepted);
    });

    group('driver', () {
      late List<Uint8List> writes;
      late Uint8List state;

      FakeSession heater() => FakeSession(
        characteristics: const [
          GattChar(hcaloryWrite, canWrite: true, canWriteWithoutResponse: true),
          GattChar(hcaloryNotify, canRead: true, canNotify: true),
        ],
        onWrite: (c, data) {
          writes.add(data);
          final dp = data[7] << 8 | data[8];
          if (dp == HcaloryDp.pin) {
            return [data[13] == 0 ? _pinAccepted : _pinRefused];
          }
          if (dp == HcaloryDp.setLevel) {
            state = Uint8List.fromList(state)..[22] = data[12];
            state[state.length - 1] =
                state
                    .sublist(8, state.length - 1)
                    .fold<int>(0, (a, b) => a + b) &
                0xFF;
          }
          return [state.sublist(0, 20), state.sublist(20)];
        },
      );

      setUp(() {
        writes = [];
        state = Uint8List.fromList(_mvp2Running);
      });

      final a = adv(name: null, serviceUuids: const [0xBD39]);

      test('matches the 0xBD39 advert', () {
        expect(const HeaterDriver().matches(a), isTrue);
      });

      test('sends the PIN, then reads', () async {
        final d = await const HeaterDriver().read(heater(), a);
        String r(String l) =>
            d.readings.firstWhere((x) => x.label == l).display;
        expect(r('temperature'), '21 °C');
        expect(r('level'), '2');
        expect(r('state'), 'Running');
        expect(r('supply voltage'), '26 V');
        expect(d.info['target range'], '0 to 40 °C');
        expect(writes.map((w) => hex(w, sep: '')), [
          hex(hcaloryPin('0000'), sep: ''),
          hex(hcaloryPress(HcaloryButton.query), sep: ''),
        ]);
      });

      test('sends the PIN again when its reply is lost', () async {
        var pins = 0;
        final session = FakeSession(
          characteristics: const [
            GattChar(hcaloryWrite, canWriteWithoutResponse: true),
            GattChar(hcaloryNotify, canNotify: true),
          ],
          onWrite: (c, data) {
            if (data[8] == 0x0C) {
              return ++pins == 1 ? const [] : [_pinAccepted];
            }
            return [state];
          },
        );
        await const HeaterDriver().read(session, a);
        expect(pins, 2);
      });

      test('sets a level and reads it back', () async {
        final d = await const HeaterDriver().control(
          heater(),
          a,
          const DeviceCommand(HeaterSetting.level, 3),
        );
        expect(writes[2], hcaloryLevel(3));
        expect(d.readings.firstWhere((r) => r.label == 'level').value, 3);
      });
    });
  });

  group('commands', () {
    test('eight bytes with the passkey as base-100 digits', () {
      // The command matrix from homeassistant-diesel-heater, passkey 1234.
      expect(hex(heaterCommand(0, 0), sep: ''), 'aa550c220000002e');
      expect(hex(heaterCommand(1, 0), sep: ''), 'aa550c220100002f');
      expect(hex(heaterCommand(2, 1), sep: ''), 'aa550c2202010031');
      expect(hex(heaterCommand(2, 2), sep: ''), 'aa550c2202020032');
      expect(hex(heaterCommand(3, 0), sep: ''), 'aa550c2203000031');
      expect(hex(heaterCommand(3, 1), sep: ''), 'aa550c2203010032');
    });

    test('16-bit argument, other passkeys', () {
      expect(hex(heaterCommand(2, 300), sep: ''), 'aa550c22022c015d');
      expect(hex(heaterCommand(1, 0, passkey: 0), sep: ''), 'aa55000001000001');
    });
  });

  group('status', () {
    test('AA55 level mode', () {
      final s = parseHeaterStatus(_aa55Level)!;
      expect(s.layout, 'AA55');
      expect(s.on, isTrue);
      expect(s.stepName, 'Running');
      expect(s.error, 3);
      expect(s.errorName, 'Supply voltage out of range');
      expect(s.mode, HeaterMode.level);
      expect(s.level, 8);
      expect(s.target, isNull);
      expect(s.voltage, closeTo(12.6, 1e-9));
      expect(s.caseTemp, 200);
      expect(s.cabinTemp, 25);
    });

    test('AA55 thermostat with sub-zero readings', () {
      final s = parseHeaterStatus(_aa55Temp)!;
      expect(s.mode, HeaterMode.temperature);
      expect(s.target, 23);
      expect(s.level, 5);
      expect(s.voltage, closeTo(24.0, 1e-9));
      expect(s.caseTemp, -100);
      expect(s.cabinTemp, -5);
      expect(s.errorName, isNull);
    });

    test('AA55 manual mode takes its level from byte 10', () {
      final s = parseHeaterStatus(_aa55Manual)!;
      expect(s.on, isFalse);
      expect(s.stepName, 'Standby');
      expect(s.level, 7);
      expect(s.cabinTemp, 18);
    });

    test('AA66 keeps its fault code at byte 17', () {
      final l = parseHeaterStatus(_aa66Level)!;
      expect(l.layout, 'AA66');
      expect(l.level, 8);
      expect(l.error, 3);
      expect(l.caseTemp, 200);
      final t = parseHeaterStatus(_aa66Temp)!;
      expect(t.target, 23);
      expect(t.level, 5);
      expect(t.error, 0);
      expect(t.cabinTemp, -5);
    });

    test('encrypted 48-byte frames', () {
      final clear = _aa55EncClear();
      final wire = heaterXor(clear);
      expect(hex(wire.sublist(0, 2), sep: ''), 'da34');
      final s = parseHeaterStatus(wire)!;
      expect(s.layout, 'AA55 encrypted');
      expect(s.on, isTrue);
      expect(s.target, 21);
      expect(s.level, 6);
      expect(s.voltage, closeTo(13.2, 1e-9));
      expect(s.caseTemp, 160);
      expect(s.cabinTemp, closeTo(19.5, 1e-9));
      expect(s.coPpm, 12);

      final aa66 = Uint8List.fromList(clear)
        ..[1] = 0x66
        ..[27] =
            1 // Fahrenheit
        ..[35] = 7; // fan fault
      final f = parseHeaterStatus(heaterXor(aa66))!;
      expect(f.layout, 'AA66 encrypted');
      expect(f.unit, '°F');
      expect(f.errorName, 'Fan fault');
    });

    test('rejects other frames', () {
      expect(parseHeaterStatus(fromHex('aa55000100')), isNull);
      expect(parseHeaterStatus(Uint8List(48)), isNull);
      expect(
        parseHeaterStatus(fromHex('fefe03010200aabbccddeeff0011223344')),
        isNull,
      );
    });
  });

  group('framer', () {
    test('clear frames pass through, encrypted ones are joined', () {
      final f = HeaterFramer();
      expect(f.add(_aa55Level).single, _aa55Level);
      final wire = heaterXor(_aa55EncClear());
      expect(f.add(wire.sublist(0, 20)), isEmpty);
      expect(f.add(wire.sublist(20, 40)), isEmpty);
      expect(f.add(wire.sublist(40)).single, wire);
      expect(f.add([0x01, 0x02, 0x03]), isEmpty, reason: 'stray bytes');
    });
  });

  group('driver', () {
    late List<Uint8List> writes;
    late Uint8List state;

    FakeSession heater() => FakeSession(
      characteristics: const [
        GattChar(
          heaterChar,
          canWrite: true,
          canWriteWithoutResponse: true,
          canNotify: true,
        ),
      ],
      onWrite: (c, data) {
        writes.add(data);
        final d = Uint8List.fromList(state);
        switch (data[4]) {
          case HeaterCmd.power:
            d[3] = data[5];
            d[4] = 0;
            d[5] = data[5] == 1 ? 2 : 4;
          case HeaterCmd.mode:
            d[8] = data[5];
          case HeaterCmd.setValue:
            d[9] = data[5];
        }
        state = d;
        return [state];
      },
    );

    setUp(() {
      writes = [];
      state = Uint8List.fromList(_aa55Level);
    });

    final a = adv(name: 'BYD-DC32622B4821', serviceUuids: const [0xFFE0]);

    test('matches the BYD- module', () {
      expect(const HeaterDriver().matches(a), isTrue);
      expect(const HeaterDriver().matches(adv(name: 'BYD-X')), isFalse);
    });

    test('reads the status', () async {
      final d = await const HeaterDriver().read(heater(), a);
      String r(String l) => d.readings.firstWhere((x) => x.label == l).display;
      expect(d.protocol, 'Hcalory');
      expect(r('temperature'), '25 °C');
      expect(r('level'), '8');
      expect(r('mode'), 'Level');
      expect(r('supply voltage'), '12.6 V');
      expect(r('state'), 'Supply voltage out of range');
      expect(d.info['layout'], 'AA55');
      expect(writes.map((w) => hex(w, sep: '')), ['aa550c220100002f']);
    });

    test('turns on and reads back', () async {
      state = Uint8List.fromList(_aa55Manual);
      final d = await const HeaterDriver().control(
        heater(),
        a,
        const DeviceCommand(HeaterSetting.power, true),
      );
      expect(writes.map((w) => w[4]), [
        HeaterCmd.status,
        HeaterCmd.power,
        HeaterCmd.status,
      ]);
      expect(writes[1][5], 1);
      expect(d.readings.firstWhere((r) => r.label == 'power').value, isTrue);
      expect(
        d.readings.firstWhere((r) => r.label == 'state').value,
        'Igniting',
      );
    });

    test('a target in level mode switches to the thermostat first', () async {
      final d = await const HeaterDriver().control(
        heater(),
        a,
        const DeviceCommand(HeaterSetting.target, 50),
      );
      expect(writes.map((w) => hex(w, sep: '')), [
        'aa550c220100002f',
        hex(heaterCommand(HeaterCmd.mode, HeaterMode.temperature), sep: ''),
        hex(heaterCommand(HeaterCmd.setValue, heaterMaxTemp), sep: ''),
        'aa550c220100002f',
      ]);
      expect(
        d.readings.firstWhere((r) => r.label == 'target').display,
        '36 °C',
      );
    });

    test('a level in level mode goes straight out', () async {
      await const HeaterDriver().control(
        heater(),
        a,
        const DeviceCommand(HeaterSetting.level, 4),
      );
      expect(writes.map((w) => w[4]), [
        HeaterCmd.status,
        HeaterCmd.setValue,
        HeaterCmd.status,
      ]);
      expect(writes[1][5], 4);
    });
  });
}
