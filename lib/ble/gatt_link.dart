// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Real GattSession on top of the bluetooth_low_energy CentralManager.

import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'gatt_session.dart';

class GattLink implements ClosableSession {
  final CentralManager _central;
  final Peripheral peripheral;
  final List<GATTCharacteristic> _platformChars;
  @override
  final List<GattChar> characteristics;
  final Map<String, StreamController<Uint8List>> _notify = {};
  StreamSubscription? _notifySub;
  StreamSubscription? _stateSub;
  final _disconnected = Completer<void>();

  GattLink._(this._central, this.peripheral, this._platformChars)
    : characteristics = [
        for (final c in _platformChars)
          GattChar(
            c.uuid.toString().toLowerCase(),
            canRead: c.properties.contains(GATTCharacteristicProperty.read),
            canWrite: c.properties.contains(GATTCharacteristicProperty.write),
            canWriteWithoutResponse: c.properties.contains(
              GATTCharacteristicProperty.writeWithoutResponse,
            ),
            canNotify:
                c.properties.contains(GATTCharacteristicProperty.notify) ||
                c.properties.contains(GATTCharacteristicProperty.indicate),
          ),
      ] {
    _notifySub = _central.characteristicNotified.listen((e) {
      if (e.peripheral != peripheral) return;
      _notify[e.characteristic.uuid.toString().toLowerCase()]?.add(e.value);
    });
    _stateSub = _central.connectionStateChanged.listen((e) {
      if (e.peripheral == peripheral &&
          e.state == ConnectionState.disconnected &&
          !_disconnected.isCompleted) {
        _disconnected.complete();
      }
    });
  }

  /// Completes when the peripheral drops the link on its own.
  Future<void> get onDisconnected => _disconnected.future;

  /// Connects and discovers services. Throws on failure or after
  /// [timeout]; the caller does not need to disconnect in that case.
  static Future<GattLink> open(
    CentralManager central,
    Peripheral peripheral, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await central.connect(peripheral).timeout(timeout);
    try {
      final services = await central.discoverGATT(peripheral).timeout(timeout);
      final chars = <GATTCharacteristic>[
        for (final s in services) ...s.characteristics,
        for (final s in services)
          for (final inc in s.includedServices) ...inc.characteristics,
      ];
      return GattLink._(central, peripheral, chars);
    } catch (_) {
      try {
        await central.disconnect(peripheral);
      } catch (_) {}
      rethrow;
    }
  }

  GATTCharacteristic _platform(GattChar c) =>
      _platformChars[characteristics.indexOf(c)];

  @override
  Future<Uint8List> read(GattChar c) =>
      _central.readCharacteristic(peripheral, _platform(c));

  @override
  Future<void> write(GattChar c, Uint8List data, {bool withResponse = true}) =>
      _central.writeCharacteristic(
        peripheral,
        _platform(c),
        value: data,
        type: withResponse
            ? GATTCharacteristicWriteType.withResponse
            : GATTCharacteristicWriteType.withoutResponse,
      );

  @override
  Future<Stream<Uint8List>> subscribe(GattChar c) async {
    final existing = _notify[c.uuid];
    if (existing != null) return existing.stream;
    final ctl = StreamController<Uint8List>.broadcast();
    _notify[c.uuid] = ctl;
    await _central.setCharacteristicNotifyState(
      peripheral,
      _platform(c),
      state: true,
    );
    return ctl.stream;
  }

  @override
  Future<void> close() async {
    await _notifySub?.cancel();
    await _stateSub?.cancel();
    for (final c in _notify.values) {
      await c.close();
    }
    _notify.clear();
    try {
      await _central.disconnect(peripheral).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Already gone, or the stack is wedged; nothing more we can do.
    }
  }
}
