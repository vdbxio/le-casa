// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Real GattSession on top of the bluetooth_low_energy CentralManager.

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

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
      final uuid = e.characteristic.uuid.toString().toLowerCase();
      debugPrint(
        'gatt: notify ${uuid.substring(4, 8)} ${e.value.length} B: '
        '${_hex(e.value)}',
      );
      _notify[uuid]?.add(e.value);
    });
    _stateSub = _central.connectionStateChanged.listen((e) {
      if (e.peripheral == peripheral &&
          e.state == ConnectionState.disconnected &&
          !_disconnected.isCompleted) {
        debugPrint('gatt: ${peripheral.uuid} disconnected by the device');
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
    // Android gives up on its own after 30 s; a Daly module in a battery
    // box has been seen to take 22 s, so do not cut it shorter than that.
    Duration timeout = const Duration(seconds: 32),
  }) async {
    debugPrint('gatt: connecting ${peripheral.uuid}');
    await central.connect(peripheral).timeout(timeout);
    debugPrint('gatt: connected ${peripheral.uuid}, discovering services');
    try {
      final services = await central
          .discoverGATT(peripheral)
          .timeout(const Duration(seconds: 15));
      final chars = <GATTCharacteristic>[
        for (final s in services) ...s.characteristics,
        for (final s in services)
          for (final inc in s.includedServices) ...inc.characteristics,
      ];
      debugPrint(
        'gatt: ${peripheral.uuid} has ${chars.length} characteristics: '
        '${chars.map((c) => c.uuid.toString().substring(4, 8)).join(' ')}',
      );
      return GattLink._(central, peripheral, chars);
    } catch (e) {
      debugPrint('gatt: discovery on ${peripheral.uuid} failed: $e');
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
  Future<void> write(GattChar c, Uint8List data, {bool withResponse = true}) {
    // Honour what the characteristic actually supports: a module that only
    // takes one kind of write would reject (or worse, stall on) the other.
    final useResponse = withResponse
        ? c.canWrite || !c.canWriteWithoutResponse
        : !c.canWriteWithoutResponse && c.canWrite;
    debugPrint(
      'gatt: write ${c.uuid.substring(4, 8)} '
      '${useResponse ? 'with' : 'without'} response: ${_hex(data)}',
    );
    return _central.writeCharacteristic(
      peripheral,
      _platform(c),
      value: data,
      type: useResponse
          ? GATTCharacteristicWriteType.withResponse
          : GATTCharacteristicWriteType.withoutResponse,
    );
  }

  @override
  Future<Stream<Uint8List>> subscribe(GattChar c) async {
    final existing = _notify[c.uuid];
    if (existing != null) return existing.stream;
    final ctl = StreamController<Uint8List>.broadcast();
    _notify[c.uuid] = ctl;
    debugPrint('gatt: subscribe ${c.uuid.substring(4, 8)}');
    await _central.setCharacteristicNotifyState(
      peripheral,
      _platform(c),
      state: true,
    );
    return ctl.stream;
  }

  @override
  Future<void> close() async {
    debugPrint('gatt: closing ${peripheral.uuid}');
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

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
