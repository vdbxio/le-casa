import 'dart:typed_data';

import 'package:lecasa/decoders/raw_advertisement.dart';

RawAdvertisement adv({
  String id = 'A4:C1:38:8D:18:B2',
  String? mac = 'A4:C1:38:8D:18:B2',
  String? name,
  Map<int, String> serviceData = const {},
  Map<int, String> manufacturerData = const {},
  List<int> serviceUuids = const [],
  DateTime? seenAt,
}) => RawAdvertisement(
  id: id,
  mac: parseMac(mac),
  name: name,
  rssi: -60,
  seenAt: seenAt ?? DateTime.utc(2026, 10, 23),
  serviceData: serviceData.map((k, v) => MapEntry(k, fromHex(v))),
  manufacturerData: manufacturerData.map((k, v) => MapEntry(k, fromHex(v))),
  serviceUuids: serviceUuids,
);

Uint8List? Function(String) keyFor(String id, String hexKey) =>
    (String q) => q == id ? fromHex(hexKey) : null;
