import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/registry.dart';
import 'package:lecasa/decoders/xiaomi.dart';
import 'package:pointycastle/export.dart';

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
    expect(reg.decode(adv(manufacturerData: {0x0059: '02 15 00'})), isNull);
  });

  group('stock MiBeacon with a bindkey', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i * 17));
    // MAC A4:C1:38:8D:18:B2, reversed in the frame.
    final macRev = [0xb2, 0x18, 0x8d, 0x38, 0xc1, 0xa4];

    /// A v5 frame as stock LYWSD03MMC firmware sends it: frame control
    /// 0x5858 (encrypted, MAC and object included), product 0x055B.
    String frame(List<int> objects, int packet, {Uint8List? k}) {
      final header = [0x58, 0x58, 0x5b, 0x05, packet];
      final counter = [0x01, 0x02, 0x03];
      final nonce = Uint8List.fromList([
        ...macRev,
        0x5b,
        0x05,
        packet,
        ...counter,
      ]);
      final ccm = CCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(k ?? key),
            32,
            nonce,
            Uint8List.fromList([0x11]),
          ),
        );
      final sealed = ccm.process(Uint8List.fromList(objects));
      final body = sealed.sublist(0, sealed.length - 4);
      final mic = sealed.sublist(sealed.length - 4);
      return [
        ...header,
        ...macRev,
        ...body,
        ...counter,
        ...mic,
      ].map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    }

    test('decrypts and keeps the latest of each value', () {
      final reg = DecoderRegistry.standard(keyFor: (_) => key);
      reg.decode(
        adv(
          serviceData: {
            0xFE95: frame([0x04, 0x10, 0x02, 0xd2, 0x00], 1),
          },
        ),
      );
      reg.decode(
        adv(
          serviceData: {
            0xFE95: frame([0x06, 0x10, 0x02, 0xc2, 0x01], 2),
          },
        ),
      );
      final out = reg.decode(
        adv(
          serviceData: {
            0xFE95: frame([0x0a, 0x10, 0x01, 0x58], 3),
          },
        ),
      )!;
      expect(out.kind, DeviceKind.climate);
      expect(out.isReadable, isTrue);
      expect(values(out), {
        'temperature': 21.0,
        'humidity': 45.0,
        'battery': 88,
      });
      expect(
        out.info['mac'],
        'A4:C1:38:8D:18:B2',
        reason: 'iOS learns it here',
      );
    });

    test('a wrong key reads nothing', () {
      final reg = DecoderRegistry.standard(keyFor: (_) => key);
      final wrong = Uint8List.fromList(List.filled(16, 7));
      final out = reg.decode(
        adv(
          serviceData: {
            0xFE95: frame([0x04, 0x10, 0x02, 0xd2, 0x00], 1, k: wrong),
          },
        ),
      )!;
      expect(out.isReadable, isFalse);
      expect(out.needs, contains('bindkey'));
      expect(out.keyCheck, KeyCheck.wrong);
    });

    test('says whether the key works', () {
      final reg = DecoderRegistry.standard(keyFor: (_) => key);
      // A keep-alive without values says nothing about the key.
      final idle = reg.decode(
        adv(serviceData: {0xFE95: '18 58 5b 05 01 b2 18 8d 38 c1 a4'}),
      )!;
      expect(idle.keyCheck, KeyCheck.waiting);
      final out = reg.decode(
        adv(
          serviceData: {
            0xFE95: frame([0x04, 0x10, 0x02, 0xd2, 0x00], 2),
          },
        ),
      )!;
      expect(out.keyCheck, KeyCheck.works);
      expect(out.decryptedAt, isNotNull);
    });

    test('broadcast readings replace the connected ones', () {
      final tracker = DeviceTracker(
        DecoderRegistry.standard(keyFor: (_) => key),
      );
      final a = adv(serviceData: {0xFE95: '18 58 5b 05 01 b2 18 8d 38 c1 a4'});
      tracker.onAdvertisement(a);
      tracker.setPolled(
        a.id,
        const Decoded(protocol: 'Xiaomi (connected)', model: 'x'),
      );
      expect(tracker[a.id]!.view?.protocol, 'Xiaomi (connected)');
      tracker.onAdvertisement(
        adv(
          serviceData: {
            0xFE95: frame([0x04, 0x10, 0x02, 0xd2, 0x00], 2),
          },
        ),
      );
      expect(tracker[a.id]!.view?.protocol, 'Xiaomi MiBeacon');
      expect(tracker[a.id]!.readsBroadcasts, isTrue);
    });

    test('object parsing', () {
      expect(
        {
          for (final r in miBeaconReadings(
            Uint8List.fromList([0x0d, 0x10, 0x04, 0xfe, 0xff, 0xf4, 0x01]),
          ))
            r.label: r.value,
        },
        {'temperature': -0.2, 'humidity': 50.0},
      );
    });
  });
}
