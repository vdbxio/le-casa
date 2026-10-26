// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../decoders/raw_advertisement.dart';

/// Every payload in [a], one line per field, for devices we cannot decode.
String rawSummary(RawAdvertisement a) {
  final parts = <String>[
    for (final e in a.manufacturerData.entries)
      'mfr 0x${e.key.toRadixString(16).padLeft(4, '0')}: ${hex(e.value)}',
    for (final e in a.serviceData.entries)
      'svc 0x${e.key.toRadixString(16).padLeft(4, '0')}: ${hex(e.value)}',
    if (a.serviceUuids.isNotEmpty)
      'uuids: ${a.serviceUuids.map((u) => u.toRadixString(16)).join(', ')}',
  ];
  return parts.isEmpty ? 'no payload (name/flags only)' : parts.join('\n');
}

class Rssi extends StatelessWidget {
  final int rssi;
  const Rssi(this.rssi, {super.key});

  @override
  Widget build(BuildContext context) {
    final bars = rssi > -60
        ? 4
        : rssi > -70
        ? 3
        : rssi > -80
        ? 2
        : rssi > -90
        ? 1
        : 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(switch (bars) {
          4 => Icons.signal_cellular_alt,
          3 => Icons.signal_cellular_alt,
          2 => Icons.signal_cellular_alt_2_bar,
          1 => Icons.signal_cellular_alt_1_bar,
          _ => Icons.signal_cellular_0_bar,
        }, size: 16),
        const SizedBox(width: 3),
        Text('$rssi', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
