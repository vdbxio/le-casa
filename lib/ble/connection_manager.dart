// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Polls devices that only talk over a connection. One link at a time: a
// Daly module or a Xiaomi sensor accepts a single central, and this tablet
// is meant to be the one that owns it, so we connect, read, disconnect and
// leave the device free in between. Readings land on the TrackedDevice next
// to the broadcast ones.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../decoders/raw_advertisement.dart';
import '../drivers/driver.dart';
import 'ble_scanner.dart';
import 'device_tracker.dart';
import 'gatt_link.dart';
import 'gatt_session.dart';

enum LinkPhase {
  /// Waiting for its next slot.
  scheduled,
  connecting,
  reading,

  /// Last poll succeeded; waiting for the next one.
  ok,

  /// Last poll failed; will retry with backoff.
  failed,

  /// Turned off for this device by the user.
  off,

  /// The device does not expose what the driver needs. Not retried.
  unsupported,
}

/// Polling state for one device.
class Link {
  final String id;
  final GattDriver driver;
  LinkPhase phase = LinkPhase.scheduled;
  DateTime nextDue;
  DateTime? lastOk;
  DateTime? lastAttempt;
  String? error;
  int failures = 0;

  /// Polls since the last good read where the link came up and then the
  /// device dropped it before the read finished.
  int drops = 0;

  Link(this.id, this.driver, {bool enabled = true})
    : nextDue = DateTime.now(),
      phase = enabled ? LinkPhase.scheduled : LinkPhase.off;

  bool get busy => phase == LinkPhase.connecting || phase == LinkPhase.reading;

  bool get enabled => phase != LinkPhase.off && phase != LinkPhase.unsupported;

  /// This device keeps cutting the link a few seconds after connecting. Seen
  /// with a Daly module and the PRITOM M10 tablet: the module asks for new
  /// link parameters and the tablet's radio loses the link four seconds
  /// later, whatever the app does. Nothing to fix in the app, so tell the
  /// user instead of retrying in silence.
  bool get keepsDropping => drops >= dropsToWarn;

  static const dropsToWarn = 3;

  String get statusText => switch (phase) {
    LinkPhase.scheduled => 'Waiting to connect',
    LinkPhase.connecting => 'Connecting…',
    LinkPhase.reading => 'Reading…',
    LinkPhase.ok => 'Read ok',
    LinkPhase.failed => 'Failed: $error',
    LinkPhase.off => 'Off',
    LinkPhase.unsupported => 'Not supported: $error',
  };
}

/// Opens a connected, service-discovered session to a device id, or throws.
/// The real one goes through the scanner and [GattLink]; tests fake it.
typedef SessionOpener = Future<ClosableSession> Function(String id);

SessionOpener scannerOpener(BleScanner scanner) => (id) async {
  final p = scanner.peripheralFor(id);
  if (p == null) throw StateError('Device not seen by the scanner');
  // Scanning and connecting fight over the radio on cheap tablets; a scan
  // left running is the classic cause of GATT status 133 on connect and of
  // links that time out right after they come up. Pause it for the few
  // seconds the link lives.
  final wasScanning = scanner.scanning;
  if (wasScanning) await scanner.stop();
  try {
    final link = await GattLink.open(scanner.central, p);
    return _ScanPausingSession(link, wasScanning ? scanner : null);
  } catch (_) {
    if (wasScanning) unawaited(scanner.start());
    rethrow;
  }
};

/// Restarts the scan when the link closes.
class _ScanPausingSession implements ClosableSession {
  final GattLink _link;
  final BleScanner? _resume;
  _ScanPausingSession(this._link, this._resume);

  @override
  List<GattChar> get characteristics => _link.characteristics;
  @override
  Future<Uint8List> read(GattChar c) => _link.read(c);
  @override
  Future<void> write(GattChar c, Uint8List data, {bool withResponse = true}) =>
      _link.write(c, data, withResponse: withResponse);
  @override
  Future<Stream<Uint8List>> subscribe(GattChar c) => _link.subscribe(c);
  @override
  bool get droppedByDevice => _link.droppedByDevice;
  @override
  Future<void> get onDisconnected => _link.onDisconnected;
  @override
  Future<void> close() async {
    await _link.close();
    final r = _resume;
    if (r != null) {
      try {
        await r.start();
      } catch (e) {
        debugPrint('poll: could not restart scanning: $e');
      }
    }
  }
}

class ConnectionManager extends ChangeNotifier {
  static const _disabledKey = 'gatt:disabled';
  static const _globalKey = 'gatt:enabled';

  /// Do not try to connect to something we have not heard from recently;
  /// it has probably been carried out of range.
  static const staleAfter = Duration(minutes: 3);

  final DeviceTracker tracker;
  final GattDriverRegistry drivers;
  final SessionOpener _open;
  final Map<String, Link> _links = {};
  final Set<String> _disabled = {};
  SharedPreferences? _prefs;
  Timer? _tick;
  bool _enabled = true;
  String? _busy;

  ConnectionManager(
    this.tracker, {
    required SessionOpener open,
    GattDriverRegistry? drivers,
    Duration tick = const Duration(seconds: 1),
  }) : drivers = drivers ?? GattDriverRegistry.standard(),
       // ignore: prefer_initializing_formals
       _open = open {
    _tick = Timer.periodic(tick, (_) => pump());
  }

  ConnectionManager.forScanner(
    BleScanner scanner,
    DeviceTracker tracker, {
    GattDriverRegistry? drivers,
  }) : this(tracker, open: scannerOpener(scanner), drivers: drivers);

  /// Global switch: when off, nothing connects to anything.
  bool get enabled => _enabled;

  /// Id of the device we are connected to right now, if any.
  String? get busyId => _busy;

