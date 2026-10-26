import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/keys/key_store.dart';
import 'package:lecasa/sync/ble_radio.dart';
import 'package:lecasa/sync/radio.dart';
import 'package:lecasa/sync/wire.dart';

void main() {
  test('a reading survives the trip', () {
    final r = SharedReading(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'AK1-AAFE13156431',
      mac: 'AA:BB:CC:DD:EE:FF',
      ownerId: 'ipad',
      ownerName: 'Kitchen iPad',
      at: DateTime.now().subtract(const Duration(seconds: 5)),
      every: const Duration(seconds: 30),
      controllable: true,
      decoded: const Decoded(
        protocol: 'Alpicool',
        model: 'Fridge',
        kind: DeviceKind.appliance,
        readings: [
          Reading('temperature', 3.5, '°C'),
          Reading('target', 48, '°F'),
          Reading('eco', false),
          Reading('fault', null),
        ],
        info: {'settable range': '-4 to 68 °F'},
      ),
    );
    final back = SharedReading.fromJson(r.toJson());
    expect(back.slot, 'ipad|AA:BB:CC:DD:EE:FF');
    expect(back.controllable, isTrue);
    expect(back.every, const Duration(seconds: 30));
    expect(back.at.difference(r.at).inSeconds.abs(), lessThan(2));
    expect(back.decoded.kind, DeviceKind.appliance);
    expect(back.decoded.readings.map((r) => r.display), [
      '3.5 °C',
      '48 °F',
      'off',
      'n/a',
    ]);
    expect(back.decoded.info['settable range'], '-4 to 68 °F');
    expect(back.freshAt(DateTime.now()), isTrue);
    expect(
      back.freshAt(DateTime.now().add(const Duration(minutes: 3))),
      isFalse,
    );
  });

  test('hub adverts from Android and iOS give their home tag', () {
    RawAdvertisement adv({String? name, Map<int, Uint8List> mfr = const {}}) =>
        RawAdvertisement(
          id: 'x',
          rssi: -40,
          seenAt: DateTime.now(),
          name: name,
          manufacturerData: mfr,
          longServiceUuids: const [syncServiceUuid],
        );
    expect(
      BleSyncRadio.sightingOf(
        adv(
          mfr: {
            syncCompanyId: Uint8List.fromList([0x1a, 0x2b, 0x3c, 0x4d]),
          },
        ),
      )?.tag,
      '1a2b3c4d',
    );
    expect(
      BleSyncRadio.sightingOf(adv(name: 'LeCasa 1A2B3C4D'))?.tag,
      '1a2b3c4d',
    );
    expect(BleSyncRadio.sightingOf(adv())?.tag, isNull);
    expect(
      BleSyncRadio.sightingOf(
        RawAdvertisement(id: 'y', rssi: -40, seenAt: DateTime.now()),
      ),
      isNull,
    );
  });

  test('keys merge by time, removals included', () async {
    final k = KeyStore();
    const id = 'dev';
    await k.apply(
      const KeyRecord(
        SecretKind.key,
        id,
        value: '00112233445566778899aabbccddeeff',
        at: 100,
      ),
    );
    expect(k.has(id), isTrue);
    // Older news loses.
    expect(await k.apply(const KeyRecord(SecretKind.key, id, at: 50)), isFalse);
    expect(k.has(id), isTrue);
    // A newer removal wins and is remembered.
    expect(await k.apply(const KeyRecord(SecretKind.key, id, at: 200)), isTrue);
    expect(k.has(id), isFalse);
    expect(
      await k.apply(
        const KeyRecord(
          SecretKind.key,
          id,
          value: '00112233445566778899aabbccddeeff',
          at: 150,
        ),
      ),
      isFalse,
    );
    // Bad keys are refused.
    expect(
      await k.apply(
        const KeyRecord(SecretKind.key, 'other', value: 'abcd', at: 300),
      ),
      isFalse,
    );
    // PINs too.
    await k.setSecret('bms', '1234');
    expect(k.recordFor(SecretKind.pin, 'bms')?.value, '1234');
  });
}
