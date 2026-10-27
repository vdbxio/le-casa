import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/connection_manager.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/drivers/ideal_led.dart';

import 'fake_session.dart';
import 'helpers.dart';

void main() {
  // Chloe's controller as the Mac heard it.
  final strip = adv(
    id: 'led',
    name: 'ISP-820ED3',
    manufacturerData: {0x5254: '0000'},
  );

  String enc(Uint8List p) => hex(idealLedEncrypt(p), sep: '');

  test('commands encrypt to the blocks the vendor app sends', () {
    // Ciphertexts published by glowmote and idealLED.
    expect(enc(idealLedPower(false)), '79d1dba40919c246a8580ae7d11b7884');
    expect(enc(idealLedPower(true)), '84dd5042374150897ac82f39110968a8');
    expect(
      enc(idealLedColour(0xFF0000, 100)),
      '73baa3e311ef375b0c2965911e7f5357',
    );
    expect(
      enc(idealLedColour(0x00FF00, 100)),
      'a06566adefd31c59d5c85979620ce9ef',
    );
    expect(
      enc(idealLedColour(0x0000FF, 100)),
      'c7f95a08c3583941208cca2d3e6e91c0',
    );
  });

  test('effects and scenes encrypt to the blocks the vendor app sent', () {
    // Captured by glowmote from the vendor app, 2026-10-24.
    expect(
      enc(idealLedEffect(1, 0x00FF00, 0x0000FF, brightness: 50)),
      'abc14c153ede82e54b7e050132c329d8',
    );
    for (final (effect, speed, cipher) in [
      (0, 0x50, '78a285cda85bf710f8bcbb1eae183bd8'),
      (1, 0x09, '7a0e16c5439b21ad54cf9a2e6745f1aa'),
      (8, 0x50, '173a9afca7ae6d41a8c794c4fdbb5c08'),
      (9, 0x50, '6912a67bf156ae6fbc63c7b36e5bfbcd'),
    ]) {
      expect(
        enc(idealLedScene(effect, 7, speed: speed, brightness: 50)),
        cipher,
        reason: 'scene $effect',
      );
    }
    final f = idealLedSceneFrame(idealRainbow, 50);
    expect(f, hasLength(98));
    expect(
      hex(f.sublist(0, 23), sep: ''),
      '16007f00007f51007f7f00007f0000007f7f007f7f7f7f',
    );
    expect(f.sublist(23).every((b) => b == 0), isTrue);
  });

  test('never builds an effect or scene the firmware cannot index', () {
    expect(() => idealLedEffect(10, 0, 0), throwsRangeError);
    expect(() => idealLedScene(12, 7), throwsRangeError);
    expect(() => idealLedScene(0, 8), throwsRangeError);
    expect(() => idealLedScene(0, 0), throwsRangeError);
    for (final p in idealPatterns) {
      expect((p.scene ?? 0) < idealSceneCount, isTrue);
      expect((p.effect ?? 0) < idealEffectCount, isTrue);
      expect(p.colours.length, inInclusiveRange(1, idealSceneMaxColours));
    }
  });

  test('brightness scales the colour and keeps a lit channel lit', () {
    final p = idealLedColour(0xFF0102, 10);
    expect(p.sublist(9, 12), [25, 2, 2]);
    expect(idealLedDecrypt(idealLedEncrypt(p)), p);
  });

  test('is found by name or maker id', () {
    expect(const IdealLedDecoder().matches(strip), isTrue);
    expect(const IdealLedDecoder().matches(adv(name: 'IDL-1234')), isTrue);
    expect(const IdealLedDecoder().matches(adv(name: 'Govee_H5074')), isFalse);
    final d = DecoderRegistry.standard().decode(strip)!;
    expect(d.kind, DeviceKind.lights);
    expect(d.readings, isEmpty);
    expect(
      GattDriverRegistry.standard().forAdvertisement(strip),
      isA<IdealLedDriver>(),
    );
  });

  // As the firmware answers: the reply, then the next one in its table
  // (an SGLS ack also spells MULTOK).
  Uint8List reply(String text) {
    final r = Uint8List(16)
      ..[0] = text.length
      ..setRange(1, 1 + text.length, ascii.encode(text));
    if (text.length <= 6) {
      r
        ..[8] = 6
        ..setRange(9, 15, ascii.encode('MULTOK'));
    }
    return idealLedEncrypt(r);
  }

  FakeSession session(List<Uint8List> writes, {bool ack = true}) => FakeSession(
    characteristics: const [
      GattChar(idealLedWrite, canWriteWithoutResponse: true),
      GattChar(idealLedNotify, canNotify: true),
      GattChar(idealLedBulk, canWriteWithoutResponse: true),
    ],
    onWrite: (c, data) {
      if (c.uuid == normalizeUuid(idealLedBulk)) {
        writes.add(data);
        return ack ? [reply('MULTCPOK')] : const [];
      }
      writes.add(idealLedDecrypt(data));
      if (!ack) return const [];
      final tag = ascii.decode(idealLedDecrypt(data).sublist(1, 5));
      return [reply('${tag}OK')];
    },
  );

  test('a colour turns the strip on first and reports the look', () async {
    final writes = <Uint8List>[];
    final s = session(writes);
    const d = IdealLedDriver();
    final out = await d.control(
      s,
      strip,
      const DeviceCommand('colour', {'rgb': 0x0000FF, 'brightness': 50}),
    );
    expect(writes.map((w) => ascii.decode(w.sublist(1, 5))), ['TURN', 'SGLS']);
    expect(writes[0][5], 1);
    expect(writes[1].sublist(9, 12), [0, 0, 127]);
    final r = {for (final x in out.readings) x.label: x.value};
    expect(r, {
      'on': true,
      'pattern': 'Solid colour',
      'colour': '#0000FF',
      'brightness': 50,
    });
    expect(idealLedRgb(r['colour']), 0x0000FF);
    // The broadcast only names it.
    expect(const IdealLedDecoder().decode(strip)!.readings, isEmpty);
  });

  test('a rainbow scene sends its header, then its colours in clear', () async {
    final writes = <Uint8List>[];
    final out = await const IdealLedDriver().control(
      session(writes),
      strip,
      const DeviceCommand('pattern', {
        'pattern': 'Rainbow flow',
        'speed': 80,
        'brightness': 50,
      }),
    );
    expect(writes, hasLength(3));
    expect(ascii.decode(writes[0].sublist(1, 5)), 'TURN');
    // 0a 'MULT' effect 9, forward, 100, speed 80, 7 colours, 50 %.
    expect(
      hex(writes[1].sublist(0, 11), sep: ''),
      '0a${hex(ascii.encode('MULT'), sep: '')}090064500732',
    );
    expect(writes[2], idealLedSceneFrame(idealRainbow, 50));
    final r = {for (final x in out.readings) x.label: x.value};
    expect(r['pattern'], 'Rainbow flow');
    expect(r['speed'], 80);
    expect(r['brightness'], 50);
  });

  test('an effect uses the picked colour over black', () async {
    final writes = <Uint8List>[];
    await const IdealLedDriver().control(
      session(writes),
      strip,
      const DeviceCommand('pattern', {
        'pattern': 'Chase',
        'rgb': 0xFF0000,
        'speed': 30,
      }),
    );
    expect(
      hex(writes.last, sep: ''),
      // mode 5, forward, 100, speed 30, red over black.
      '0f${hex(ascii.encode('SGLS'), sep: '')}0500641eff000000000032',
    );
  });

  test('an unknown pattern is refused before anything is sent', () async {
    final writes = <Uint8List>[];
    await expectLater(
      const IdealLedDriver().control(
        session(writes),
        strip,
        const DeviceCommand('pattern', {'pattern': 'Made up'}),
      ),
      throwsArgumentError,
    );
    expect(writes, isEmpty);
  });

  test('no ack after two tries is an error', () async {
    final writes = <Uint8List>[];
    await expectLater(
      const IdealLedDriver().control(
        session(writes, ack: false),
        strip,
        const DeviceCommand('on', true),
      ),
      throwsA(anything),
    );
    expect(writes, hasLength(2));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('the last command, from any screen, is what the light shows', () {
    final t = DeviceTracker(DecoderRegistry.standard());
    t.onAdvertisement(strip);
    expect(t['led']!.view!.readings, isEmpty);
    t.setPolled(
      'led',
      Decoded(
        protocol: 'iDeal LED',
        kind: DeviceKind.lights,
        model: 'iDeal LED controller',
        readings: const [Reading('on', true)],
      ),
    );
    expect(t['led']!.view!.readings.single.value, isTrue);
  });

  test('switching off from any screen keeps the look on the card', () async {
    final t = DeviceTracker(DecoderRegistry.standard());
    final m = ConnectionManager(
      t,
      drivers: GattDriverRegistry.standard(),
      tick: const Duration(hours: 1),
      open: (id) async => session([]),
    );
    final x = adv(id: 'third', name: 'ISP-000003', seenAt: DateTime.now());
    t.onAdvertisement(x);
    m.onAdvertisement(x);
    // Blue at 33 %, set from another screen.
    t.setPolled(
      'third',
      const Decoded(
        protocol: 'iDeal LED',
        kind: DeviceKind.lights,
        model: 'iDeal LED controller',
        readings: [
          Reading('on', true),
          Reading('colour', '#0000FF'),
          Reading('brightness', 33, '%'),
        ],
      ),
    );
    await m.control('third', const DeviceCommand('on', false));
    final r = {for (final y in t['third']!.view!.readings) y.label: y.value};
    expect(r, {'on': false, 'colour': '#0000FF', 'brightness': 33});
    m.dispose();
  });
}
