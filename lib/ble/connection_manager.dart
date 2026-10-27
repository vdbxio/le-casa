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
import 'dart:convert';

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

/// Another screen in the home that read a device recently and shares it.
class RemoteOwner {
  final String screen;
  final DateTime at;
  final bool controllable;

  /// The owner gives the device up to this screen when this screen can
  /// read it (the owner is a phone, this is a tablet).
  final bool yields;
  const RemoteOwner(
    this.screen,
    this.at, {
    this.controllable = false,
    this.yields = false,
  });
}

/// What screen sync tells the connection manager: who else holds which
/// device, and how to send that screen a command. One connection per
/// device across the whole home.
abstract interface class RemoteLinks {
  /// The screen that read [id] most recently, if its reading is fresh.
  RemoteOwner? ownerOf(String id);

  /// Asks the owning screen to change a setting. Throws with a message for
  /// the user when it cannot.
  Future<void> control(String id, DeviceCommand command);

  /// Why this screen should leave [id] to another screen right now (it is
  /// locked to another one, or another one hears it better), or null when
  /// this screen may read it.
  String? standAside(String id);
}

/// Opens a connected, service-discovered session to a device id, or throws.
/// The real one goes through the scanner and [GattLink]; tests fake it.
typedef SessionOpener = Future<ClosableSession> Function(String id);

