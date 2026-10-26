import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/registry.dart';
import 'package:lecasa/ui/device_rows.dart';

import 'helpers.dart';

void main() {
  const mppt = '10 02 42 a0 01 62 07 ad ce b3 7b 60 5d 7e 0e e2 1b 24 df 5c';

  DeviceTracker feed() {
    final t = DeviceTracker(DecoderRegistry.standard());
    t.onAdvertisement(
      adv(id: 'phone', mac: null, manufacturerData: {0x0059: '10 05 01'}),
    );
    t.onAdvertisement(
      adv(
        id: 'xiaomi',
        name: 'ATC_8D18B2',
        serviceData: {0xFCD2: '40 02 ca 09 03 bf 13'},
      ),
    );
    t.onAdvertisement(adv(id: 'mppt', manufacturerData: {0x02E1: mppt}));
    t.onAdvertisement(
      adv(
        id: 'fob',
        name: "Le'Fob",
        serviceData: {0xFCD2: '44 00 07 01 5a 3a 01'},
      ),
    );
    t.onAdvertisement(
      adv(id: 'improv', serviceData: {0x4677: '01 00 00 00 00 00'}),
    );
    t.onAdvertisement(
      adv(id: 'tv', mac: null, manufacturerData: {0x0075: '42 04'}),
    );
    t.onAdvertisement(
      adv(id: 'airtag', mac: null, manufacturerData: {0x004C: '12 02 00 00'}),
    );
    return t;
  }

  test('devices are grouped by kind in a fixed group order', () {
    final g = feed().groups;
    expect(g.keys, [
      DeviceKind.climate,
      DeviceKind.solar,
      DeviceKind.leDevice,
      DeviceKind.improv,
      DeviceKind.background,
    ]);
    expect(
      g[DeviceKind.solar]!.single.decoded!.needs,
      contains('VictronConnect'),
    );
  });

  test('unknown devices keep first-heard order however loud they get', () {
    final t = feed();
    expect(t.unknown.map((d) => d.id), ['phone', 'tv']);
    // A later, stronger packet from the first device must not reorder.
    t.onAdvertisement(
      adv(id: 'tv', mac: null, manufacturerData: {0x0075: '42 05'}),
    );
    t.onAdvertisement(
      adv(id: 'phone', mac: null, manufacturerData: {0x0059: '10 06'}),
    );
    expect(t.unknown.map((d) => d.id), ['phone', 'tv']);
  });

  test('a Victron device keeps its group after its key is added', () {
    final t = feed();
    // A name-only scan response arrives last; re-decoding must still use
    // the data packet, or the device stays on "needs key" until the next one.
    t.onAdvertisement(adv(id: 'mppt', name: 'Sol 30'));
    t.registry = DecoderRegistry.standard(
      keyFor: keyFor('mppt', 'adeccb947395801a4dd45a2eaa44bf17'),
    );
    t.redecodeAll();
    final solar = t.groups[DeviceKind.solar]!.single;
    expect(solar.decoded!.needs, isNull);
    expect(primaryReading(solar.decoded!)!.display, '19 W');
  });

  testWidgets('a device row shows the name and the reading that sums it up', (
    tester,
  ) async {
    final t = feed();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeviceRow(
            device: t.groups[DeviceKind.climate]!.single,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Climate · '), findsOneWidget);
    expect(find.textContaining('ATC_8D18B2'), findsOneWidget);
    expect(find.text('25.06 °C'), findsOneWidget);
  });

  testWidgets('a Daly waiting for its first read says Connecting', (
    tester,
  ) async {
    final t = DeviceTracker(DecoderRegistry.standard());
    t.onAdvertisement(
      adv(
        id: 'daly',
        name: 'DL-694201312BA',
        manufacturerData: {0x0402: '16 40 17 10 01 5c'},
      ),
    );
    final d = t['daly']!;
    expect(d.view?.needs, isNotNull);
    Future<void> show(bool connecting) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeviceRow(device: d, onTap: () {}, connecting: connecting),
        ),
      ),
    );
    await show(false);
    expect(find.text('Needs setup'), findsOneWidget);
    await show(true);
    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('a narrow device row does not overflow', (tester) async {
    final t = DeviceTracker(DecoderRegistry.standard());
    t.onAdvertisement(
      adv(
        id: 'x',
        name: 'A rather long advertised name for a thermometer',
        serviceData: {0xFCD2: '40 02 ca 09 03 bf 13'},
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: DeviceRow(device: t['x']!, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('a device first heard without a name takes the one saved', () {
    final t = DeviceTracker(DecoderRegistry.standard());
    t.nameFor = (id) => id == 'daly' ? 'DL-694201312BA' : null;
    // After a restart, a held-open Daly sends no name at all.
    t.onAdvertisement(adv(id: 'daly', name: null));
    expect(t['daly']!.latest.name, 'DL-694201312BA');
    // A name that arrives from another screen later fills in too.
    t.onAdvertisement(adv(id: 'xiaomi', name: null));
    expect(t['xiaomi']!.latest.name, isNull);
    t.nameFor = (id) => id == 'xiaomi' ? 'LYWSD03MMC' : null;
    t.relabel();
    expect(t['xiaomi']!.latest.name, 'LYWSD03MMC');
    // What the device sends itself wins.
    t.onAdvertisement(adv(id: 'daly', name: 'DL-NEW'));
    expect(t['daly']!.latest.name, 'DL-NEW');
  });

  test('a packet without a name keeps the name heard earlier', () {
    final t = DeviceTracker(DecoderRegistry.standard());
    t.onAdvertisement(
      adv(id: 'mppt', name: 'Roof MPPT', manufacturerData: {0x02E1: mppt}),
    );
    t.onAdvertisement(
      adv(id: 'mppt', name: null, manufacturerData: {0x02E1: mppt}),
    );
    expect(t['mppt']!.latest.name, 'Roof MPPT');
    // And a decoder that uses the name still sees it.
    t.onAdvertisement(
      adv(
        id: 'fob',
        name: "Le'Fob",
        serviceData: {0xFCD2: '44 00 07 01 5a 3a 01'},
      ),
    );
    t.onAdvertisement(
      adv(id: 'fob', name: null, serviceData: {0xFCD2: '44 00 08 01 5a 3a 00'}),
    );
    expect(t['fob']!.decoded!.model, "Le'Fob");
  });
}
