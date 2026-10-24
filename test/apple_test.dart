import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';

import 'helpers.dart';

void main() {
  final reg = DecoderRegistry.standard();

  test('AirPlay target advert is parked under background with its IP', () {
    final out = reg.decode(
      adv(
        id: 'rotating-1',
        mac: null,
        manufacturerData: {0x004C: '09 06 03 2b 0a 00 00 ee'},
      ),
    )!;
    expect(out.kind, DeviceKind.background);
    expect(out.protocol, 'Apple Continuity');
    expect(out.model, 'AirPlay target');
    expect(out.info['IPv4'], '10.0.0.238');
  });

  test('short Find My beacon is recognised', () {
    final out = reg.decode(
      adv(
        id: 'rotating-2',
        mac: null,
        manufacturerData: {0x004C: '12 02 00 00'},
      ),
    )!;
    expect(out.kind, DeviceKind.background);
    expect(out.readings.single.display, 'Find My');
  });

  test('iBeacon exposes uuid, major and minor', () {
    final out = reg.decode(
      adv(
        id: 'rotating-3',
        mac: null,
        manufacturerData: {
          0x004C: '02 15 e2c56db5dffb48d2b060d0f5a71096e0 00 01 00 02 c5',
        },
      ),
    )!;
    expect(out.info['beacon uuid'], 'e2c56db5-dffb-48d2-b060-d0f5a71096e0');
    expect(out.info['major'], '1');
    expect(out.info['minor'], '2');
  });

  test('a Victron product advert without Instant Readout needs setup', () {
    final out = reg.decode(
      adv(name: 'Gary Bussy', manufacturerData: {0x02E1: '10 00 03 c0'}),
    )!;
    expect(out.protocol, 'Victron');
    expect(out.kind, DeviceKind.needsSetup);
    expect(out.model, 'Generic Venus Device');
    expect(out.needs, contains('Instant Readout is off'));
  });

  test('a Daly BMS module is filed under Battery as needing a connection', () {
    final out = reg.decode(
      adv(
        name: 'DL-694201312BA',
        manufacturerData: {0x0402: '27 d2 19 08 01 c5 61 4a 48 42'},
      ),
    )!;
    expect(out.protocol, 'Daly BMS');
    expect(out.kind, DeviceKind.battery);
    expect(out.needs, contains('connection'));
    expect(out.info['module'], 'DL-694201312BA');
  });

  test('Hcalory heater and Alpicool fridge get appliance cards', () {
    final heater = reg.decode(
      RawAdvertisement(
        id: 'h',
        name: 'BYD-DC32622B4821',
        rssi: -60,
        seenAt: DateTime.utc(2026),
        serviceUuids: const [0xFFE0],
      ),
    )!;
    expect(heater.protocol, 'Hcalory');
    expect(heater.kind, DeviceKind.appliance);

    final fridge = reg.decode(adv(name: 'AK1-1234'))!;
    expect(fridge.protocol, 'Alpicool');
    expect(fridge.kind, DeviceKind.appliance);
    expect(reg.decode(adv(name: 'Avocado')), isNull);
  });
}
