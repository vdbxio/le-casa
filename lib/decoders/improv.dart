// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Improv Wi-Fi over BLE (https://www.improv-wifi.com/ble/). ESPHome and
// other firmware advertise this while they wait for Wi-Fi credentials.
// Le'Casa does not provision Wi-Fi, so these are recognised and parked in
// their own group rather than cluttering the unknown list.

import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';

const String improvServiceUuid = '00467768-6228-2272-4663-277478268000';
const int improvServiceDataUuid = 0x4677;

const Map<int, String> improvStates = {
  0x00: 'Stopped',
  0x01: 'Awaiting authorization',
  0x02: 'Authorized',
  0x03: 'Provisioning',
  0x04: 'Provisioned',
};

class ImprovDecoder implements Decoder {
  const ImprovDecoder();

  @override
  String get name => 'Improv';

  @override
  bool matches(RawAdvertisement adv) =>
      adv.serviceData.containsKey(improvServiceDataUuid) ||
      adv.longServiceUuids.contains(improvServiceUuid);

  @override
  Decoded? decode(RawAdvertisement adv) {
    final d = adv.serviceData[improvServiceDataUuid];
    final readings = <Reading>[];
    final info = <String, String>{};
    if (d != null && d.length >= 2) {
      readings.add(Reading('state', improvStates[d[0]] ?? 'state ${d[0]}'));
      info['can identify'] = (d[1] & 0x01) != 0 ? 'yes' : 'no';
    }
    return Decoded(
      protocol: 'Improv BLE',
      kind: DeviceKind.improv,
      model: adv.name ?? 'Improv device',
      readings: readings,
      info: info,
    );
  }
}
