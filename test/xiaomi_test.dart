import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/registry.dart';

import 'helpers.dart';

void main() {
  final reg = DecoderRegistry.standard();
  Map<String, Object?> values(Decoded out) => {
    for (final r in out.readings) r.label: r.value,
  };

  test('stock MiBeacon tells the user to flash pvvx', () {
    final out = reg.decode(
      adv(serviceData: {0xFE95: '58 58 5b 05 01 b2 18 8d 38 c1 a4 28'}),
    )!;
    expect(out.model, 'Xiaomi LYWSD03MMC (stock firmware)');
    expect(out.needs, contains('pvvx'));
  });

  test('pvvx custom format', () {
    // MAC b2188d38c1a4 reversed, 25.06 C, 50.55 %, 2.993 V, 88 %, counter 7, flags 4
    final out = reg.decode(
      adv(
        serviceData: {0x181A: 'b2 18 8d 38 c1 a4 ca 09 bf 13 b1 0b 58 07 04'},
      ),
    )!;
    expect(out.protocol, 'pvvx custom');
    expect(values(out), {
      'temperature': 25.06,
      'humidity': 50.55,
      'battery': 88,
      'battery voltage': 2.993,
    });
    expect(out.info['mac'], 'A4:C1:38:8D:18:B2');
  });

  test('ATC1441 format', () {
    final out = reg.decode(
      adv(serviceData: {0x181A: 'a4 c1 38 8d 18 b2 00 fa 33 58 0b b1 07'}),
    )!;
    expect(out.protocol, 'ATC1441');
    expect(values(out), {
      'temperature': 25.0,
      'humidity': 51,
      'battery': 88,
      'battery voltage': 2.993,
    });
  });

  test('unknown packets decode to null', () {
    expect(reg.decode(adv(manufacturerData: {0x004C: '02 15 00'})), isNull);
  });
}
