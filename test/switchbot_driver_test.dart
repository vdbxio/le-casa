import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/drivers/switchbot_driver.dart';

import 'fake_session.dart';
import 'helpers.dart';

void main() {
  // Chloe's Plug Mini (US), broadcasting "off".
  final plug = adv(
    serviceData: {0xFD3D: '6700'},
    manufacturerData: {0x0969: 'AABBCCDDEEFF0000003C0000'},
  );

  FakeSession session(List<Uint8List> writes) => FakeSession(
    characteristics: const [
      GattChar(switchBotWrite, canWrite: true, canWriteWithoutResponse: true),
      GattChar(switchBotNotify, canNotify: true),
    ],
    onWrite: (c, data) {
      writes.add(data);
      // As the plug answered on the Mac: 01 then its new state.
      return [
        Uint8List.fromList([0x01, data[5]]),
      ];
    },
  );

  test('matches the US and JP Plug Minis only', () {
    const d = SwitchBotPlugDriver();
    expect(d.matches(plug), isTrue);
    expect(d.matches(adv(serviceData: {0xFD3D: '6a00'})), isTrue);
    // Plug Mini (EU) encrypts its commands.
    expect(d.matches(adv(serviceData: {0xFD3D: '3f00'})), isFalse);
    expect(d.matches(adv(serviceData: {0xFD3D: '7740e4'})), isFalse);
    expect(
      GattDriverRegistry.standard().forAdvertisement(plug),
      isA<SwitchBotPlugDriver>(),
    );
  });

  test(
    'switches on and off with the frames the plug answered on the Mac',
    () async {
      final writes = <Uint8List>[];
      final s = session(writes);
      const d = SwitchBotPlugDriver();
      var out = await d.control(s, plug, const DeviceCommand('on', true));
      expect(hex(writes.last, sep: ''), '570f50010180');
      expect(out.readings.firstWhere((r) => r.label == 'on').value, isTrue);
      expect(out.readings.firstWhere((r) => r.label == 'power').value, 0.0);
      out = await d.control(s, plug, const DeviceCommand('on', false));
      expect(hex(writes.last, sep: ''), '570f50010100');
      expect(out.readings.firstWhere((r) => r.label == 'on').value, isFalse);
    },
  );

  test('a refusal is an error', () async {
    final s = FakeSession(
      characteristics: const [
        GattChar(switchBotWrite, canWrite: true),
        GattChar(switchBotNotify, canNotify: true),
      ],
      onWrite: (c, data) => [
        Uint8List.fromList([0x05, 0x00]),
      ],
    );
    expect(
      const SwitchBotPlugDriver().control(
        s,
        plug,
        const DeviceCommand('on', true),
      ),
      throwsStateError,
    );
  });

  test(
    'a plug that answers with the old state gets the command again',
    () async {
      var tries = 0;
      final s = FakeSession(
        characteristics: const [
          GattChar(switchBotWrite, canWrite: true),
          GattChar(switchBotNotify, canNotify: true),
        ],
        onWrite: (c, data) => [
          Uint8List.fromList([0x01, ++tries == 1 ? 0x80 : 0x00]),
        ],
      );
      final out = await const SwitchBotPlugDriver().control(
        s,
        plug,
        const DeviceCommand('on', false),
      );
      expect(tries, 2);
      expect(out.readings.firstWhere((r) => r.label == 'on').value, isFalse);
    },
  );
}