  List<Link> get links => _links.values.toList();

  Link? operator [](String id) => _links[id];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _disabled.addAll(_prefs!.getStringList(_disabledKey) ?? const []);
    _enabled = _prefs!.getBool(_globalKey) ?? true;
    for (final l in _links.values) {
      if (_disabled.contains(l.id) && !l.busy) l.phase = LinkPhase.off;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await _prefs?.setBool(_globalKey, v);
    notifyListeners();
  }

  /// Per-device on/off, remembered across restarts.
  Future<void> setDeviceEnabled(String id, bool v) async {
    final l = _links[id];
    if (v) {
      _disabled.remove(id);
      if (l != null && l.phase == LinkPhase.off) {
        l
          ..phase = LinkPhase.scheduled
          ..failures = 0
          ..nextDue = DateTime.now();
      }
    } else {
      _disabled.add(id);
      if (l != null && !l.busy) l.phase = LinkPhase.off;
    }
    await _prefs?.setStringList(_disabledKey, _disabled.toList());
    notifyListeners();
  }

  /// Puts a device at the front of the queue. Returns when the poll that
  /// it triggered has finished, or at once if one is already running (the
  /// device then goes next).
  Future<void> readNow(String id) {
    final l = _links[id];
    if (l == null || l.phase == LinkPhase.unsupported) return Future.value();
    if (l.phase == LinkPhase.off) {
      _disabled.remove(id);
      _prefs?.setStringList(_disabledKey, _disabled.toList());
    }
    if (!l.busy) {
      l
        ..phase = LinkPhase.scheduled
        ..failures = 0
        ..nextDue = DateTime.now();
    }
    notifyListeners();
    return pump();
  }

  /// Called for every advertisement: the first one from a device a driver
  /// recognises schedules it.
  void onAdvertisement(RawAdvertisement adv) {
    if (_links.containsKey(adv.id)) return;
    final driver = drivers.forAdvertisement(adv);
    if (driver == null) return;
    _links[adv.id] = Link(adv.id, driver, enabled: !_disabled.contains(adv.id));
    notifyListeners();
  }

  /// Starts the most overdue poll if nothing is in flight. Runs on a timer;
  /// public so tests can drive it. Returns when that poll has finished.
  Future<void> pump() {
    if (!_enabled || _busy != null) return Future.value();
    final now = DateTime.now();
    Link? pick;
    for (final l in _links.values) {
      if (!l.enabled || l.busy || l.nextDue.isAfter(now)) continue;
      final dev = tracker[l.id];
      if (dev == null || now.difference(dev.lastSeen) > staleAfter) continue;
      if (pick == null || l.nextDue.isBefore(pick.nextDue)) pick = l;
    }
    return pick == null ? Future.value() : _poll(pick);
  }

  Future<void> _poll(Link l) async {
    final dev = tracker[l.id];
    if (dev == null) return;
    _busy = l.id;
    l
      ..phase = LinkPhase.connecting
      ..lastAttempt = DateTime.now()
      ..error = null;
    debugPrint('poll: ${l.id} (${l.driver.name}) connecting');
    notifyListeners();
    ClosableSession? link;
    try {
      link = await _open(l.id);
      l.phase = LinkPhase.reading;
      notifyListeners();
      final decoded = await l.driver
          .read(link, dev.lastRecognised ?? dev.latest)
          .timeout(l.driver.timeout);
      debugPrint('poll: ${l.id} ok: ${decoded.readings.take(4).join(', ')}');
      tracker.setPolled(l.id, decoded);
      l
        ..phase = LinkPhase.ok
        ..failures = 0
        ..drops = 0
        ..lastOk = DateTime.now()
        ..nextDue = DateTime.now().add(l.driver.interval);
    } on UnsupportedDeviceException catch (e) {
      debugPrint('poll: ${l.id} unsupported: ${e.message}');
      l
        ..phase = LinkPhase.unsupported
        ..error = e.message;
    } catch (e) {
      debugPrint('poll: ${l.id} failed: $e');
      final dropped = await _dropped(link, e);
      // Only a good read clears the count: on the M10 every other try at
      // the Daly fails while connecting, between the drops.
      if (dropped) l.drops++;
      _fail(l, dropped ? 'The device dropped the connection' : _describe(e));
    } finally {
      await link?.close();
      _busy = null;
      notifyListeners();
    }
  }

  /// Whether [e] came from the link going down under us. Android fails the
  /// pending request (often "status: 133") before it reports the
  /// disconnect, so give that event a moment to arrive. A status 8 can also
  /// come while connecting, before there is a [link].
  static Future<bool> _dropped(ClosableSession? link, Object e) async {
    if (RegExp(r'status: 8\b|is disconnected').hasMatch('$e')) return true;
    if (link == null) return false;
    if (!link.droppedByDevice) {
      await link.onDisconnected.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    return link.droppedByDevice;
  }

  void _fail(Link l, String error) {
    l.failures++;
    // Back off: interval, 2x, 4x... capped at ten minutes, so a device
    // that is being used by another app does not get hammered.
    final base = l.driver.interval.inSeconds;
    final wait = (base * (1 << (l.failures - 1).clamp(0, 6))).clamp(base, 600);
    l
      ..phase = LinkPhase.failed
      ..error = error
      ..nextDue = DateTime.now().add(Duration(seconds: wait));
    notifyListeners();
  }

  static String _describe(Object e) {
    if (e is TimeoutException) {
      return e.message ?? 'Timed out';
    }
    final s = e.toString();
    // Platform exceptions read like "PlatformException(code, message, ...)".
    final m = RegExp(r'PlatformException\([^,]*, ([^,]*)').firstMatch(s);
    return m?.group(1) ?? s;
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}
