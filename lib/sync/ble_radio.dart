// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Screen sync over real Bluetooth. The hub runs the Le'Casa GATT service
// with the plugin's PeripheralManager and advertises its home tag; members
// find it through the normal scan and connect with a GattLink, the same
// way the app talks to a fridge or a BMS.

import 'dart:async';
import 'dart:convert';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../ble/ble_scanner.dart';
import '../ble/connection_manager.dart';
import '../ble/gatt_link.dart';
import '../ble/gatt_session.dart';
import '../decoders/raw_advertisement.dart';
import 'framing.dart';
import 'home.dart';
import 'radio.dart';

class BleSyncRadio implements SyncRadio {
  final BleScanner scanner;
  PeripheralManager? _pmInstance;
  final _incoming = StreamController<MessageLink>.broadcast();
  final Map<String, _CentralLink> _links = {};
  final List<StreamSubscription> _subs = [];
  GATTCharacteristic? _tx;
  Uint8List _info = Uint8List(0);

  /// Shares the radio with device polls, when given.
  final ConnectionManager? connections;

  BleSyncRadio(this.scanner, {this.connections});

  PeripheralManager get _pm => _pmInstance ??= PeripheralManager();

  @override
  Stream<MessageLink> get incoming => _incoming.stream;

  @override
  Stream<HubSighting> get sightings =>
      scanner.advertisements.map(sightingOf).where((s) => s != null).cast();

  /// A Le'Casa hub's advert, or null for anything else. Public for tests.
  static HubSighting? sightingOf(RawAdvertisement a) {
    if (!a.longServiceUuids.contains(syncServiceUuid)) return null;
    String? tag;
    final m = a.manufacturerData[syncCompanyId];
    if (m != null && m.length >= 4) {
      tag = hex(m.sublist(0, 4), sep: '');
    } else if (a.name?.startsWith(syncNamePrefix) ?? false) {
      tag = a.name!.substring(syncNamePrefix.length).trim().toLowerCase();
    }
    return HubSighting(a.id, tag, a.rssi, a.seenAt);
  }

