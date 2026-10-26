// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Screen sync: tablets and phones in one home share what they read and
// the keys they know, over Bluetooth only. The screens form a mesh: each
// one runs a Le'Casa GATT server, advertises the home, and links to the
// other screens it hears. Messages hop from screen to screen, so a tablet
// at one end of the van can pass along what a tablet at the other end
// reads. None is in charge; any of them can leave.
//
// Every screen reads the adverts it hears. A device read over a connection
// (a fridge, a BMS) is read by one screen at a time: the one it is locked
// to, or else whichever screen hears it best and reads it, and the others
// show what that screen shares. Controls travel to that screen.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/connection_manager.dart';
import '../ble/device_tracker.dart';
import '../decoders/raw_advertisement.dart';
import '../drivers/driver.dart';
import '../keys/key_store.dart';
import 'crypto.dart';
import 'framing.dart';
import 'home.dart';
import 'radio.dart';
import 'read_by.dart';
import 'session.dart';
import 'wire.dart';

/// A pairing code waiting for the person to compare it.
class PairPrompt {
  final String code;
  final ScreenId peer;
  final Completer<bool> _answer = Completer();
  PairPrompt(this.code, this.peer);
}

/// A device a screen hears and could read over a connection.
class HeardDevice {
  final String id;
  final String? name;
  final String? mac;
  final String? fp;
  final int rssi;
  const HeardDevice(this.id, this.rssi, {this.name, this.mac, this.fp});

  Map<String, Object?> toJson() => {
    'id': id,
    'name': ?name,
    'mac': ?mac,
    'fp': ?fp,
    'r': rssi,
  };

  static HeardDevice fromJson(Map<String, Object?> j) => HeardDevice(
    '${j['id']}',
    (j['r'] as num?)?.toInt() ?? -127,
    name: j['name'] as String?,
    mac: j['mac'] as String?,
    fp: j['fp'] as String?,
  );
}

/// Another screen in the home, from the beacon it sends every few seconds.
class PeerInfo {
  final ScreenId screen;
  final bool phone;

  /// When its latest beacon reached this screen.
  final DateTime heard;
  final int seq;

  /// Connected devices it hears, with their signal.
  final List<HeardDevice> hears;

  /// Other screens it hears, by [shortScreen], with their signal.
  final Map<String, int> sees;

  /// Screens it has a link to.
  final List<String> links;
  final Map<String, Object?> _raw;

  PeerInfo._(
    this.screen,
    this.phone,
    this.heard,
    this.seq,
    this.hears,
    this.sees,
    this.links,
    this._raw,
  );

  static PeerInfo fromJson(Map<String, Object?> j, DateTime now) => PeerInfo._(
    ScreenId('${j['o']}', '${j['n'] ?? 'Screen'}'),
    j['ph'] == true,
    now,
    (j['q'] as num).toInt(),
    [
      for (final d in (j['d'] as List? ?? const []))
        HeardDevice.fromJson((d as Map).cast()),
    ],
    {
      for (final e in ((j['s'] as Map?) ?? const {}).entries)
        '${e.key}': (e.value as num).toInt(),
    },
    [for (final l in (j['l'] as List? ?? const [])) '$l'],
    j,
  );
}

/// One screen hearing another, for working out where a phone is.
typedef Hearing = ({ScreenId by, int rssi});

class SyncService extends ChangeNotifier implements RemoteLinks {
  final HomeStore home;
  final DeviceTracker tracker;
  final KeyStore keys;
  final ConnectionManager connections;
  final SyncRadio radio;
  final ReadByStore readBy;

  SyncService({
    required this.home,
    required this.tracker,
    required this.keys,
    required this.connections,
    required this.radio,
    ReadByStore? readBy,
  }) : readBy = readBy ?? ReadByStore();

  /// Links to other screens, at most [maxLinks]; beyond that, messages
  /// reach the rest through the screens in between.
  static const maxLinks = 4;

  /// A screen whose beacon has not arrived for this long has gone.
  static const _peerGone = Duration(seconds: 45);

  /// How long a screen that hears a device less well leaves it to one that
  /// hears it better, before reading it itself after all.
  @visibleForTesting
  Duration handoverGrace = const Duration(seconds: 90);

