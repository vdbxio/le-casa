// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Screen sync over real Bluetooth. Every screen in a home runs the Le'Casa
// GATT service with the plugin's PeripheralManager and advertises its home
// tag; other screens find it through the normal scan and connect with a
// GattLink, the same way the app talks to a fridge or a BMS.

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

/// Largest sync chunk, in bytes. It fits one link-layer packet (251 bytes
/// with data length extension, less the L2CAP and ATT headers). The M10's
/// link to an iPhone stalled on a 512-byte write, which the stack splits
/// over several packets, and the disconnect that followed took its
/// Bluetooth down (2026-10-26).
const syncChunkMax = 180;

/// How long a link this screen gave up on may wait for its last write to
/// finish before it is disconnected.
const _settleBeforeDisconnect = Duration(minutes: 2);

/// Disconnects once [inFlight] has settled. A write that never answers
/// means the radio is stuck, and a disconnect sent then timed out on the
/// M10 and crashed its Bluetooth stack. If the write is still stuck after
/// [settle], the link is left for the other screen or the
/// link supervision timeout to drop. Returns whether it disconnected.
@visibleForTesting
Future<bool> disconnectWhenIdle(
  Future<void>? inFlight,
  Future<void> Function() disconnect,
  String what, {
  Duration settle = _settleBeforeDisconnect,
}) async {
  if (inFlight != null) {
    try {
      await inFlight.timeout(settle);
    } on TimeoutException {
      debugPrint('sync: $what still stuck, not disconnecting it');
      return false;
    } catch (_) {
      // Failed rather than stuck: the radio answered, so disconnecting is
      // safe.
    }
  }
  await disconnect();
  return true;
}

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
  Stream<PeerSighting> get sightings =>
      scanner.advertisements.map(sightingOf).where((s) => s != null).cast();

  /// A Le'Casa screen's advert, or null for anything else. Public for tests.
  static PeerSighting? sightingOf(RawAdvertisement a) {
    final m = a.manufacturerData[syncCompanyId];
    if (m != null &&
        m.length >= 11 &&
        m[0] == syncMagic[0] &&
        m[1] == syncMagic[1]) {
      return PeerSighting(
        a.id,
        hex(m.sublist(3, 7), sep: ''),
        a.rssi,
        a.seenAt,
        screen: hex(m.sublist(7, 11), sep: ''),
        adding: m[2] & 1 != 0,
      );
    }
    final name = a.name;
    if (name == null || !name.startsWith(syncNamePrefix)) return null;
    if (!a.longServiceUuids.contains(syncServiceUuid)) return null;
    var rest = name.substring(syncNamePrefix.length).trim().toLowerCase();
    final adding = rest.endsWith('+');
    if (adding) rest = rest.substring(0, rest.length - 1);
    final parts = rest.split('.');
    return PeerSighting(
      a.id,
      parts.first,
      a.rssi,
      a.seenAt,
      screen: parts.length > 1 ? parts[1] : null,
      adding: adding,
    );
  }

  bool _serving = false;

  @override
  Future<void> startServer(PeerAdvert ad) async {
    if (!_serving) await _serve(ad.tag);
    _serving = true;
    final pm = _pm;
    try {
      await pm.stopAdvertising();
    } catch (_) {
      // Was not advertising.
    }
    final apple =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    debugPrint('sync: starting advert');
    await pm
        .startAdvertising(
          // iOS adverts carry only a name and service UUIDs, so everything goes
          // in the name there. On Android a name would rename the tablet's
          // Bluetooth, so it rides in manufacturer data instead, without the
          // 16-byte service UUID: both do not fit in a legacy advert.
          apple
              ? Advertisement(
                  name:
                      '$syncNamePrefix${ad.tag}.${ad.screen}${ad.adding ? '+' : ''}',
                  serviceUUIDs: [UUID.fromString(syncServiceUuid)],
                )
              : Advertisement(
                  manufacturerSpecificData: [
                    ManufacturerSpecificData(
                      id: syncCompanyId,
                      data: Uint8List.fromList([
                        ...syncMagic,
                        ad.adding ? 1 : 0,
                        ...fromHexString(ad.tag),
                        ...fromHexString(ad.screen),
                      ]),
                    ),
                  ],
                ),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw StateError('Starting the advert timed out'),
        );
    debugPrint('sync: advertising ${ad.tag} as ${ad.screen}');
  }

  Future<void> _serve(String tag) async {
    final pm = _pm;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    // Android asks for the advertise and connect permissions here; on iOS
    // the plugin has no authorize() and the system asks by itself.
    // On Android the answer can go missing when the scanner asks for its
    // own permissions at the same moment, and then authorize() never
    // returns; carry on and let the state check below decide.
    try {
      await pm.authorize().timeout(const Duration(seconds: 8));
    } on UnsupportedError {
      // iOS
    } on TimeoutException {
      debugPrint('sync server: no answer to the permission request');
    }
    debugPrint('sync server: Bluetooth is ${pm.state.name}');
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
    _info = Uint8List.fromList(utf8.encode(jsonEncode({'v': 2, 'tag': tag})));
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
          debugPrint('sync server: read reply failed: $err');
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
          debugPrint('sync server: write reply failed: $err');
        }
        if (!link._closed.isCompleted) link._in.add(e.request.value);
      }),
      pm.characteristicNotifyStateChanged.listen((e) async {
        if (e.characteristic.uuid != tx.uuid) return;
        if (e.state) {
          // A new subscription is a new link, even when iOS never told us
          // the last one from this screen went away.
          _links.remove(e.central.uuid.toString())?._gone();
          await _linkFor(e.central);
        } else {
          _links.remove(e.central.uuid.toString())?._gone();
        }
      }),
    ]);
    // Android also says when a screen's link drops; iOS only unsubscribes.
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
    await pm
        .addService(
          GATTService(
            uuid: UUID.fromString(syncServiceUuid),
            isPrimary: true,
            includedServices: [],
            characteristics: [info, rx, tx],
          ),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () =>
              throw StateError('Adding the GATT service timed out'),
        );
    debugPrint('sync server: service added');
  }

  Future<_CentralLink> _linkFor(Central c) async {
    final key = c.uuid.toString();
    // A link this screen gave up on (silent for too long) stays in the map
    // on iOS until the other end unsubscribes, which it may never do; its
    // writes would then go nowhere and the other screen could never link
    // again.
    final existing = _links[key];
    if (existing != null && !existing.isClosed) return existing;
    var max = 20;
    try {
      max = await _pm.getMaximumNotifyLength(c);
    } catch (e) {
      debugPrint('sync server: notify length unknown: $e');
    }
    final again = _links[key];
    if (again != null && !again.isClosed) return again;
    final link = _links[key] = _CentralLink(
      _pm,
      c,
      _tx!,
      max.clamp(20, syncChunkMax),
    );
    debugPrint('sync server: ${c.uuid} linked, chunks of $max');
    _incoming.add(MessageLink(link));
    return link;
  }

  @override
  Future<void> stopServer() async {
    _serving = false;
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
      debugPrint('sync server: stop failed: $e');
    }
  }

  @override
  Future<MessageLink> connect(PeerSighting peer) {
    final c = connections;
    // The connect gives up after 32 s and each step after it has its own
    // limit, so exclusive's 60 s is only a backstop.
    return c == null
        ? _connect(peer)
        : c.exclusive('screen sync', () => _connect(peer));
  }

  Future<MessageLink> _connect(PeerSighting peer) async {
    final p = scanner.peripheralFor(peer.id);
    if (p == null) throw StateError('Screen not heard yet');
    if (_GattChunkLink.lingering.contains(p.uuid.toString())) {
      // Its old link is stuck on a write; dialling again would only add
      // to what the radio is waiting on.
      throw StateError('The last link to that screen has not closed yet');
    }
    // Scanning while connecting is the classic cause of status 133 on
    // cheap tablets; pause it for the connect, as device polls do.
    final wasScanning =
        !(connections?.holdLinks ?? false) &&
        scanner.scanning &&
        await RadioWrites.settle();
    if (wasScanning) await scanner.stop();
    GattLink? link;
    try {
      for (var attempt = 1; ; attempt++) {
        try {
          link = await GattLink.open(scanner.central, p);
          break;
        } catch (e) {
          if (attempt >= 3 || !'$e'.contains('133')) rethrow;
          debugPrint('sync: connect got 133, retry $attempt');
          await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
        }
      }
    } finally {
      if (wasScanning) unawaited(scanner.resume());
    }
    final l = link;
    try {
      final rx = l.require(syncRxUuid, 'sync write');
      final tx = l.require(syncTxUuid, 'sync notify');
      final stream = await l.subscribe(tx);
      final max = await l.maxWriteLength();
      debugPrint('sync: connected to ${peer.id}, chunks of $max');
      return MessageLink(
        _GattChunkLink(l, rx, stream, max.clamp(20, syncChunkMax)),
      );
    } catch (_) {
      await l.close();
      rethrow;
    }
  }
}

