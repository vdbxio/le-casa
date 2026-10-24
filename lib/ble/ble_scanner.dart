// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Thin wrapper over the bluetooth_low_energy plugin's CentralManager that
// turns platform scan results into plain RawAdvertisement values.

import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../decoders/raw_advertisement.dart';

class BleScanner {
  final CentralManager _central;
  final _out = StreamController<RawAdvertisement>.broadcast();
  StreamSubscription? _sub;
  bool _scanning = false;

  BleScanner([CentralManager? central])
    : _central = central ?? CentralManager();

  Stream<RawAdvertisement> get advertisements => _out.stream;
  bool get scanning => _scanning;

  BluetoothLowEnergyState get state => _central.state;
  Stream<BluetoothLowEnergyState> get stateChanges =>
      _central.stateChanged.map((e) => e.state);

  /// Asks for the Bluetooth (and on old Android, location) permissions.
  Future<bool> authorize() => _central.authorize();

  Future<void> showAppSettings() => _central.showAppSettings();

  Future<void>? _starting;

  /// Starts scanning. Safe to call from several places at once: callers that
  /// arrive while a start is in flight share the same future, and a platform
  /// "already started" error is treated as success.
  Future<void> start() {
    if (_scanning) return Future.value();
    return _starting ??= _doStart().whenComplete(() => _starting = null);
  }

  Future<void> _doStart() async {
    _sub ??= _central.discovered.listen((e) {
      final adv = toRaw(e.peripheral.uuid, e.rssi, e.advertisement);
      _out.add(adv);
    });
    try {
      await _central.startDiscovery();
    } catch (e) {
      // Android reports SCAN_FAILED_ALREADY_STARTED (1) when another path
      // got there first; the radio is scanning, so that is not a failure.
      if (!_isAlreadyStarted(e)) rethrow;
    }
    _scanning = true;
  }

  static bool _isAlreadyStarted(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('already') ||
        RegExp(r'error ?code[ =:]*1\b').hasMatch(msg);
  }

  Future<void> stop() async {
    if (!_scanning) return;
    await _central.stopDiscovery();
    _scanning = false;
  }

  Future<void> dispose() async {
    await stop();
    await _sub?.cancel();
    await _out.close();
  }

  /// Converts a plugin scan result. Public and static so it can be unit
  /// tested without a radio.
  static RawAdvertisement toRaw(UUID uuid, int rssi, Advertisement a) {
    final mac = macFromUuid(uuid);
    final serviceData = <int, Uint8List>{};
    for (final entry in a.serviceData.entries) {
      final short = shortUuid(entry.key);
      if (short != null) serviceData[short] = entry.value;
    }
    final mfr = <int, Uint8List>{};
    for (final m in a.manufacturerSpecificData) {
      mfr[m.id] = m.data;
    }
    return RawAdvertisement(
      id: mac != null ? hex(mac, sep: ':').toUpperCase() : uuid.toString(),
      mac: mac,
      name: (a.name?.isEmpty ?? true) ? null : a.name,
      rssi: rssi,
      seenAt: DateTime.now(),
      serviceData: serviceData,
      manufacturerData: mfr,
      serviceUuids: [for (final u in a.serviceUUIDs) ?shortUuid(u)],
      longServiceUuids: [
        for (final u in a.serviceUUIDs)
          if (!u.isShort) u.toString().toLowerCase(),
      ],
    );
  }

  /// On Android the plugin encodes the MAC as `00000000-0000-0000-0000-<mac>`.
  static Uint8List? macFromUuid(UUID uuid) {
    final v = uuid.value;
    for (var i = 0; i < 10; i++) {
      if (v[i] != 0) return null;
    }
    return Uint8List.fromList(v.sublist(10));
  }

  /// 16/32-bit value of a UUID on the Bluetooth base, else null.
  static int? shortUuid(UUID u) {
    if (!u.isShort) return null;
    final v = u.value;
    return (v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3];
  }
}
