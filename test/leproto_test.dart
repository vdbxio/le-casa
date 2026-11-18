// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Le'Proto against the vectors the firmware's host tests and its Python
// bench tool agree on (firmware/le-led/tests).

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/bthome.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/leproto/leled.dart';
import 'package:lecasa/leproto/leproto.dart';
import 'package:lecasa/leproto/sender.dart';

import 'helpers.dart';

String h(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  Map<String, Object?> values(Decoded out) => {
    for (final r in out.readings) r.label: r.value,
  };

  final key = fromHex('00112233445566778899aabbccddeeff');

  test('keys derive as the firmware derives them', () {
    final k = LepKeys(key);
    expect(h(k.down), '598fdc7555a68d2fa212ec83219361bb');
    expect(k.dstHex, '358341');
  });

  test('a command frame matches the firmware byte for byte', () {
    final f = lepSeal(LepKeys(key), 1, 42, LepOp.brightness, 200, 3);
    expect(h(f), '4c01358341012a0000a8c6baa8679123');
  });

  test('the iOS UUID is the frame reversed', () {
    final f = fromHex('4c01358341012a0000a8c6baa8679123');
    expect(lepUuid(f), '239167a8-bac6-a800-002a-01418335014c');
  });

  test('card commands map to opcodes', () {
    expect(lepCommandFor(const DeviceCommand('on', true), null), (1, 1, 0));
    expect(lepCommandFor(const DeviceCommand('on', false), null), (1, 0, 0));
    expect(lepCommandFor(const DeviceCommand('brightness', 100), null), (
      2,
      255,
      0,
    ));
    // 0 would switch WLED off.
    expect(lepCommandFor(const DeviceCommand('brightness', 0), null), (
      2,
      1,
      0,
    ));
    final c = rgbTo565(255, 0, 0);
    expect(lepCommandFor(const DeviceCommand('colour', '#ff0000'), null), (
      3,
      c & 0xFF,
      c >> 8,
    ));
    // No speed yet: a frozen effect is no use.
    expect(lepCommandFor(const DeviceCommand('effect', 9), null), (6, 9, 128));
    expect(
      () => lepCommandFor(const DeviceCommand('fan', 1), null),
      throwsArgumentError,
    );
  });

  test('sequence numbers climb, with the clock as a floor', () {
    final t = DateTime.utc(2026, 11, 2);
    expect(lepNextSeq(0, t), 86400);
    expect(lepNextSeq(86400, t), 86401);
    expect(lepNextSeq(90000, t), 90001);
  });

  test('the state advert decodes as a Le\'LED', () {
    LeLedKeys.clear();
    final dec = BtHomeDecoder(
      keyFor: keyFor('A0:B1:C2:D3:E4:F5', '00112233445566778899aabbccddeeff'),
    );
    final out = dec.decode(
      adv(
        id: 'A0:B1:C2:D3:E4:F5',
        mac: 'A0:B1:C2:D3:E4:F5',
        serviceData: {0xFCD2: '416483fc80612c1f0691b8e3ff4594e80300003cc6a4f0'},
      ),
    )!;
    expect(out.model, leLedModel);
    expect(out.kind, DeviceKind.lights);
    expect(values(out), {
      'on': true,
      'brightness': 50,
      'pattern': 'Rainbow',
      'colour': '#ff4100',
      'speed': 200,
      'intensity': 100,
      'preset': 7,
    });
    expect(out.info['counter'], '1000');
    final s = LeLedKeys.stateOf('A0:B1:C2:D3:E4:F5')!;
    expect(s.acks(2, 77), isTrue);
    expect(s.acks(1, 77), isFalse);
    expect(LeLedKeys.keyOf('A0:B1:C2:D3:E4:F5'), key);
  });

  test('iOS reads the MAC from the scan response', () {
    LeLedKeys.clear();
    const id = '64FA0E6C-79EC-A70E-E6AA-F071A29BD9CC';
    final dec = BtHomeDecoder(
      keyFor: keyFor(id, '00112233445566778899aabbccddeeff'),
    );
    const state = '416483fc80612c1f0691b8e3ff4594e80300003cc6a4f0';
    final out = dec.decode(
      adv(
        id: id,
        mac: null,
        serviceData: {0xFCD2: state},
        manufacturerData: {0xFFFF: '4d a0 b1 c2 d3 e4 f5'},
      ),
    )!;
    expect(out.model, leLedModel);
    expect(out.info['mac'], 'A0:B1:C2:D3:E4:F5');
    // A packet without the scan response still decrypts.
    final again = dec.decode(
      adv(id: id, mac: null, serviceData: {0xFCD2: state}),
    )!;
    expect(values(again)['brightness'], 50);
    // Health bytes after the MAC (firmware since 2026-11-18) are fine.
    LeLedKeys.clear();
    final fresh = BtHomeDecoder(
      keyFor: keyFor(id, '00112233445566778899aabbccddeeff'),
    );
    final withHealth = fresh.decode(
      adv(
        id: id,
        mac: null,
        serviceData: {0xFCD2: state},
        manufacturerData: {0xFFFF: '4d a0 b1 c2 d3 e4 f5 79 78 64 05 00 01'},
      ),
    )!;
    expect(withHealth.info['mac'], 'A0:B1:C2:D3:E4:F5');
  });
}
