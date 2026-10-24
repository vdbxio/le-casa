import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';

import 'helpers.dart';

void main() {
  final reg = DecoderRegistry.standard();

  test('Improv service data is recognised and parked in its own group', () {
    // state 0x02 authorized, capabilities 0x01 identify (spec 2.x layout)
    final out = reg.decode(
      adv(
        name: 'esphome-web-1a2b3c',
        serviceData: {0x4677: '02 01 00 00 00 00'},
      ),
    )!;
    expect(out.kind, DeviceKind.improv);
    expect(out.protocol, 'Improv BLE');
    expect(out.model, 'esphome-web-1a2b3c');
    expect(out.readings.single.display, 'Authorized');
    expect(out.info['can identify'], 'yes');
  });

  test('Improv 1.0 devices only advertise the service UUID', () {
    final out = reg.decode(
      RawAdvertisement(
        id: 'x',
        rssi: -70,
        seenAt: DateTime.utc(2026),
        longServiceUuids: const ['00467768-6228-2272-4663-277478268000'],
      ),
    )!;
    expect(out.kind, DeviceKind.improv);
    expect(out.readings, isEmpty);
  });
}