/// Server end of a link from a screen that connected to this one.
class _CentralLink implements ChunkLink {
  final PeripheralManager _pm;
  final Central central;
  final GATTCharacteristic _tx;
  @override
  final int maxChunk;
  final _in = StreamController<Uint8List>();
  final _closed = Completer<void>();
  Future<void>? _inFlight;

  _CentralLink(this._pm, this.central, this._tx, this.maxChunk);

  @override
  Stream<Uint8List> get chunks => _in.stream;

  @override
  Future<void> get closed => _closed.future;

  bool get isClosed => _closed.isCompleted;

  @override
  Future<void> sendChunk(Uint8List chunk) {
    if (_closed.isCompleted) throw StateError('Screen gone');
    return _inFlight = RadioWrites.track(
      _pm.notifyCharacteristic(central, _tx, value: chunk),
    );
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
    unawaited(
      disconnectWhenIdle(_inFlight, () async {
        try {
          await _pm.disconnect(central);
        } catch (_) {
          // iOS cannot drop a central; it goes when it disconnects.
        }
      }, 'link from ${central.uuid}'),
    );
  }
}

/// Client end: a GATT link to a screen this one connected to.
class _GattChunkLink implements ChunkLink {
  final GattLink _link;
  final GattChar _rx;
  final Stream<Uint8List> _stream;
  @override
  final int maxChunk;
  final _closed = Completer<void>();
  Future<void>? _inFlight;
  bool _closing = false;

  /// Screens whose old link is still waiting to be disconnected.
  static final Set<String> lingering = {};

  _GattChunkLink(this._link, this._rx, this._stream, this.maxChunk) {
    _link.onDisconnected.then((_) {
      if (!_closed.isCompleted) _closed.complete();
      lingering.remove(_id);
    });
  }

  String get _id => _link.peripheral.uuid.toString();

  @override
  Stream<Uint8List> get chunks => _stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> sendChunk(Uint8List chunk) =>
      _inFlight = _link.write(_rx, chunk, withResponse: true);

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    if (!_closed.isCompleted) _closed.complete();
    if (_link.droppedByDevice) {
      await _link.close();
      return;
    }
    lingering.add(_id);
    unawaited(
      disconnectWhenIdle(_inFlight, _link.close, 'link to $_id').then((done) {
        // Still stuck: it stays lingering until the link drops.
        if (done) lingering.remove(_id);
      }),
    );
  }
}
