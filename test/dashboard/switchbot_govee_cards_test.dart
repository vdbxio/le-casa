import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/decoders/registry.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';

import '../helpers.dart';

void main() {
  final at = DateTime.utc(2026, 10, 27, 20);

  (DeviceTracker, CardSources) track(List<RawAdvertisement> ads) {
    final t = DeviceTracker(DecoderRegistry.standard());
    ads.forEach(t.onAdvertisement);
    return (t, CardSources(tracker: t, now: () => at));
  }

  test("Chloe's Indoor/Outdoor Meter (W3400010), captured on the Mac", () {
    // macOS id, no name; the scan response adds the service data.
    const id = 'B1D2D783-13DA-ABE0-2935-95F33A75F261';
    final (t, s) = track([
      adv(
        id: id,
        mac: null,
        manufacturerData: {0x0969: 'ce1bc5065e660106089e9600'},
        seenAt: at,
      ),
      adv(
        id: id,
        mac: null,
        serviceData: {0xFD3D: '7740e4'},
        manufacturerData: {0x0969: 'ce1bc5065e660106089e9600'},
        seenAt: at,
      ),
    ]);
    final d = t[id]!;
    expect(d.view!.model, 'SwitchBot Indoor/Outdoor Meter');
    expect(deviceName(d), 'Climate · 5E66');
    final m = s.model(CardSpec.device(id));
    expect(m.headline!.inline, '30.8 °C');
    expect(m.details.first.inline, '22 %');
  });

  test('a plug card leads with watts and says whether it is on', () {
    final (_, s) = track([
      adv(
        serviceData: {0xFD3D: '6700'},
        manufacturerData: {0x0969: 'AABBCCDDEEFF0080003C04D2'},
        seenAt: at,
      ),
    ]);
    final m = s.model(CardSpec.device('A4:C1:38:8D:18:B2'));
    expect(m.headline!.inline, '123 W');
    expect(m.state, 'On');
  });

  test('a contact sensor card says open or closed', () {
    final (_, s) = track([
      adv(
        serviceData: {0xFD3D: '64406405007500f812'},
        manufacturerData: {0x0969: 'e7ab46ac8f927c0f001104'},
        seenAt: at,
      ),
    ]);
    final m = s.model(CardSpec.device('A4:C1:38:8D:18:B2'));
    expect(m.headline!.label, 'Door');
    expect(m.headline!.value, 'Open');
  });

  test('a Govee sensor is named by the MAC tail in its name', () {
    final (t, s) = track([
      adv(
        id: '61DE521B-F0BF-9F44-64D4-75BBE1738105',
        mac: null,
        name: 'GVH5075_2762',
        manufacturerData: {0xEC88: '000341c26400'},
        seenAt: at,
      ),
    ]);
    final d = t['61DE521B-F0BF-9F44-64D4-75BBE1738105']!;
    expect(deviceName(d), 'Climate · 2762');
    expect(s.model(CardSpec.device(d.id)).headline!.inline, '21.3 °C');
  });
}
