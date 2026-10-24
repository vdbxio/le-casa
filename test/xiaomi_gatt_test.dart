import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/drivers/xiaomi_driver.dart';

import 'fake_session.dart';
import 'helpers.dart';

void main() {
  // 23.45 °C, 50 %, 2.950 V
  final live = fromHex('29 09 32 86 0b');

  test('parses the 5-byte live value', () {
    final r = parseXiaomiLive(live)!;
    expect(r.temperature, 23.45);
    expect(r.humidity, 50);
    expect(r.batteryVoltage, 2.95);
    expect(r.estimatedBattery, 85);
  });

  test('negative temperatures', () {
    final r = parseXiaomiLive(fromHex('c4 fd 3c 00 0c'))!;
    expect(r.temperature, -5.72);
    expect(r.humidity, 60);
    expect(r.batteryVoltage, 3.072);
    expect(r.estimatedBattery, 97);
  });

  test('too short is null', () {
    expect(parseXiaomiLive(fromHex('29 09 32')), isNull);
  });

  test('decoded is a Climate device with no setup needed', () {
    final d = xiaomiLiveToDecoded(parseXiaomiLive(live)!, batteryPercent: 91);
    expect(d.kind, DeviceKind.climate);
    expect(d.needs, isNull);
    final byLabel = {for (final r in d.readings) r.label: r};
    expect(byLabel['temperature']!.display, '23.45 °C');
    expect(byLabel['humidity']!.display, '50 %');
    expect(byLabel['battery']!.display, '91 %');
    expect(byLabel['battery voltage']!.display, '2.95 V');
  });

  group('driver', () {
    final stockAdv = adv(
      name: 'LYWSD03MMC',
      // Encrypted MiBeacon frame for product 0x055B.
      serviceData: {
        0xFE95: '58 58 5b 05 01 b2 18 8d 38 c1 a4 28 01 00 00 00 00 00 11',
      },
    );

    test('the registry picks it for a stock LYWSD03MMC', () {
      final d = GattDriverRegistry.standard().forAdvertisement(stockAdv);
      expect(d, isA<XiaomiStockGattDriver>());
    });

    test('not for a Daly module or a pvvx sensor', () {
      final reg = GattDriverRegistry.standard();
      expect(
        reg.forAdvertisement(adv(serviceData: {0x181A: '00' * 15})),
        isNull,
      );
    });

    test('subscribes, takes the first value and reads the battery', () async {
      final session = FakeSession(
        characteristics: const [
          GattChar(xiaomiDataUuid, canNotify: true),
          GattChar(xiaomiBatteryUuid, canRead: true),
        ],
        readValues: {xiaomiBatteryUuid: fromHex('5b')},
        onSubscribe: {
          xiaomiDataUuid: [live],
        },
      );
      final d = await const XiaomiStockGattDriver().read(session, stockAdv);
      final byLabel = {for (final r in d.readings) r.label: r};
      expect(byLabel['temperature']!.display, '23.45 °C');
      expect(byLabel['battery']!.display, '91 %');
    });

    test('falls back to the voltage estimate without a battery char', () async {
      final session = FakeSession(
        characteristics: const [GattChar(xiaomiDataUuid, canNotify: true)],
        onSubscribe: {
          xiaomiDataUuid: [live],
        },
      );
      final d = await const XiaomiStockGattDriver().read(session, stockAdv);
      final byLabel = {for (final r in d.readings) r.label: r};
      expect(byLabel['battery']!.display, '85 %');
    });

    test('a device without the data characteristic is unsupported', () {
      final session = FakeSession(characteristics: const []);
      expect(
        () => const XiaomiStockGattDriver().read(session, stockAdv),
        throwsA(isA<UnsupportedDeviceException>()),
      );
    });
  });
}