  /// How long a screen waits after linking up before it reads connected
  /// devices, so it learns which ones another screen already reads.
  @visibleForTesting
  Duration settleTime = const Duration(seconds: 10);

  /// How long the screen with the larger id waits for the other to dial.
  @visibleForTesting
  Duration dialWait = const Duration(seconds: 15);

  /// A link with no message for this long is dropped and dialled again.
  @visibleForTesting
  Duration linkSilence = const Duration(seconds: 40);

  /// Wait before trying to start the server again; doubles each time.
  @visibleForTesting
  Duration serverRetry = const Duration(seconds: 15);

  final Map<String, _Link> _links = {};
  StreamSubscription? _incoming;
  bool _serverUp = false;
  bool _serverStarting = false;
  DateTime _nextServerTry = DateTime.now();
  Duration _serverWait = Duration.zero;

  /// Why other screens cannot connect to this one, when they cannot. It
  /// still connects to them.
  String? serverError;

  /// Until when this screen takes new screens.
  DateTime? addingUntil;

  bool connecting = false;
  final Map<String, DateTime> _backoff = {};
  final Map<String, DateTime> _firstHeard = {};
  DateTime? _linkedSince;

  /// Le'Casa screens heard lately, by scanner id.
  final Map<String, PeerSighting> nearby = {};

  final Map<String, PeerInfo> _peers = {};

  /// Last thing that went wrong, for the settings page.
  String? error;

  /// Set while a pairing code is on screen.
  PairPrompt? prompt;
  bool joining = false;

  final Map<String, SharedReading> _shared = {};
  final Map<String, String> _ownerSlotOf = {};
  final Map<String, DateTime> _sentAt = {};
  final Map<String, Completer<String?>> _pending = {};
  final Map<String, (SyncSession, DateTime)> _routes = {};
  final Map<String, DateTime> _seenReq = {};
  final Map<String, DateTime> _unowned = {};
  int _keysSent = 0;
  int _readBySent = 0;
  bool _applying = false;
  Timer? _tick;
  int _ticks = 0;
  StreamSubscription? _sightingSub;

  bool get connected => _links.isNotEmpty;

  /// Screens this one has a link to.
  List<ScreenId> get linked => [for (final l in _links.values) l.s.peer];

  /// Every screen in the home heard from lately, this one first.
  List<ScreenId> get screens {
    final now = DateTime.now();
    final out = [
      home.me,
      for (final p in _peers.values)
        if (now.difference(p.heard) < _peerGone) p.screen,
    ];
    for (final l in _links.values) {
      if (!out.contains(l.s.peer)) out.add(l.s.peer);
    }
    return out;
  }

  PeerInfo? peer(String id) => _peers[id];

  bool get adding =>
      addingUntil != null && DateTime.now().isBefore(addingUntil!);

  void start() {
    _sightingSub = radio.sightings.listen(_onSighting);
    keys.addListener(_onKeys);
    readBy.addListener(_onReadBy);
    _keysSent = _maxAt(keys.records.map((r) => r.at));
    _readBySent = _maxAt(readBy.records.map((r) => r.at));
    connections.remote = this;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    unawaited(_applyHome());
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    // Links close and answers arrive after the page or app has gone.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _sightingSub?.cancel();
    keys.removeListener(_onKeys);
    readBy.removeListener(_onReadBy);
    unawaited(_shutdown());
    super.dispose();
  }

  // ---- what the settings and device pages call ----------------------------

  Future<void> startHome(String name) async {
    await home.startHome(name);
    await _applyHome();
  }

  /// Lets new screens pair with this one for a few minutes.
  void startAdding() {
    addingUntil = DateTime.now().add(const Duration(minutes: 3));
    unawaited(_advertise());
    notifyListeners();
  }

  void stopAdding() {
    addingUntil = null;
    prompt?._answer.complete(false);
    unawaited(_advertise());
    notifyListeners();
  }

  /// Pairs with a screen that is adding; the code shows up in [prompt].
  Future<void> join(PeerSighting peer) async {
    if (joining) return;
    joining = true;
    error = null;
    notifyListeners();
    MessageLink? link;
    try {
      link = await radio.connect(peer);
      final joined = await SyncSession.pair(link, home.me, _confirm);
      await home.joined(joined);
      await _applyHome();
    } on SyncRefused catch (e) {
      error = e.message == 'Cancelled' ? null : e.message;
    } catch (e) {
      error = 'Could not reach that screen: $e';
    } finally {
      await link?.close();
      joining = false;
      notifyListeners();
    }
  }

