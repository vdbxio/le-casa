// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/bms/base_bms.dart';
import 'package:lecasa/bms/registry.dart';
import 'package:lecasa/decoders/bms.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/drivers/bms_driver.dart';
import 'package:lecasa/drivers/daly_driver.dart';
import 'package:lecasa/drivers/driver.dart';

import '../fake_session.dart';

RawAdvertisement _jbdAdv() => RawAdvertisement(
  id: 'A4:C1:37:00:11:22',
  mac: parseMac('A4:C1:37:00:11:22'),
  name: 'SP04S034L100A',
  rssi: -60,
  seenAt: DateTime.utc(2026, 10, 25),
  serviceUuids: const [0xFF00],
);

Uint8List _h(String s) => fromHexStr(s);

/// A JBD battery answering like the one in aiobmsble's tests.
FakeSession _jbd() => FakeSession(
  characteristics: [
    const GattChar(
      '0000ff01-0000-1000-8000-00805f9b34fb',
      canRead: true,
      canNotify: true,
    ),
    const GattChar(
      '0000ff02-0000-1000-8000-00805f9b34fb',
      canWriteWithoutResponse: true,
    ),
  ],
  onWrite: (c, data) => switch (hex(data, sep: '')) {
    'dda50300fffd77' => [
      _h('dd03001d0618fee101f201f4002a2c7c00000000'),
      _h('000080640304030b8b0b8a0b84f88477'),
    ],
    'dda50400fffc77' => [_h('dd0400080d660d610d680d59fe3c77')],
    _ => const [],
  },
);

void main() {
  BaseBms.timeScale = 0.01;

  test('JBD battery advertisement goes to the BMS driver', () {
    final reg = GattDriverRegistry.standard();
    expect(reg.forAdvertisement(_jbdAdv()), isA<BmsDriver>());
    expect(bmsSpecFor(_jbdAdv())?.module, 'jbd_bms');
  });

  test('Daly modules with a DL- name keep the Daly driver', () {
    final daly = RawAdvertisement(
      id: 'x',
      name: 'DL-40D63C2012A1',
      rssi: -60,
      seenAt: DateTime.utc(2026),
      manufacturerData: {
        0x0402: Uint8List.fromList([1, 2]),
      },
    );
    expect(
      GattDriverRegistry.standard().forAdvertisement(daly),
      isA<DalyDriver>(),
    );
  });

  test('waiting card before the first connection', () {
    final d = const BmsDecoder().decode(_jbdAdv())!;
    expect(d.kind, DeviceKind.battery);
    expect(d.model, 'Jiabaida smart BMS');
    expect(d.needs, contains('PIN'));
  });

  test('reads a JBD battery over a session', () async {
    final driver = BmsDriver();
    final s = _jbd();
    final d = await driver.read(s, _jbdAdv());
    double? n(String l) =>
        (d.readings.firstWhere((r) => r.label == l).value as num?)?.toDouble();
    expect(d.kind, DeviceKind.battery);
    expect(d.protocol, 'Jiabaida BMS');
    expect(n('voltage'), 15.6);
    expect(n('current'), -2.87);
    expect(n('state of charge'), 100);
    expect(n('cell 1'), 3.43);
    expect(n('cell spread'), 15);
    expect(d.readings.any((r) => r.label == 'power'), isTrue);
    expect(
      d.readings.firstWhere((r) => r.label == 'state').value,
      'discharging',
    );
    expect(d.info['bms'], 'jbd_bms');
    // the second read reuses the BMS object
    await driver.read(_jbd(), _jbdAdv());
  });

  test('labels temperatures by sensor type', () {
    final d = bmsSampleToDecoded(bmsSpecByModule('jbd_bms')!, {
      'temp_values': [
        const TempSensor(21.5, TempType.cell),
        const TempSensor(22, TempType.cell),
        const TempSensor(30, TempType.mosfet),
      ],
      'problem': true,
      'problem_code': -1,
    }, module: 'x');
    final labels = [for (final r in d.readings) r.label];
    expect(labels, [
      'temperature 1',
      'temperature 2',
      'MOSFET temperature',
      'alarm',
    ]);
    expect(d.readings.last.value, 'code 0xffffffffffffffff');
  });
}
