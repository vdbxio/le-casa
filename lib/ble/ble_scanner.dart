// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Thin wrapper over the bluetooth_low_energy plugin's CentralManager that
// turns platform scan results into plain RawAdvertisement values.

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../decoders/raw_advertisement.dart';

class BleScanner {
  final CentralManager _central;
  final _out = StreamController<RawAdvertisement>.broadcast();
  final Map<String, Peripheral> _peripherals = {};
  StreamSubscription? _sub;
  bool _scanning = false;

  BleScanner([CentralManager? central])
    : _central = central ?? CentralManager();

  Stream<RawAdvertisement> get advertisements => _out.stream;

  /// The platform manager, for the connection layer.
  CentralManager get central => _central;

  /// The platform handle for a device id the scanner has reported, needed
  /// to connect to it. Null if we never heard it.
  Peripheral? peripheralFor(String id) => _peripherals[id];
  bool get scanning => _scanning;

  /// Whether the scan has to pause while a link opens. Android tablets'
  /// radios fail connects (status 133) with a scan running; Apple's
  /// handle both, and a scan paused for every poll there missed the
  /// other screens' "Hey, Gary" claims.
  static bool get pausesForLinks =>
      defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.macOS;

  /// The person paused scanning, or it has not started yet. Otherwise a
  /// scan that is off is only waiting for a connection to open, and comes
  /// back by itself.
  bool get paused => _paused;
  bool _paused = true;

  BluetoothLowEnergyState get state => _central.state;
  Stream<BluetoothLowEnergyState> get stateChanges =>
      _central.stateChanged.map((e) => e.state);

  /// Asks for the Bluetooth (and on old Android, location) permissions.
  Future<bool> authorize() => _central.authorize();

  Future<void> showAppSettings() => _central.showAppSettings();

  /// Starts and stops run one after another: a start that arrives while a
  /// stop is still going must not see the old "scanning" flag and do
  /// nothing, or the scan stays off for good.
  Future<void> _ops = Future.value();
  Timer? _watchdog;
  DateTime _lastAdvert = DateTime.now();
  DateTime? _stoppedAt;

  Future<void> _queue(Future<void> Function() op) {
    final next = _ops.then((_) => op());
    _ops = next.catchError((_) {});
    return next;
  }

  /// Starts scanning. Safe to call from several places at once; a platform
  /// "already started" error is treated as success.
  Future<void> start() => _queue(() async {
    _paused = false;
    if (_scanning) return;
    await _doStart();
  });

  Future<void> _doStart() async {
    _sub ??= _central.discovered.listen((e) {
      _lastAdvert = DateTime.now();
      final adv = toRaw(e.peripheral.uuid, e.rssi, e.advertisement);
      _peripherals[adv.id] = e.peripheral;
      _out.add(adv);
    });
    try {
      await _central.startDiscovery().timeout(_platformLimit);
    } catch (e) {
      // Android reports SCAN_FAILED_ALREADY_STARTED (1) when another path
      // got there first; the radio is scanning, so that is not a failure.
      if (!_isAlreadyStarted(e)) rethrow;
    }
    _scanning = true;
    _stoppedAt = null;
    _lastAdvert = DateTime.now();
    _watchdog ??= Timer.periodic(const Duration(seconds: 15), (_) => _check());
  }

  /// Scans can die quietly: a pause for a connection whose restart got
  /// lost, or iOS dropping the scan. Restart one that has been off for long
  /// after a pause, or that has heard nothing at all for a while.
  void _check() {
    final now = DateTime.now();
    final off = _stoppedAt;
    if (!_scanning &&
        !_paused &&
        off != null &&
        now.difference(off) > _offTooLong) {
      debugPrint('scan: off since $off, starting again');
      unawaited(start().catchError((Object e) => debugPrint('scan: $e')));
    } else if (_scanning && now.difference(_lastAdvert) > _quietTooLong) {
      debugPrint('scan: nothing heard since $_lastAdvert, restarting');
      unawaited(
        _queue(() async {
          try {
            await _central.stopDiscovery().timeout(_platformLimit);
          } catch (_) {}
          _scanning = false;
          await _doStart();
        }).catchError((Object e) => debugPrint('scan: $e')),
      );
    }
  }

  /// A start or stop that never returns would hold up every later one,
  /// and every connect waits for the scan to pause.
  static const _platformLimit = Duration(seconds: 10);
  static const _offTooLong = Duration(seconds: 90);
  static const _quietTooLong = Duration(seconds: 45);

  static bool _isAlreadyStarted(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('already') ||
        RegExp(r'error ?code[ =:]*1\b').hasMatch(msg);
  }

  /// Starts again after a pause for a connection, unless the person
  /// paused scanning meanwhile.
  Future<void> resume() => _queue(() async {
    if (_paused || _scanning) return;
    await _doStart();
  });

  /// Stops scanning until [start], for the person's pause button.
  Future<void> pause() {
    _paused = true;
    return stop();
  }

  Future<void> stop() => _queue(() async {
    if (!_scanning) return;
    try {
      await _central.stopDiscovery().timeout(_platformLimit);
    } on TimeoutException {
      debugPrint('scan: stop did not answer');
    }
    _scanning = false;
    _stoppedAt = DateTime.now();
  });

  Future<void> dispose() async {
    _watchdog?.cancel();
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
