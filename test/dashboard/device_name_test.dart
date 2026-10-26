import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/decoders/registry.dart';

import '../helpers.dart';

void main() {
  // pvvx custom: MAC A4:C1:38:DF:07:81 reversed, 21.00 °C, 45.00 %, 3000 mV,
  // 88 %, counter, flags.
  const pvvx = '81 07 df 38 c1 a4 34 08 94 11 b8 0b 58 01 00';

  test('identical sensors are told apart by the end of the MAC', () {
    final t = DeviceTracker(DecoderRegistry.standard());
    final a = adv(
      id: 'A4:C1:38:DF:07:81',
      mac: 'A4:C1:38:DF:07:81',
      serviceData: {0x181A: pvvx},
    );
    t.onAdvertisement(a);
    expect(deviceName(t[a.id]!), 'Climate · 0781');
  });

  test('on iOS the MAC comes from the broadcast, not the private id', () {
    final t = DeviceTracker(DecoderRegistry.standard());
    final a = adv(
      id: '782D9C35-0000-4000-8000-BBAD176223BE',
      mac: null,
      serviceData: {0x181A: pvvx},
    );
    t.onAdvertisement(a);
    expect(deviceName(t[a.id]!), 'Climate · 0781');
  });

  test('a serial in the name is the same on every screen', () {
    final t = DeviceTracker(DecoderRegistry.standard());
    final a = adv(
      id: '0B2D1E77-0000-4000-8000-000000000002',
      mac: null,
      name: 'DL-694201312BA',
    );
    t.onAdvertisement(a);
    expect(deviceName(t[a.id]!), endsWith(' · 12BA'));
  });
}