  @override
  Future<void> startHub(String tag) async {
    final pm = _pm;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    // Android asks for the advertise and connect permissions here; on iOS
    // the plugin has no authorize() and the system asks by itself.
    try {
      await pm.authorize();
    } on UnsupportedError {
      // iOS
    }
    // The manager reports its real state a moment after it is created.
    // Poll rather than wait for an event: the change can land between a
    // check and a listen.
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (pm.state != BluetoothLowEnergyState.poweredOn) {
      if (pm.state == BluetoothLowEnergyState.unauthorized) {
        throw StateError('Bluetooth permission not granted');
      }
      if (DateTime.now().isAfter(until)) {
        throw StateError('Bluetooth is ${pm.state.name}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _info = Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'tag': tag})));
    final rx = GATTCharacteristic.mutable(
      uuid: UUID.fromString(syncRxUuid),
      // With response only: chunks must not get lost or overtake each other.
      properties: [GATTCharacteristicProperty.write],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    final tx = _tx = GATTCharacteristic.mutable(
      uuid: UUID.fromString(syncTxUuid),
      properties: [GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    final info = GATTCharacteristic.mutable(
      uuid: UUID.fromString(syncInfoUuid),
      properties: [GATTCharacteristicProperty.read],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    _subs.addAll([
      pm.characteristicReadRequested.listen((e) async {
        final off = e.request.offset.clamp(0, _info.length);
        try {
          await pm.respondReadRequestWithValue(
            e.request,
            value: Uint8List.sublistView(_info, off),
          );
        } catch (err) {
          debugPrint('sync hub: read reply failed: $err');
        }
      }),
      pm.characteristicWriteRequested.listen((e) async {
        if (e.characteristic.uuid != rx.uuid) {
          await pm.respondWriteRequestWithError(
            e.request,
            error: GATTError.writeNotPermitted,
          );
          return;
        }
        final link = await _linkFor(e.central);
        try {
          await pm.respondWriteRequest(e.request);
        } catch (err) {
          debugPrint('sync hub: write reply failed: $err');
        }
        if (!link._closed.isCompleted) link._in.add(e.request.value);
      }),
      pm.characteristicNotifyStateChanged.listen((e) async {
        if (e.characteristic.uuid != tx.uuid) return;
        if (e.state) {
          await _linkFor(e.central);
        } else {
          _links.remove(e.central.uuid.toString())?._gone();
        }
      }),
    ]);
    // Android also says when a member's link drops; iOS only unsubscribes.
    try {
      _subs.add(
        pm.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected) {
            _links.remove(e.central.uuid.toString())?._gone();
          }
        }),
      );
    } on UnsupportedError {
      // iOS
    }
    await pm.removeAllServices();
    await pm.addService(
      GATTService(
        uuid: UUID.fromString(syncServiceUuid),
        isPrimary: true,
        includedServices: [],
        characteristics: [info, rx, tx],
      ),
    );
    final apple =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    await pm.startAdvertising(
      Advertisement(
        // iOS adverts carry only a name and service UUIDs, so the tag goes
        // in the name there. On Android a name would rename the tablet's
        // Bluetooth, so it rides in manufacturer data instead.
        name: apple ? '$syncNamePrefix$tag' : null,
        serviceUUIDs: [UUID.fromString(syncServiceUuid)],
        manufacturerSpecificData: apple
            ? const []
            : [
                ManufacturerSpecificData(
                  id: syncCompanyId,
                  data: fromHexString(tag),
                ),
              ],
      ),
    );
    debugPrint('sync hub: advertising $tag');
  }

  Future<_CentralLink> _linkFor(Central c) async {
    final key = c.uuid.toString();
    final existing = _links[key];
    if (existing != null) return existing;
    var max = 20;
    try {
      max = await _pm.getMaximumNotifyLength(c);
    } catch (e) {
      debugPrint('sync hub: notify length unknown: $e');
    }
    final again = _links[key];
    if (again != null) return again;
    final link = _links[key] = _CentralLink(_pm, c, _tx!, max.clamp(20, 512));
    debugPrint('sync hub: ${c.uuid} joined, chunks of $max');
    _incoming.add(MessageLink(link));
    return link;
  }

  @override
  Future<void> stopHub() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final l in _links.values.toList()) {
      await l.close();
    }
    _links.clear();
    final pm = _pmInstance;
    if (pm == null) return;
    try {
      await pm.stopAdvertising();
      await pm.removeAllServices();
    } catch (e) {
      debugPrint('sync hub: stop failed: $e');
    }
  }

  @override
  Future<MessageLink> connect(HubSighting hub) {
    final c = connections;
    return c == null
        ? _connect(hub)
        : c.exclusive('sync hub', () => _connect(hub));
  }

  Future<MessageLink> _connect(HubSighting hub) async {
    final p = scanner.peripheralFor(hub.id);
    if (p == null) throw StateError('Hub not heard yet');
    // Scanning while connecting is the classic cause of status 133 on
    // cheap tablets; pause it for the connect, as device polls do.
    final wasScanning = scanner.scanning;
    if (wasScanning) await scanner.stop();
    GattLink? link;
    try {
      for (var attempt = 1; ; attempt++) {
        try {
          link = await GattLink.open(scanner.central, p);
          break;
        } catch (e) {
          if (attempt >= 3 || !'$e'.contains('133')) rethrow;
          debugPrint('sync: hub connect got 133, retry $attempt');
          await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
        }
      }
    } finally {
      if (wasScanning) unawaited(scanner.start());
    }
    final l = link;
    try {
      final rx = l.require(syncRxUuid, 'sync write');
      final tx = l.require(syncTxUuid, 'sync notify');
      final stream = await l.subscribe(tx);
      final max = await l.maxWriteLength();
      debugPrint('sync: connected to hub ${hub.id}, chunks of $max');
      return MessageLink(_GattChunkLink(l, rx, stream, max.clamp(20, 512)));
    } catch (_) {
      await l.close();
      rethrow;
    }
  }
}

/// Hub end of one member's link.
class _CentralLink implements ChunkLink {
  final PeripheralManager _pm;
  final Central central;
  final GATTCharacteristic _tx;
  @override
  final int maxChunk;
  final _in = StreamController<Uint8List>();
  final _closed = Completer<void>();

  _CentralLink(this._pm, this.central, this._tx, this.maxChunk);

  @override
  Stream<Uint8List> get chunks => _in.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> sendChunk(Uint8List chunk) {
    if (_closed.isCompleted) throw StateError('Member gone');
    return _pm.notifyCharacteristic(central, _tx, value: chunk);
  }

  void _gone() {
    if (_closed.isCompleted) return;
    _closed.complete();
    _in.close();
  }

  @override
  Future<void> close() async {
    if (_closed.isCompleted) return;
    _gone();
    try {
      await _pm.disconnect(central);
    } catch (_) {
      // iOS cannot drop a central; it goes when it disconnects.
    }
  }
}

/// Member end: a GATT client link to the hub.
class _GattChunkLink implements ChunkLink {
  final GattLink _link;
  final GattChar _rx;
  final Stream<Uint8List> _stream;
  @override
  final int maxChunk;
  final _closed = Completer<void>();

  _GattChunkLink(this._link, this._rx, this._stream, this.maxChunk) {
    _link.onDisconnected.then((_) {
      if (!_closed.isCompleted) _closed.complete();
    });
  }

  @override
  Stream<Uint8List> get chunks => _stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> sendChunk(Uint8List chunk) =>
      _link.write(_rx, chunk, withResponse: true);

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
    await _link.close();
  }
}
