import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/victron.dart';

import 'helpers.dart';

// Vectors from victron-ble tests (MIT).
void main() {
  Map<String, Object?> values(Decoded out) => {
    for (final r in out.readings) r.label: r.value,
  };

  const mppt = '10 02 42 a0 01 62 07 ad ce b3 7b 60 5d 7e 0e e2 1b 24 df 5c';
  const mpptKey = 'adeccb947395801a4dd45a2eaa44bf17';
  const shunt =
      '10 02 89 a3 02 b0 40 af 92 5d 09 a4 d8 9a a0 12 8b de f4 8c 62 98 a9';
  const shuntKey = 'aff4d0995b7d1e176c0c33ecb9e70dcd';

  test('header parses model and record type without a key', () {
    final out = const VictronDecoder().decode(
      adv(manufacturerData: {0x02E1: mppt}),
    )!;
    expect(out.protocol, 'Victron');
    expect(out.model, 'BlueSolar Charger MPPT 75/15');
    expect(out.info['record type'], 'Solar charger');
    expect(out.isReadable, isFalse);
    expect(out.needs, contains('VictronConnect'));
  });

  test('solar charger end to end', () {
    final dec = VictronDecoder(keyFor: keyFor('mppt', mpptKey));
    final out = dec.decode(adv(id: 'mppt', manufacturerData: {0x02E1: mppt}))!;
    expect(out.isReadable, isTrue);
    expect(values(out), {
      'charge state': 'Absorption',
      'charger error': 'none',
      'battery voltage': 13.88,
      'battery current': 1.4,
      'yield today': 30,
      'solar power': 19,
      'load current': 0.0,
    });
  });

  test('solar charger MPPT 100 decrypted record', () {
    final r = VictronDecoder.parseSolarCharger(
      fromHex('0300fb09650032000901ffff31bc45ad'),
    );
    final v = {for (final x in r) x.label: x.value};
    expect(v['charge state'], 'Bulk');
    expect(v['battery voltage'], 25.55);
    expect(v['battery current'], 10.1);
    expect(v['solar power'], 265);
    expect(v['yield today'], 500);
    expect(v['load current'], isNull);
  });

  test('SmartShunt end to end', () {
    final dec = VictronDecoder(keyFor: keyFor('shunt', shuntKey));
    final out = dec.decode(
      adv(id: 'shunt', manufacturerData: {0x02E1: shunt}),
    )!;
    expect(out.model, 'SmartShunt 500A/50mV');
    expect(values(out), {
      'state of charge': 50.0,
      'voltage': 12.53,
      'current': 0.0,
      'consumed': -50.0,
      'time to go': null,
      'alarm': 'No alarm',
    });
  });

  test('battery monitor aux modes', () {
    Map<String, Object?> v(String h) => {
      for (final x in VictronDecoder.parseBatteryMonitor(fromHex(h)))
        x.label: x.value,
    };
    expect(v('ffffe6040000feff010000000080fe0c')['midpoint voltage'], 655.34);
    expect(v('ffffe6040000feff000000000080feac')['starter voltage'], -0.02);
    // 0xFFFF aux in temperature mode means "no sensor" rather than 382 C.
    expect(v('ffffe6040000ffff020000000080fede')['temperature'], isNull);
    // 0x7333 = 294.91 K = 21.76 C
    expect(v('ffffe60400003373020000000080fede')['temperature'], 21.76);
  });

  test('wrong key is detected from the key check byte', () {
    final dec = VictronDecoder(
      keyFor: keyFor('shunt', 'ffffffffffffffffffffffffffffffff'),
    );
    final out = dec.decode(
      adv(
        id: 'shunt',
        manufacturerData: {
          0x02E1: '10 02 89 a3 02 bb 01 af 12 90 87 60 0b 9b 97 bc 2c 32 86 7c 82 38 da',
        },
      ),
    )!;
    expect(out.isReadable, isFalse);
    expect(out.needs, contains('does not match'));
  });

  test('non-product Victron manufacturer data is ignored', () {
    expect(
      const VictronDecoder().matches(
        adv(manufacturerData: {0x02E1: '00 01 02'}),
      ),
      isFalse,
    );
  });
}