  /// The person's answer to [prompt].
  void answer(bool match) {
    final p = prompt;
    if (p != null && !p._answer.isCompleted) p._answer.complete(match);
  }

  Future<void> leave() async {
    await _shutdown();
    await home.leave();
    _peers.clear();
    notifyListeners();
  }

  /// Locks [id] to [screen], or with null lets the screens sort it out.
  Future<void> lock(String id, ScreenId? screen) {
    final d = tracker[id];
    return readBy.set(
      id,
      screen: screen?.id,
      screenName: screen?.name,
      name: d?.latest.name,
      mac: d?.latest.macString,
      fp: _fp(id),
    );
  }

  /// The screens that hear [screenId], loudest first: where it is.
  List<Hearing> heardBy(String screenId) {
    final short = shortScreen(screenId);
    final now = DateTime.now();
    final out = <Hearing>[
      if (_heardScreens()[short] case final rssi?) (by: home.me, rssi: rssi),
      for (final p in _peers.values)
        if (now.difference(p.heard) < _peerGone && p.sees[short] != null)
          (by: p.screen, rssi: p.sees[short]!),
    ];
    return out..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// Screens of this home this screen hears, by [shortScreen]. A phone
  /// changes its Bluetooth address now and then, so one screen can sit in
  /// [nearby] under two ids for a while; the newest sighting counts.
  Map<String, int> _heardScreens() {
    final newest = <String, PeerSighting>{};
    for (final h in nearby.values) {
      final s = h.screen;
      if (h.tag != home.tag || s == null) continue;
      final old = newest[s];
      if (old == null || h.seen.isAfter(old.seen)) newest[s] = h;
    }
    return {for (final e in newest.entries) e.key: e.value.rssi};
  }

  // ---- RemoteLinks --------------------------------------------------------

  @override
  RemoteOwner? ownerOf(String id) {
    final r = _shared[_ownerSlotOf[id]];
    if (r == null || !r.freshAt(DateTime.now())) return null;
    return RemoteOwner(
      r.ownerName,
      r.at,
      controllable: r.controllable,
      // A phone only reads a device until a tablet that hears it takes
      // over; it may have got there first while the screens were linking.
      yields: !home.phone && (_peers[r.ownerId]?.phone ?? false),
    );
  }

  @override
  String? standAside(String id) {
    if (!home.inHome) return null;
    final lock = readBy.lockOf(id);
    if (lock != null) {
      if (lock.screen == home.me.id) return null;
      return 'Locked to ${_nameOf(lock.screen!, lock.screenName)}';
    }
    if (!connected) return null;
    final now = DateTime.now();
    final since = _linkedSince;
    if (since != null && now.difference(since) < settleTime) {
      return 'Checking with your other screens first';
    }
    final rivals = _hearersOf(id);
    if (rivals.isEmpty) return null;
    final best = rivals.first;
    if (home.phone) {
      return '${best.by.name} reads it. Phones only read devices locked '
          'to them';
    }
    final mine = tracker[id]?.latest.rssi;
    if (mine == null || best.rssi <= mine + 6) return null;
    // Give the screen that hears it better the first go; if it does not
    // read it in time (its Bluetooth may not get along with this device),
    // read it here after all.
    final waiting = _unowned.putIfAbsent(id, () => now);
    if (now.difference(waiting) < handoverGrace) {
      return '${best.by.name} hears it better';
    }
    return null;
  }

  @override
  Future<void> control(String id, DeviceCommand command) async {
    final lock = readBy.lockOf(id);
    final r = _shared[_ownerSlotOf[id]];
    final String owner;
    final String ownerName;
    final String deviceId;
    if (lock != null && lock.screen != home.me.id) {
      owner = lock.screen!;
      ownerName = _nameOf(owner, lock.screenName);
      deviceId = r?.ownerId == owner ? r!.id : id;
    } else if (r != null) {
      owner = r.ownerId;
      ownerName = r.ownerName;
      deviceId = r.id;
    } else {
      throw StateError('No screen reads this device yet');
    }
    final req = _hex(randomBytes(6));
    final done = _pending[req] = Completer<String?>();
    _seenReq[req] = DateTime.now();
    try {
      final sent = await _route({
        't': 'control',
        'req': req,
        'o': owner,
        'id': deviceId,
        'mac': ?tracker[id]?.latest.macString,
        'fp': ?_fp(id),
        'name': ?tracker[id]?.latest.name,
        's': command.setting,
        'v': command.value,
      });
      if (!sent) throw StateError('$ownerName is not connected');
      final err = await done.future.timeout(
        const Duration(seconds: 70),
        onTimeout: () => '$ownerName did not answer',
      );
      if (err != null) throw StateError(err);
    } finally {
      _pending.remove(req);
    }
  }

  String _nameOf(String screen, String? fallback) =>
      _peers[screen]?.screen.name ??
      (screen == home.me.id ? home.me.name : null) ??
      fallback ??
      'another screen';

  /// Other screens (not phones) that hear [id], loudest first.
  List<Hearing> _hearersOf(String id) {
    final now = DateTime.now();
    final out = <Hearing>[];
    for (final p in _peers.values) {
      if (p.phone || now.difference(p.heard) >= _peerGone) continue;
      for (final d in p.hears) {
        if (_resolve(d.id, d.mac, d.name, d.fp) == id) {
          out.add((by: p.screen, rssi: d.rssi));
          break;
        }
      }
    }
    return out..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  // ---- links --------------------------------------------------------------

  Future<void> _applyHome() async {
    await _shutdown();
    error = null;
    if (home.inHome) {
      _incoming = radio.incoming.listen(_onIncoming);
      _serverWait = Duration.zero;
      await _startServer();
    }
    notifyListeners();
  }

  PeerAdvert get _advert =>
      PeerAdvert(home.tag, shortScreen(home.me.id), adding: adding);

  /// Starts serving; on failure [tick] tries again a little later.
  Future<void> _startServer() async {
    if (_serverUp || _serverStarting || !home.inHome) return;
    _serverStarting = true;
    try {
      await radio.startServer(_advert);
      _serverUp = true;
      serverError = null;
    } catch (e) {
      debugPrint('sync: server failed: $e');
      serverError =
          'Other screens cannot connect to this one (${_plainError(e)}). '
          'It still connects to them.';
      _serverWait = _serverWait == Duration.zero
          ? serverRetry
          : _serverWait * 2 > const Duration(minutes: 5)
          ? const Duration(minutes: 5)
          : _serverWait * 2;
      _nextServerTry = DateTime.now().add(_serverWait);
    } finally {
      _serverStarting = false;
      notifyListeners();
    }
  }

  Future<void> _advertise() async {
    if (!_serverUp) return;
    try {
      await radio.startServer(_advert);
    } catch (e) {
      debugPrint('sync: advert update failed: $e');
    }
  }

  Future<void> _shutdown() async {
    await _incoming?.cancel();
    _incoming = null;
    if (_serverUp) {
      _serverUp = false;
      try {
        await radio.stopServer();
      } catch (_) {}
    }
    for (final l in _links.values.toList()) {
      await l.s.close();
    }
    _links.clear();
    _linkedSince = null;
    addingUntil = null;
  }

  Future<void> _onIncoming(MessageLink link) async {
    final key = home.key;
    if (key == null) return link.close();
    final s = await SyncSession.accept(
      link,
      home.me,
      homeKey: key,
      homeName: home.homeName,
      confirm: adding ? _confirm : null,
      onPaired: (m) => stopAdding(),
    );
    if (s == null) {
      await link.close();
      return;
    }
    await _addLink(s, mine: false);
  }

  void _onSighting(PeerSighting h) {
    nearby[h.id] = h;
  }

  Future<void> _connectPeer(PeerSighting h) async {
    final key = home.key;
    if (key == null) return;
    connecting = true;
    notifyListeners();
    MessageLink? link;
    try {
      link = await radio.connect(h);
      final s = await SyncSession.connect(link, home.me, key);
      if (!home.inHome || s.peer.id == home.me.id) {
        await s.close();
        return;
      }
      error = null;
      await _addLink(s, mine: true);
    } on SyncRefused catch (e) {
      debugPrint('sync: ${h.id} refused: $e');
      await link?.close();
      _backoff[h.id] = DateTime.now().add(const Duration(minutes: 5));
      if (!connected) error = e.message;
    } catch (e) {
      debugPrint('sync: link to ${h.id} failed: $e');
      await link?.close();
      _backoff[h.id] = DateTime.now().add(const Duration(seconds: 20));
      if (!connected) error = 'Could not reach a screen: ${_plainError(e)}';
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> _addLink(SyncSession s, {required bool mine}) async {
    final old = _links[s.peer.id];
    if (old != null) {
      // Both screens connected to each other at once. Keep the link the
      // screen with the smaller id opened; the other end decides the same.
      final keepNew = mine == (home.me.id.compareTo(s.peer.id) < 0);
      if (!keepNew) {
        await s.close();
        return;
      }
      _links.remove(s.peer.id);
      await old.s.close();
    }
    final l = _links[s.peer.id] = _Link(s, mine);
    _linkedSince ??= DateTime.now();
    debugPrint('sync: linked to ${s.peer.name} (${mine ? 'out' : 'in'})');
    _listen(s);
    unawaited(
      s.closed.then((_) {
        if (_links[s.peer.id] == l) {
          _links.remove(s.peer.id);
          if (_links.isEmpty) _linkedSince = null;
          notifyListeners();
        }
      }),
    );
    await _sendSnapshot(s);
    notifyListeners();
  }

  Future<bool> _confirm(String code, ScreenId peer, Future<void> abandoned) {
    final p = PairPrompt(code, peer);
    prompt?._answer.complete(false);
    prompt = p;
    notifyListeners();
    abandoned.then((_) {
      if (!p._answer.isCompleted) p._answer.complete(false);
    });
    return p._answer.future.whenComplete(() {
      if (prompt == p) prompt = null;
      notifyListeners();
    });
  }

  // ---- the once-a-second work ---------------------------------------------

  /// Public so tests can drive it.
  Future<void> tick() async {
    _ticks++;
    final now = DateTime.now();
    nearby.removeWhere(
      (_, h) => now.difference(h.seen) > const Duration(seconds: 30),
    );
    _peers.removeWhere(
      (_, p) => now.difference(p.heard) > const Duration(minutes: 5),
    );
    _seenReq.removeWhere(
      (_, t) => now.difference(t) > const Duration(minutes: 3),
    );
    _routes.removeWhere(
      (_, r) => now.difference(r.$2) > const Duration(minutes: 3),
    );
    _unowned.removeWhere((id, _) => ownerOf(id) != null);
    for (final l in _links.values.toList()) {
      if (now.difference(l.heard) > linkSilence) {
        debugPrint(
          'sync: nothing from ${l.s.peer.name} for $linkSilence, '
          'dropping the link',
        );
        _links.remove(l.s.peer.id);
        if (_links.isEmpty) _linkedSince = null;
        unawaited(l.s.close());
        notifyListeners();
      }
    }
    if (addingUntil != null && !adding) stopAdding();
    if (!home.inHome) return;
    if (!_serverUp && !now.isBefore(_nextServerTry)) {
      unawaited(_startServer());
    }
    if (!connecting && _links.length < maxLinks) {
      final pick = _nextPeer(now);
      if (pick != null) unawaited(_connectPeer(pick));
    }
    await _publishOwn();
    if (_ticks % 10 == 1) await _beacon();
    if (_ticks % 5 == 0) {
      await _adoptKeys();
      _mergeRemote();
    }
  }

  /// The screen of this home to link to next, if any.
  PeerSighting? _nextPeer(DateTime now) {
    final me = shortScreen(home.me.id);
    final linkedShort = {for (final id in _links.keys) shortScreen(id)};
    PeerSighting? best;
    for (final h in nearby.values) {
      final s = h.screen;
      if (h.tag != home.tag || s == null || s == me) continue;
      if (linkedShort.contains(s)) continue;
      if (_backoff[h.id]?.isAfter(now) ?? false) continue;
      // To keep two screens from dialling each other at once, the one with
      // the smaller id goes first. The other waits, then goes anyway: the
      // smaller one may not be able to hear it (no advertising allowed).
      final first = _firstHeard.putIfAbsent(s, () => now);
      if (me.compareTo(s) > 0 && now.difference(first) < dialWait) {
        continue;
      }
      if (best == null || h.rssi > best.rssi) best = h;
    }
    return best;
  }

  /// Sends readings this screen took itself since the last tick.
  Future<void> _publishOwn() async {
    final out = <SharedReading>[];
    for (final d in tracker.devices) {
      final at = d.polledAt;
      if (d.polled == null || d.polledBy != null || at == null) continue;
      if (_sentAt[d.id] == at) continue;
      _sentAt[d.id] = at;
      out.add(_own(d));
    }
    if (out.isEmpty || !connected) return;
    await _broadcast({
      't': 'state',
      'r': [for (final r in out) r.toJson()],
    });
  }

  SharedReading _own(TrackedDevice d) {
    final link = connections[d.id];
    return SharedReading(
      id: d.id,
      name: d.latest.name,
      mac: d.latest.macString,
      fp: _fp(d.id),
      ownerId: home.me.id,
      ownerName: home.me.name,
      at: d.polledAt!,
      every: link?.driver.interval ?? const Duration(minutes: 1),
      controllable: link?.driver is ControllableDriver,
      decoded: d.polled!,
    );
  }

  /// Who this screen is and what it hears, for the whole mesh.
  Map<String, Object?> _myBeacon() {
    final now = DateTime.now();
    return {
      't': 'hi',
      'o': home.me.id,
      'n': home.me.name,
      'q': now.millisecondsSinceEpoch,
      'ph': home.phone,
      'd': [
        for (final l in connections.links)
          if (tracker[l.id] case final d?
              when !d.remoteOnly &&
                  now.difference(d.lastSeen) < const Duration(seconds: 30))
            HeardDevice(
              d.id,
              d.latest.rssi,
              name: d.latest.name,
              mac: d.latest.macString,
              fp: _fp(d.id),
            ).toJson(),
      ],
      's': _heardScreens(),
      'l': _links.keys.toList(),
    };
  }

  @visibleForTesting
  Future<void> beacon() => _beacon();

  Future<void> _beacon() async {
    if (connected) await _broadcast(_myBeacon());
  }

  Future<void> _sendSnapshot(SyncSession s) async {
    final now = DateTime.now();
    await _sendTo(s, _myBeacon());
    for (final p in _peers.values.toList()) {
      if (p.screen.id != s.peer.id && now.difference(p.heard) < _peerGone) {
        await _sendTo(s, p._raw);
      }
    }
    final readings = [
      for (final d in tracker.devices)
        if (d.polled != null && d.polledBy == null && d.polledAt != null)
          _own(d),
      for (final r in _shared.values)
        if (r.ownerId != s.peer.id && r.freshAt(now)) r,
    ];
    if (readings.isNotEmpty) {
      await _sendTo(s, {
        't': 'state',
        'r': [for (final r in readings) r.toJson()],
      });
    }
    final recs = keys.records;
    if (recs.isNotEmpty) {
      await _sendTo(s, {
        't': 'keys',
        'k': [for (final r in recs) r.toJson()],
      });
    }
    final locks = readBy.records;
    if (locks.isNotEmpty) {
      await _sendTo(s, {
        't': 'readby',
        'b': [for (final r in locks) r.toJson()],
      });
    }
  }

  /// To every linked screen, except [skip].
  Future<void> _broadcast(Map<String, Object?> msg, {SyncSession? skip}) async {
    for (final l in _links.values.toList()) {
      if (l.s != skip) await _sendTo(l.s, msg);
    }
  }

  /// Sends a message meant for screen `o`: straight to it when linked,
  /// otherwise to every link but [from], to pass along. Returns false when
  /// there was nobody to send it to.
  Future<bool> _route(Map<String, Object?> msg, {SyncSession? from}) async {
    final direct = _links['${msg['o']}'];
    final targets = direct != null
        ? [direct.s]
        : [
            for (final l in _links.values)
              if (l.s != from) l.s,
          ];
    for (final s in targets) {
      await _sendTo(s, msg);
    }
    return targets.isNotEmpty;
  }

  Future<void> _sendTo(SyncSession s, Map<String, Object?> msg) async {
    try {
      await s.send(msg);
    } catch (e) {
      debugPrint('sync: send to ${s.peer.name} failed: $e');
    }
  }

  // ---- incoming -----------------------------------------------------------

  void _listen(SyncSession s) {
    s.messages.listen((m) async {
      _links[s.peer.id]?.heard = DateTime.now();
      try {
        await _onMessage(s, m);
      } catch (e) {
        debugPrint('sync: bad ${m['t']} from ${s.peer.name}: $e');
      }
    });
  }

  // Readings, keys, locks and beacons pass along only when they are news to
  // this screen, so a message never goes round in circles.
  Future<void> _onMessage(SyncSession from, Map<String, Object?> m) async {
    switch (m['t']) {
      case 'hi':
        final id = '${m['o']}';
        if (id == home.me.id) return;
        final old = _peers[id];
        if (old != null && (m['q'] as num).toInt() <= old.seq) return;
        _peers[id] = PeerInfo.fromJson(m, DateTime.now());
        await _broadcast(m, skip: from);
        notifyListeners();
      case 'state':
        final fresh = <SharedReading>[];
        for (final j in (m['r'] as List? ?? const [])) {
          final r = SharedReading.fromJson((j as Map).cast());
          if (r.ownerId == home.me.id) continue;
          final old = _shared[r.slot];
          if (old != null && !r.at.isAfter(old.at)) continue;
          _shared[r.slot] = r;
          fresh.add(r);
          final local = _resolve(r.id, r.mac, r.name, r.fp);
          _ownerSlotOf[local] = r.slot;
          tracker.setRemote(
            local,
            decoded: r.decoded,
            at: r.at,
            by: r.ownerName,
            name: r.name,
            mac: parseMac(r.mac),
          );
        }
        if (fresh.isNotEmpty) {
          await _broadcast({
            't': 'state',
            'r': [for (final r in fresh) r.toJson()],
          }, skip: from);
        }
      case 'keys':
        final changed = <KeyRecord>[];
        _applying = true;
        try {
          for (final j in (m['k'] as List? ?? const [])) {
            final r = KeyRecord.fromJson((j as Map).cast());
            if (await keys.apply(r, asId: _resolve(r.id, r.mac, r.name))) {
              changed.add(r);
            }
          }
        } finally {
          _applying = false;
        }
        _keysSent = _max(_keysSent, _maxAt(changed.map((r) => r.at)));
        if (changed.isNotEmpty) {
          await _broadcast({
            't': 'keys',
            'k': [for (final r in changed) r.toJson()],
          }, skip: from);
        }
      case 'readby':
        final changed = <ReadByRecord>[];
        _applying = true;
        try {
          for (final j in (m['b'] as List? ?? const [])) {
            final r = ReadByRecord.fromJson((j as Map).cast());
            if (await readBy.apply(
              r,
              asId: _resolve(r.id, r.mac, r.name, r.fp),
            )) {
              changed.add(r);
            }
          }
        } finally {
          _applying = false;
        }
        _readBySent = _max(_readBySent, _maxAt(changed.map((r) => r.at)));
        if (changed.isNotEmpty) {
          await _broadcast({
            't': 'readby',
            'b': [for (final r in changed) r.toJson()],
          }, skip: from);
        }
      case 'control':
        await _onControl(from, m);
      case 'result':
        final req = '${m['req']}';
        final route = _routes.remove(req);
        if (route != null) {
          await _sendTo(route.$1, m);
        } else {
          _pending[req]?.complete(m['err'] as String?);
        }
    }
  }

  Future<void> _onControl(SyncSession from, Map<String, Object?> m) async {
    final req = '${m['req']}';
    // The same request can arrive by two paths through the mesh.
    if (_seenReq.containsKey(req)) return;
    _seenReq[req] = DateTime.now();
    final owner = '${m['o']}';
    if (owner == home.me.id) {
      String? err;
      try {
        final id = _resolve(
          '${m['id']}',
          m['mac'] as String?,
          m['name'] as String?,
          m['fp'] as String?,
        );
        await connections.control(
          id,
          DeviceCommand('${m['s']}', m['v'] as Object),
          here: true,
        );
      } catch (e) {
        err = _plainError(e);
      }
      await _sendTo(from, {'t': 'result', 'req': req, 'err': ?err});
      return;
    }
    final hops = (m['h'] as num?)?.toInt() ?? 0;
    _routes[req] = (from, DateTime.now());
    final sent = hops < 6 && await _route({...m, 'h': hops + 1}, from: from);
    if (!sent) {
      _routes.remove(req);
      await _sendTo(from, {
        't': 'result',
        'req': req,
        'err': 'The screen that reads that device is not connected',
      });
    }
  }

  // ---- keys and locks -----------------------------------------------------

  void _onKeys() {
    if (_applying) return;
    final news = keys.records.where((r) => r.at > _keysSent).toList();
    if (news.isEmpty) return;
    _keysSent = _maxAt(news.map((r) => r.at));
    unawaited(
      _broadcast({
        't': 'keys',
        'k': [for (final r in news) r.toJson()],
      }),
    );
  }

  void _onReadBy() {
    _unowned.clear();
    if (_applying) return;
    final news = readBy.records.where((r) => r.at > _readBySent).toList();
    if (news.isEmpty) return;
    _readBySent = _maxAt(news.map((r) => r.at));
    unawaited(
      _broadcast({
        't': 'readby',
        'b': [for (final r in news) r.toJson()],
      }),
    );
  }

  /// A key that came from a screen that knows the device under another id
  /// (iOS), for a device this screen had not heard yet: copy it to this
  /// screen's id once the device shows up. Locks likewise.
  Future<void> _adoptKeys() async {
    _applying = true;
    try {
      for (final r in keys.records) {
        if (r.value == null || tracker[r.id] != null) continue;
        final local = _resolve(r.id, r.mac, r.name);
        if (local != r.id) await keys.apply(r, asId: local);
      }
      for (final r in readBy.records) {
        if (tracker[r.id] != null) continue;
        final local = _resolve(r.id, r.mac, r.name, r.fp);
        if (local != r.id) await readBy.apply(r, asId: local);
      }
    } finally {
      _applying = false;
    }
  }

  /// A reading that arrived before this screen heard the device sits under
  /// the other screen's id. Once this screen hears the device itself, move
  /// the reading over and drop the stand-in, so it does not show twice.
  void _mergeRemote() {
    for (final e in _ownerSlotOf.entries.toList()) {
      if (!(tracker[e.key]?.remoteOnly ?? false)) continue;
      final r = _shared[e.value];
      if (r == null) continue;
      final local = _resolve(r.id, r.mac, r.name, r.fp);
      if (local == e.key) continue;
      _ownerSlotOf.remove(e.key);
      _ownerSlotOf[local] = e.value;
      tracker.removeRemote(e.key);
      tracker.setRemote(
        local,
        decoded: r.decoded,
        at: r.at,
        by: r.ownerName,
        name: r.name,
        mac: parseMac(r.mac),
      );
    }
  }

  /// This screen's id for a device another screen calls [id]: the same id,
  /// the same MAC, or failing those the only device with that name.
  String _resolve(String id, String? mac, String? name, [String? fp]) {
    final heard = tracker.devices.where((d) => !d.remoteOnly).toList();
    if (heard.any((d) => d.id == id)) return id;
    if (mac != null) {
      for (final d in heard) {
        if (d.id == mac || d.latest.macString == mac) return d.id;
      }
    }
    if (name != null) {
      final named = heard.where((d) => d.latest.name == name).toList();
      if (named.length == 1) return named.single.id;
    }
    if (fp != null) {
      final same = heard.where((d) => _fp(d.id) == fp).toList();
      if (same.length == 1) return same.single.id;
    }
    return id;
  }

  String? _fp(String id) {
    final d = tracker[id];
    if (d == null || d.remoteOnly) return null;
    return advertFingerprint(d.lastRecognised ?? d.latest);
  }
}

class _Link {
  final SyncSession s;

  /// This screen opened it.
  final bool mine;

  /// When the last message came in. Beacons arrive every 10 seconds, so a
  /// link that has gone quiet is stuck even if Bluetooth says it is up.
  DateTime heard = DateTime.now();
  _Link(this.s, this.mine);
}

String _plainError(Object e) =>
    '$e'.replaceFirst(RegExp(r'^(Bad state|StateError|Exception): '), '');

int _maxAt(Iterable<int> ats) => ats.fold(0, _max);

int _max(int a, int b) => a > b ? a : b;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