SessionOpener scannerOpener(BleScanner scanner, {bool pauseScan = true}) =>
    (id) async {
      final p = scanner.peripheralFor(id);
      if (p == null) throw StateError('Device not seen by the scanner');
      // Scanning and connecting fight over the radio on cheap tablets; a scan
      // left running is the classic cause of GATT status 133 on connect and of
      // links that time out right after they come up. Pause it for the few
      // seconds the link lives.
      final wasScanning =
          pauseScan && scanner.scanning && await RadioWrites.settle();
      if (wasScanning) await scanner.stop();
      try {
        final link = await GattLink.open(scanner.central, p);
        return _ScanPausingSession(link, wasScanning ? scanner : null);
      } catch (_) {
        if (wasScanning) unawaited(scanner.resume());
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
  static const _choiceKey = 'gatt:choice';
  static const _globalKey = 'gatt:enabled';

  /// Do not try to connect to something we have not heard from recently;
  /// it has probably been carried out of range.
  static const staleAfter = Duration(minutes: 3);

  final DeviceTracker tracker;
  final GattDriverRegistry drivers;
  final SessionOpener _open;
  final Map<String, Link> _links = {};

  /// Keep links to [LiveDriver] devices open and read them every few
  /// seconds, instead of reconnecting every [GattDriver.interval]. Only on
  /// screens whose Bluetooth runs several links at once (iOS, macOS); the
  /// M10 cannot even hold one.
  final bool holdLinks;

  /// Open links kept for [holdLinks], by device id.
  final Map<String, ClosableSession> _held = {};

  /// Connect only to devices the person turned on. Otherwise every device
  /// a driver recognises is read, which at a campground full of other
  /// people's batteries and fridges means connecting to all of them (and
  /// taking the one connection most allow from their owners' apps).
  final bool optIn;

  /// The person's choice per device: true to connect, false not to.
  final Map<String, bool> _choice = {};

  /// Told when the person turns a device on or off here, so the other
  /// screens in the home can follow.
  void Function(String id, bool on)? onChoice;
  SharedPreferences? _prefs;
  Timer? _tick;
  bool _enabled = true;
  String? _busy;
  DateTime? _busySince;

  /// Bumped each time something takes the radio, so a call that comes back
  /// after [stuckAfter] does not free the radio for whoever has it now.
  int _turn = 0;

  /// Nothing legitimate holds the radio this long (a connect gives up after
  /// 32 s and a read after its driver's timeout). Past it, the radio is
  /// taken back: a platform call that never returns must not stop every
  /// device being read.
  @visibleForTesting
  Duration stuckAfter = const Duration(minutes: 2);

  /// Screen sync, once it is running.
  RemoteLinks? remote;

  ConnectionManager(
    this.tracker, {
    required SessionOpener open,
    GattDriverRegistry? drivers,
    Duration tick = const Duration(seconds: 1),
    this.holdLinks = false,
    this.optIn = false,
  }) : drivers = drivers ?? GattDriverRegistry.standard(),
       // ignore: prefer_initializing_formals
       _open = open {
    _tick = Timer.periodic(tick, (_) => pump());
  }

  ConnectionManager.forScanner(
    BleScanner scanner,
    DeviceTracker tracker, {
    GattDriverRegistry? drivers,
    bool holdLinks = false,
    bool optIn = false,
  }) : this(
         tracker,
         // A held link would keep the scan paused for good; screens that
         // hold links scan and connect at once without trouble.
         open: scannerOpener(scanner, pauseScan: !holdLinks),
         drivers: drivers,
         holdLinks: holdLinks,
         optIn: optIn,
       );

  /// Whether this screen keeps a link to [id] open and reads it live.
  bool isLive(String id) => _held.containsKey(id);

  /// Whether the person lets this screen connect to [id].
  bool allows(String id) => _choice[id] ?? !optIn;

  /// Whether the person has said either way for [id].
  bool hasChoice(String id) => _choice.containsKey(id);

  /// Global switch: when off, nothing connects to anything.
  bool get enabled => _enabled;

  /// Id of the device we are connected to right now, if any.
  String? get busyId => _busy;

  int _take(String what) {
    _busy = what;
    _busySince = DateTime.now();
    return ++_turn;
  }

  void _giveBack(int turn) {
    if (turn != _turn) return;
    _busy = null;
    _busySince = null;
  }

  /// Takes the radio back from a holder that has been stuck too long.
  bool _free() {
    final since = _busySince;
    if (_busy == null) return true;
    if (since == null || DateTime.now().difference(since) < stuckAfter) {
      return false;
    }
    debugPrint('radio: $_busy held it since $since, taking it back');
    final l = _links[_busy];
    if (l != null && l.busy) {
      l
        ..phase = LinkPhase.failed
        ..error = 'Bluetooth did not answer';
    }
    _turn++;
    _busy = null;
    _busySince = null;
    return true;
  }

  List<Link> get links => _links.values.toList();

  Link? operator [](String id) => _links[id];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(_prefs!.getString(_choiceKey) ?? '{}') as Map;
      for (final e in saved.entries) {
        if (e.value is bool) _choice['${e.key}'] = e.value as bool;
      }
    } catch (_) {}
    // Before the choice map there was only a list of devices turned off.
    for (final id in _prefs!.getStringList(_disabledKey) ?? const <String>[]) {
      _choice.putIfAbsent(id, () => false);
    }
    _enabled = _prefs!.getBool(_globalKey) ?? true;
    for (final l in _links.values) {
      if (!allows(l.id) && !l.busy) l.phase = LinkPhase.off;
      if (allows(l.id) && l.phase == LinkPhase.off) {
        l
          ..phase = LinkPhase.scheduled
          ..nextDue = DateTime.now();
      }
    }
    notifyListeners();
  }

  Future<void> _saveChoices() async {
    await _prefs?.setString(_choiceKey, jsonEncode(_choice));
    await _prefs?.remove(_disabledKey);
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    if (!v) await _releaseAll();
    await _prefs?.setBool(_globalKey, v);
    notifyListeners();
  }

  /// Per-device on/off, remembered across restarts. [quiet] for a choice
  /// that came from another screen, so it is not sent back.
  Future<void> setDeviceEnabled(String id, bool v, {bool quiet = false}) async {
    final l = _links[id];
    final changed = _choice[id] != v;
    _choice[id] = v;
    if (v) {
      if (l != null && l.phase == LinkPhase.off) {
        l
          ..phase = LinkPhase.scheduled
          ..failures = 0
          ..nextDue = DateTime.now();
      }
    } else {
      await _release(id);
      if (l != null && !l.busy) l.phase = LinkPhase.off;
    }
    await _saveChoices();
    if (changed && !quiet) onChoice?.call(id, v);
    notifyListeners();
  }

  /// Puts a device at the front of the queue. Returns when the poll that
  /// it triggered has finished, or at once if one is already running (the
  /// device then goes next).
  Future<void> readNow(String id) {
    final l = _links[id];
    if (l == null || l.phase == LinkPhase.unsupported) return Future.value();
    // Asking for a read is saying yes to connecting.
    if (!allows(id)) unawaited(setDeviceEnabled(id, true));
    if (!l.busy) {
      l
        ..phase = LinkPhase.scheduled
        ..failures = 0
        ..nextDue = DateTime.now();
    }
    notifyListeners();
    return pump();
  }

  /// Whether [id] has a driver that can change its settings, here or on
  /// the screen that holds its connection.
  bool canControl(String id) =>
      _links[id]?.driver is ControllableDriver ||
      (remote?.ownerOf(id)?.controllable ?? false);

  /// The other screen that holds [id]'s connection, when it has a newer
  /// reading than this one. This screen then leaves the device alone: most
  /// take one connection at a time.
  RemoteOwner? heldElsewhere(String id) {
    final o = remote?.ownerOf(id);
    if (o == null || (o.yields && _links.containsKey(id))) return null;
    final ok = _links[id]?.lastOk;
    return ok == null || o.at.isAfter(ok) ? o : null;
  }

  /// Changes a setting on the device: waits for the radio, connects, sends
  /// [command] and stores the state read back. When another screen holds
  /// the device, the command goes to that screen instead, unless [here]
  /// (a command that already came from another screen). Throws with a
  /// message for the user when it cannot.
  Future<void> control(
    String id,
    DeviceCommand command, {
    bool here = false,
  }) async {
    final r = remote;
    if (!here &&
        r != null &&
        (heldElsewhere(id) != null || r.standAside(id) != null)) {
      return r.control(id, command);
    }
    final l = _links[id];
    final driver = l?.driver;
    if (l == null || driver is! ControllableDriver) {
      throw StateError('This device cannot be controlled');
    }
    if (!_enabled) throw StateError('Connections are paused');
    // Asking for a change is saying yes to connecting. A command from
    // another screen does not decide for this one.
    if (!l.enabled) {
      if (here) throw StateError('Turn on "Connect to this device" first');
      await setDeviceEnabled(id, true);
    }
    final until = DateTime.now().add(const Duration(seconds: 60));
    while (!_free()) {
      if (DateTime.now().isAfter(until)) {
        throw TimeoutException('Bluetooth is busy with another device');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final dev = tracker[id];
    if (dev == null) throw StateError('Device gone');
    // Most devices take one connection: drop the live one for the command.
    await _release(id);
    final turn = _take(id);
    l
      ..phase = LinkPhase.connecting
      ..lastAttempt = DateTime.now()
      ..error = null;
    debugPrint('control: $id $command');
    notifyListeners();
    ClosableSession? link;
    try {
      link = await _open(id);
      l.phase = LinkPhase.reading;
      notifyListeners();
      final decoded = await driver
          .control(link, dev.lastRecognised ?? dev.latest, command)
          .timeout(driver.timeout);
      tracker.setPolled(id, decoded);
      l
        ..phase = LinkPhase.ok
        ..failures = 0
        ..drops = 0
        ..lastOk = DateTime.now()
        ..nextDue = DateTime.now().add(driver.interval);
    } catch (e) {
      debugPrint('control: $id failed: $e');
      l
        ..phase = LinkPhase.failed
        ..error = _describe(e)
        ..nextDue = DateTime.now().add(driver.interval);
      rethrow;
    } finally {
      await link?.close();
      _giveBack(turn);
      notifyListeners();
    }
  }

  /// Runs [f] with the radio to itself: waits for any poll in flight, and
  /// no poll starts until [f] returns. Cheap tablets (the M10) fail every
  /// connect with status 133 when two are attempted at once. Gives the
  /// radio back after [limit] even if [f] is stuck, so one platform call
  /// that never returns cannot stop every poll for good.
  Future<T> exclusive<T>(
    String what,
    Future<T> Function() f, {
    Duration limit = const Duration(seconds: 60),
  }) async {
    final until = DateTime.now().add(const Duration(seconds: 60));
    while (!_free()) {
      if (DateTime.now().isAfter(until)) {
        throw TimeoutException('Bluetooth is busy with another device');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final turn = _take(what);
    notifyListeners();
    try {
      return await f().timeout(limit);
    } finally {
      _giveBack(turn);
      notifyListeners();
    }
  }

  /// Called for every advertisement: the first one from a device a driver
  /// recognises schedules it.
  void onAdvertisement(RawAdvertisement adv) {
    if (_links.containsKey(adv.id)) return;
    final driver = drivers.forAdvertisement(adv);
    if (driver == null) return;
    _links[adv.id] = Link(adv.id, driver, enabled: allows(adv.id));
    notifyListeners();
  }

  /// Starts the most overdue poll if nothing is in flight, and reads held
  /// links that are due. Runs on a timer; public so tests can drive it.
  /// Returns when what it started has finished.
  Future<void> pump() {
    final live = _pumpLive();
    if (!_enabled || !_free()) return live;
    final now = DateTime.now();
    Link? pick;
    for (final l in _links.values) {
      if (_held.containsKey(l.id)) continue;
      if (!l.enabled || l.busy || l.nextDue.isAfter(now)) continue;
      if (heldElsewhere(l.id) != null) continue;
      if (remote?.standAside(l.id) != null) continue;
      final dev = tracker[l.id];
      if (dev == null || now.difference(dev.lastSeen) > staleAfter) continue;
      // Its broadcasts already carry the readings (a stock Xiaomi with its
      // bindkey entered): no need to connect.
      if (dev.decoded?.isReadable ?? false) continue;
      if (pick == null || l.nextDue.isBefore(pick.nextDue)) pick = l;
    }
    return pick == null ? live : Future.wait([live, _poll(pick)]);
  }

  /// Reads the held links that are due, and lets go of the ones this
  /// screen should no longer read.
  Future<void> _pumpLive() {
    if (_held.isEmpty) return Future.value();
    final now = DateTime.now();
    final work = <Future<void>>[];
    for (final id in _held.keys.toList()) {
      final l = _links[id];
      if (l == null ||
          !_enabled ||
          !l.enabled ||
          heldElsewhere(id) != null ||
          remote?.standAside(id) != null) {
        work.add(_release(id));
      } else if (_busy == null &&
          !_liveReading.contains(id) &&
          !l.nextDue.isAfter(now)) {
        // Wait while another device connects: on the iPad a weak Xiaomi
        // timed out connecting while the Daly was asked every few seconds.
        work.add(_readLive(l, _held[id]!));
      }
    }
    return Future.wait(work);
  }

  final Set<String> _liveReading = {};

  Future<void> _readLive(Link l, ClosableSession link) async {
    final dev = tracker[l.id];
    if (dev == null) return _release(l.id);
    _liveReading.add(l.id);
    try {
      final decoded = await l.driver
          .read(link, dev.lastRecognised ?? dev.latest)
          .timeout(l.driver.timeout);
      if (_held[l.id] != link) return;
      tracker.setPolled(l.id, decoded);
      l
        ..phase = LinkPhase.ok
        ..error = null
        ..lastOk = DateTime.now()
        ..nextDue = DateTime.now().add((l.driver as LiveDriver).liveInterval);
    } catch (e) {
      // Reconnect at once; a failure there backs off as usual.
      debugPrint('live: ${l.id} failed: $e');
      await _release(l.id);
    } finally {
      _liveReading.remove(l.id);
      notifyListeners();
    }
  }

  /// Keeps [link] open to read [l] live, if this screen does that.
  bool _hold(Link l, ClosableSession link) {
    final d = l.driver;
    if (!holdLinks || d is! LiveDriver) return false;
    _held[l.id] = link;
    l.nextDue = DateTime.now().add(d.liveInterval);
    debugPrint('live: holding ${l.id} (${d.name})');
    unawaited(
      link.onDisconnected.then((_) {
        if (_held[l.id] != link) return;
        debugPrint('live: ${l.id} dropped the link');
        _held.remove(l.id);
        l.nextDue = DateTime.now();
        notifyListeners();
      }),
    );
    return true;
  }

  /// Closes the held link to [id], if any.
  Future<void> _release(String id) async {
    final link = _held.remove(id);
    if (link == null) return;
    debugPrint('live: letting go of $id');
    _links[id]?.nextDue = DateTime.now();
    await link.close();
    notifyListeners();
  }

  Future<void> _releaseAll() async {
    for (final id in _held.keys.toList()) {
      await _release(id);
    }
  }

  Future<void> _poll(Link l) async {
    final dev = tracker[l.id];
    if (dev == null) return;
    final turn = _take(l.id);
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
      if (turn == _turn && _hold(l, link)) link = null;
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
      if (turn == _turn) {
        _fail(l, dropped ? 'The device dropped the connection' : _describe(e));
      }
    } finally {
      await link?.close();
      _giveBack(turn);
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

  bool _disposed = false;

  @override
  void notifyListeners() {
    // Choices from other screens and polls finish after the app has gone.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    for (final link in _held.values) {
      unawaited(link.close());
    }
    _held.clear();
    super.dispose();
  }
}
