import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  setUp(idealLedSet.clear);

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

  test('a colour on a dark strip turns it on first', () async {
    final writes = <Uint8List>[];
    final s = session(writes);
    const d = IdealLedDriver();
    await d.control(s, strip, const DeviceCommand('on', false));
    final out = await d.control(
      s,
      strip,
      const DeviceCommand('colour', 0x00FF00),
    );
    expect(writes.map((w) => ascii.decode(w.sublist(1, 5))), [
      'TURN',
      'TURN',
      'SGLS',
    ]);
    expect(writes[1][5], 1);
    final r = {for (final x in out.readings) x.label: x.value};
    expect(r['on'], isTrue);
    expect(r['colour'], '#00FF00');
    expect(r['brightness'], 100);
    // The next broadcast shows the same.
    expect(const IdealLedDecoder().decode(strip)!.readings.first.value, isTrue);
  });

  test('brightness keeps the colour', () async {
    final writes = <Uint8List>[];
    final s = session(writes);
    const d = IdealLedDriver();
    await d.control(s, strip, const DeviceCommand('colour', 0x0000FF));
    await d.control(s, strip, const DeviceCommand('brightness', 50));
    expect(writes.last.sublist(9, 12), [0, 0, 127]);
  });

  test('no ack after two tries is an error and changes nothing', () async {
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
    expect(idealLedSet, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 15)));
}
