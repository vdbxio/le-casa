import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/bthome.dart';
import 'package:lecasa/decoders/decoded.dart';

import 'helpers.dart';

// Vectors from bthome-ble tests/test_parser_v2.py (MIT).
void main() {
  const d = BtHomeDecoder();

  Map<String, Object?> values(Decoded out) => {
    for (final r in out.readings) r.label: r.value,
  };

  test('temperature + humidity (Xiaomi pvvx style)', () {
    final out = d.decode(
      adv(name: 'ATC_8D18B2', serviceData: {0xFCD2: '40 02 ca 09 03 bf 13'}),
    )!;
    expect(out.protocol, 'BTHome');
    expect(out.model, 'Xiaomi LYWSD03MMC (pvvx)');
    expect(values(out), {'temperature': 25.06, 'humidity': 50.55});
    expect(out.isReadable, isTrue);
  });

  test('voltage', () {
    final out = d.decode(adv(serviceData: {0xFCD2: '40 0c 02 0c'}))!;
    expect(values(out), {'voltage': 3.074});
  });

  test('button long press', () {
    final out = d.decode(
      adv(name: 'SBBT-002C', serviceData: {0xFCD2: '40 3a 04'}),
    )!;
    expect(out.events.single.toString(), 'button 1 long_press');
    expect(out.model, 'BTHome button device');
  });

  test('packet id, battery and button press (Shelly BLU Button style)', () {
    final out = d.decode(adv(serviceData: {0xFCD2: '40 00 52 01 64 3a 01'}))!;
    expect(out.info['packet id'], '82');
    expect(values(out), {'battery': 100});
    expect(out.events.single.toString(), 'button 1 press');
  });

  test("Le'Fob style: four buttons, only one pressed", () {
    final out = d.decode(
      adv(
        name: "Le'Fob",
        serviceData: {0xFCD2: '44 00 07 01 5a 3a 00 3a 00 3a 01 3a 00'},
      ),
    )!;
    expect(out.model, "Le'Fob");
    expect(out.info['mode'], 'trigger based');
    expect(out.events.single.toString(), 'button 3 press');
    expect(values(out), {'battery': 90});
  });

  test('duplicate labels get numbered', () {
    final out = d.decode(adv(serviceData: {0xFCD2: '40 02 ca 09 02 00 00'}))!;
    expect(values(out).keys, ['temperature', 'temperature 2']);
  });

  test('encrypted without key reports what it needs', () {
    final out = d.decode(
      adv(
        id: '54:48:E6:8F:80:A5',
        mac: '54:48:E6:8F:80:A5',
        serviceData: {0xFCD2: '41 a4 72 66 c9 5f 73 00 11 22 33 78 23 72 14'},
      ),
    )!;
    expect(out.isReadable, isFalse);
    expect(out.needs, contains('encryption key'));
  });

  test('encrypted with correct key', () {
    final dec = BtHomeDecoder(
      keyFor: keyFor('54:48:E6:8F:80:A5', '231d39c1d7cc1ab1aee224cd096db932'),
    );
    final out = dec.decode(
      adv(
        id: '54:48:E6:8F:80:A5',
        mac: '54:48:E6:8F:80:A5',
        serviceData: {0xFCD2: '41 a4 72 66 c9 5f 73 00 11 22 33 78 23 72 14'},
      ),
    )!;
    expect(out.protocol, 'BTHome (encrypted)');
    expect(values(out), {'temperature': 25.06, 'humidity': 50.55});
    expect(out.info['counter'], '${0x33221100}');
  });

  test('encrypted with wrong key fails cleanly', () {
    final dec = BtHomeDecoder(
      keyFor: keyFor('54:48:E6:8F:80:A5', '00000000000000000000000000000000'),
    );
    final out = dec.decode(
      adv(
        id: '54:48:E6:8F:80:A5',
        mac: '54:48:E6:8F:80:A5',
        serviceData: {0xFCD2: '41 a4 72 66 c9 5f 73 00 11 22 33 78 23 72 14'},
      ),
    )!;
    expect(out.isReadable, isFalse);
    expect(out.needs, contains('wrong key'));
  });

  test('encrypted with MAC in payload works even when the radio hides the MAC', () {
    final dec = BtHomeDecoder(
      keyFor: keyFor('ios-uuid', '231d39c1d7cc1ab1aee224cd096db932'),
    );
    final out = dec.decode(
      adv(
        id: 'ios-uuid',
        mac: null,
        serviceData: {
          0xFCD2:
              '43 a5 80 8f e6 48 54 f1 96 c0 6f fb 49 00 11 22 33 f0 8e cb de',
        },
      ),
    )!;
    expect(values(out), {'temperature': 25.06, 'humidity': 50.55});
    expect(out.info['mac'], '54:48:E6:8F:80:A5');
  });

  test('encrypted without MAC on iOS explains the limit', () {
    final dec = BtHomeDecoder(
      keyFor: keyFor('ios-uuid', '231d39c1d7cc1ab1aee224cd096db932'),
    );
    final out = dec.decode(
      adv(
        id: 'ios-uuid',
        mac: null,
        serviceData: {0xFCD2: '41 a4 72 66 c9 5f 73 00 11 22 33 78 23 72 14'},
      ),
    )!;
    expect(out.needs, contains('MAC'));
  });

  test('unknown object id stops parsing but keeps what came before', () {
    final out = d.decode(adv(serviceData: {0xFCD2: '40 01 5a ee 01 02'}))!;
    expect(values(out), {'battery': 90});
    expect(out.info['unknown object'], startsWith('0xee'));
  });
}
