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

  GattLink._(
    this._central,
    this.peripheral,
    this._platformChars,
    List<String> serviceOf,
  ) : characteristics = [
        for (final (i, c) in _platformChars.indexed)
          GattChar(
            c.uuid.toString().toLowerCase(),
            service: serviceOf[i],
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

  @override
  Future<void> get onDisconnected => _disconnected.future;

  @override
  bool get droppedByDevice => _disconnected.isCompleted;

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
    try {
      await central.connect(peripheral).timeout(timeout);
    } on TimeoutException {
      // iOS never gives up on a connect by itself; cancel it, or it stays
      // pending and the next connect to this device is never answered.
      await _cancel(central, peripheral);
      rethrow;
    }
    debugPrint('gatt: connected ${peripheral.uuid}, discovering services');
    try {
      // Ask for a big MTU first, like iOS and macOS do on every connection.
      // A Daly module answered a Mac (MTU 512) in one 129-byte notification
      // but dropped the tablet, which never asked, so some firmware may
      // wait for this exchange. Not supported everywhere; failure is fine.
      try {
        final mtu = await central
            .requestMTU(peripheral, mtu: 512)
            .timeout(const Duration(seconds: 3));
        debugPrint('gatt: mtu $mtu');
      } catch (e) {
        debugPrint('gatt: mtu request skipped: $e');
      }
      final services = await central
          .discoverGATT(peripheral)
          .timeout(const Duration(seconds: 15));
      final chars = <GATTCharacteristic>[];
      final serviceOf = <String>[];
      void add(GATTService s) {
        for (final c in s.characteristics) {
          chars.add(c);
          serviceOf.add(s.uuid.toString().toLowerCase());
        }
      }

      services.forEach(add);
      for (final s in services) {
        s.includedServices.forEach(add);
      }
      debugPrint(
        'gatt: ${peripheral.uuid} has ${chars.length} characteristics: '
        '${chars.map((c) => c.uuid.toString().substring(4, 8)).join(' ')}',
      );
      return GattLink._(central, peripheral, chars, serviceOf);
    } catch (e) {
      debugPrint('gatt: discovery on ${peripheral.uuid} failed: $e');
      await _cancel(central, peripheral);
      rethrow;
    }
  }

  /// Disconnects, without waiting for ever: iOS answers a disconnect only
  /// when the link actually goes down.
  static Future<void> _cancel(CentralManager central, Peripheral p) async {
    try {
      await central.disconnect(p).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  GATTCharacteristic _platform(GattChar c) =>
      _platformChars[characteristics.indexOf(c)];

  /// Most bytes one write can carry on this link (MTU less the header).
  Future<int> maxWriteLength({bool withResponse = true}) => _central
      .getMaximumWriteLength(
        peripheral,
        type: withResponse
            ? GATTCharacteristicWriteType.withResponse
            : GATTCharacteristicWriteType.withoutResponse,
      )
      .timeout(const Duration(seconds: 5));

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
    return RadioWrites.track(
      _central.writeCharacteristic(
        peripheral,
        _platform(c),
        value: data,
        type: useResponse
            ? GATTCharacteristicWriteType.withResponse
            : GATTCharacteristicWriteType.withoutResponse,
      ),
    );
  }

  @override
  Future<Stream<Uint8List>> subscribe(GattChar c) async {
    final existing = _notify[c.uuid];
    if (existing != null) return existing.stream;
    final ctl = StreamController<Uint8List>.broadcast();
    _notify[c.uuid] = ctl;
    debugPrint('gatt: subscribe ${c.uuid.substring(4, 8)}');
    // iOS never answers when the other end drops mid-request, and a call
    // that never returns holds the radio for every other device.
    await _central
        .setCharacteristicNotifyState(peripheral, _platform(c), state: true)
        .timeout(const Duration(seconds: 10));
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
    // Already gone, or the stack is wedged; nothing more we can do.
    await _cancel(_central, peripheral);
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

/// Writes waiting for an answer, on any link. The M10's Bluetooth stack
/// has crashed twice when the scan was paused for a connect while a write
/// to another screen hung: the scan-filter command it sends on a pause
/// timed out and took the stack down. Connects check this first.
class RadioWrites {
  static int _pending = 0;

  static Future<T> track<T>(Future<T> write) {
    _pending++;
    return write.whenComplete(() => _pending--);
  }

  /// Waits up to [limit] for writes in flight to finish. False when some
  /// are still waiting: leave the scan alone then.
  static Future<bool> settle({
    Duration limit = const Duration(seconds: 3),
  }) async {
    final until = DateTime.now().add(limit);
    while (_pending > 0) {
      if (DateTime.now().isAfter(until)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }
}
