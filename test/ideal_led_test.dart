import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  FakeSession session(List<Uint8List> writes, {bool ack = true}) => FakeSession(
    characteristics: const [
      GattChar(idealLedWrite, canWriteWithoutResponse: true),
      GattChar(idealLedNotify, canNotify: true),
    ],
    onWrite: (c, data) {
      writes.add(idealLedDecrypt(data));
      if (!ack) return const [];
      final tag = ascii.decode(idealLedDecrypt(data).sublist(1, 5));
      final reply = Uint8List(16)..setRange(1, 7, ascii.encode('${tag}OK'));
      return [idealLedEncrypt(reply)];
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
    expect(r, {'on': true, 'colour': '#0000FF', 'brightness': 50});
    expect(idealLedRgb(r['colour']), 0x0000FF);
    // The broadcast only names it.
    expect(const IdealLedDecoder().decode(strip)!.readings, isEmpty);
  });

  test('switching off and on keeps the look it was given', () async {
    final writes = <Uint8List>[];
    final s = session(writes);
    const d = IdealLedDriver();
    final x = adv(id: 'other', name: 'ISP-000001');
    var out = await d.control(s, x, const DeviceCommand('on', false));
    expect(out.readings.map((r) => r.label), ['on']);
    await d.control(
      s,
      x,
      const DeviceCommand('colour', {'rgb': 0xFF0000, 'brightness': 80}),
    );
    out = await d.control(s, x, const DeviceCommand('on', true));
    expect(writes.last[5], 1);
    final r = {for (final y in out.readings) y.label: y.value};
    expect(r, {'on': true, 'colour': '#FF0000', 'brightness': 80});
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
}
