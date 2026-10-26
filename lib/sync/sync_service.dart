// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Screen sync: tablets and phones in one home share what they read and
// the keys they know, over Bluetooth only. One screen is the hub and runs
// a Le'Casa GATT server; the others connect to it, and it passes messages
// between them. Whichever screen reads a device over a connection shares
// the reading, and the others leave that device alone, so a tablet with
// a poor Bluetooth chip can show a fridge another screen holds. Controls
// travel to the screen that holds the connection.

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
import 'session.dart';
import 'wire.dart';

/// A pairing code waiting for the person to compare it.
class PairPrompt {
  final String code;
  final ScreenId peer;
  final Completer<bool> _answer = Completer();
  PairPrompt(this.code, this.peer);
}

class SyncService extends ChangeNotifier implements RemoteLinks {
  final HomeStore home;
  final DeviceTracker tracker;
  final KeyStore keys;
  final ConnectionManager connections;
  final SyncRadio radio;

  SyncService({
    required this.home,
    required this.tracker,
    required this.keys,
    required this.connections,
    required this.radio,
  });

  // hub side
  final Map<String, SyncSession> _members = {};
  StreamSubscription? _incoming;
  bool _hubUp = false;

  /// Until when the hub takes new screens.
  DateTime? addingUntil;

  // member side
  SyncSession? _hub;
  bool connecting = false;
  DateTime _nextTry = DateTime.now();
  final Map<String, DateTime> _wrongHub = {};

  /// Hubs heard lately, for the join list.
  final Map<String, HubSighting> nearby = {};

  /// Every screen in the home the hub knows of, this one included.
  List<ScreenId> screens = const [];

  /// Last thing that went wrong, for the settings page.
  String? error;

  /// Set while a pairing code is on screen.
  PairPrompt? prompt;
  bool joining = false;

  final Map<String, SharedReading> _shared = {};
  final Map<String, String> _ownerSlotOf = {};
  final Map<String, DateTime> _sentAt = {};
  final Map<String, Completer<String?>> _pending = {};
  final Map<String, (SyncSession, String)> _forwarded = {};
  int _keysSent = 0;
  bool _applyingKeys = false;
  Timer? _tick;
  int _ticks = 0;
  StreamSubscription? _sightingSub;

  bool get connected => switch (home.role) {
    SyncRole.hub => _hubUp,
    SyncRole.member => _hub != null,
    SyncRole.alone => false,
  };

  /// Screens connected to this hub.
  List<ScreenId> get members => [for (final s in _members.values) s.peer];

  bool get adding =>
      addingUntil != null && DateTime.now().isBefore(addingUntil!);

  void start() {
    _sightingSub = radio.sightings.listen(_onSighting);
    keys.addListener(_onKeys);
    _keysSent = _maxAt(keys.records);
    connections.remote = this;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    unawaited(_applyRole());
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
    unawaited(_shutdown());
    super.dispose();
  }

  // ---- what the settings page calls --------------------------------------

  Future<void> startHome(String name) async {
    await home.startHome(name);
    await _applyRole();
  }

  /// Lets new screens pair for a few minutes.
  void startAdding() {
    addingUntil = DateTime.now().add(const Duration(minutes: 3));
    notifyListeners();
  }

  void stopAdding() {
    addingUntil = null;
    prompt?._answer.complete(false);
    notifyListeners();
  }

  /// Pairs with [hub]; the pairing code shows up in [prompt].
  Future<void> join(HubSighting hub) async {
    if (joining) return;
    joining = true;
    error = null;
    notifyListeners();
    MessageLink? link;
    try {
      link = await radio.connect(hub);
      final joined = await SyncSession.pair(link, home.me, _confirm);
      await home.joined(joined);
      await _applyRole();
    } on SyncRefused catch (e) {
      error = e.message == 'Cancelled' ? null : e.message;
    } catch (e) {
      error = 'Could not reach that hub: $e';
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
    screens = const [];
    notifyListeners();
  }

  // ---- RemoteLinks --------------------------------------------------------

  @override
  RemoteOwner? ownerOf(String id) {
    final r = _shared[_ownerSlotOf[id]];
    if (r == null || !r.freshAt(DateTime.now())) return null;
    return RemoteOwner(r.ownerName, r.at, controllable: r.controllable);
  }

  @override
  Future<void> control(String id, DeviceCommand command) async {
    final r = _shared[_ownerSlotOf[id]];
    if (r == null) throw StateError('No screen holds this device');
    final via = home.role == SyncRole.hub ? _members[r.ownerId] : _hub;
    if (via == null) throw StateError('${r.ownerName} is not connected');
    final req = _hex(randomBytes(6));
    final done = _pending[req] = Completer<String?>();
    try {
      await via.send({
        't': 'control',
        'req': req,
        'o': r.ownerId,
        'id': r.id,
        's': command.setting,
        'v': command.value,
      });
      final err = await done.future.timeout(
        const Duration(seconds: 70),
        onTimeout: () => '${r.ownerName} did not answer',
      );
      if (err != null) throw StateError(err);
    } finally {
      _pending.remove(req);
    }
  }

  // ---- roles --------------------------------------------------------------

  Future<void> _applyRole() async {
    await _shutdown();
    error = null;
    switch (home.role) {
      case SyncRole.hub:
        _incoming = radio.incoming.listen(_onIncoming);
        screens = [home.me];
        await _startHub();
      case SyncRole.member:
        _nextTry = DateTime.now();
      case SyncRole.alone:
        break;
    }
    notifyListeners();
  }

  bool _hubStarting = false;

  /// Wait before trying to start the hub again.
  @visibleForTesting
  Duration hubRetry = const Duration(seconds: 15);

  /// Starts advertising; on failure [tick] tries again a little later.
  Future<void> _startHub() async {
    if (_hubUp || _hubStarting) return;
    _hubStarting = true;
    try {
      await radio.startHub(home.tag);
      _hubUp = true;
      error = null;
    } catch (e) {
      error = 'Could not start the hub: ${_plainError(e)}. Trying again…';
      _nextTry = DateTime.now().add(hubRetry);
    } finally {
      _hubStarting = false;
      notifyListeners();
    }
  }

  Future<void> _shutdown() async {
    await _incoming?.cancel();
    _incoming = null;
    if (_hubUp) {
      _hubUp = false;
      try {
        await radio.stopHub();
      } catch (_) {}
    }
    for (final s in [..._members.values, ?_hub]) {
      await s.close();
    }
    _members.clear();
    _hub = null;
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
      onPaired: (m) {
        addingUntil = null;
        notifyListeners();
      },
    );
    if (s == null) {
      await link.close();
      return;
    }
    await _members.remove(s.peer.id)?.close();
    _members[s.peer.id] = s;
    _listen(s);
    unawaited(
      s.closed.then((_) {
        if (_members[s.peer.id] == s) _members.remove(s.peer.id);
        _sendScreens();
        notifyListeners();
      }),
    );
    _sendScreens();
    await _sendSnapshot(s);
    notifyListeners();
  }

  void _onSighting(HubSighting h) {
    nearby[h.id] = h;
  }

  Future<void> _connectHub(HubSighting h) async {
    final key = home.key;
    if (key == null) return;
    connecting = true;
    notifyListeners();
    MessageLink? link;
    try {
      link = await radio.connect(h);
      final s = await SyncSession.connect(link, home.me, key);
      if (home.role != SyncRole.member) {
        await s.close();
        return;
      }
      _hub = s;
      error = null;
      await home.setHubName(s.peer.name);
      _listen(s);
      unawaited(
        s.closed.then((_) {
          if (_hub == s) {
            _hub = null;
            _nextTry = DateTime.now().add(const Duration(seconds: 3));
            notifyListeners();
          }
        }),
      );
      await _sendSnapshot(s);
    } on SyncRefused catch (e) {
      await link?.close();
      _wrongHub[h.id] = DateTime.now().add(const Duration(minutes: 5));
      error = e.message;
      _nextTry = DateTime.now().add(const Duration(seconds: 5));
    } catch (e) {
      await link?.close();
      error = 'Could not reach the hub: $e';
      _nextTry = DateTime.now().add(const Duration(seconds: 10));
    } finally {
      connecting = false;
      notifyListeners();
    }
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
    if (addingUntil != null && !adding) {
      addingUntil = null;
      notifyListeners();
    }
    if (home.role == SyncRole.hub && !_hubUp && !now.isBefore(_nextTry)) {
      unawaited(_startHub());
    }
    if (home.role == SyncRole.member &&
        _hub == null &&
        !connecting &&
        !now.isBefore(_nextTry)) {
      final tag = home.tag;
      final ours =
          nearby.values
              .where((h) => h.tag == tag)
              .where((h) => !(_wrongHub[h.id]?.isAfter(now) ?? false))
              .toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi));
      if (ours.isNotEmpty) unawaited(_connectHub(ours.first));
    }
    await _publishOwn();
    if (_ticks % 5 == 0) await _adoptKeys();
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
    if (out.isEmpty) return;
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
      ownerId: home.me.id,
      ownerName: home.me.name,
      at: d.polledAt!,
      every: link?.driver.interval ?? const Duration(minutes: 1),
      controllable: link?.driver is ControllableDriver,
      decoded: d.polled!,
    );
  }

  Future<void> _sendSnapshot(SyncSession s) async {
    final now = DateTime.now();
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
  }

  void _sendScreens() {
    if (home.role != SyncRole.hub) return;
    screens = [home.me, ...members];
    final msg = {
      't': 'screens',
      's': [for (final s in screens) s.toJson()],
    };
    for (final s in _members.values) {
      unawaited(_sendTo(s, msg));
    }
  }

  /// To everyone this screen talks to, except [skip].
  Future<void> _broadcast(Map<String, Object?> msg, {SyncSession? skip}) async {
    final targets = home.role == SyncRole.hub
        ? _members.values.toList()
        : [?_hub];
    for (final s in targets) {
      if (s != skip) await _sendTo(s, msg);
    }
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
      try {
        await _onMessage(s, m);
      } catch (e) {
        debugPrint('sync: bad ${m['t']} from ${s.peer.name}: $e');
      }
    });
  }

  Future<void> _onMessage(SyncSession from, Map<String, Object?> m) async {
    switch (m['t']) {
      case 'state':
        final fresh = <SharedReading>[];
        for (final j in (m['r'] as List? ?? const [])) {
          final r = SharedReading.fromJson((j as Map).cast());
          if (r.ownerId == home.me.id) continue;
          final old = _shared[r.slot];
          if (old != null && !r.at.isAfter(old.at)) continue;
          _shared[r.slot] = r;
          fresh.add(r);
          final local = _resolve(r.id, r.mac, r.name);
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
        if (home.role == SyncRole.hub && fresh.isNotEmpty) {
          await _broadcast({
            't': 'state',
            'r': [for (final r in fresh) r.toJson()],
          }, skip: from);
        }
      case 'keys':
        final changed = <KeyRecord>[];
        _applyingKeys = true;
        try {
          for (final j in (m['k'] as List? ?? const [])) {
            final r = KeyRecord.fromJson((j as Map).cast());
            if (await keys.apply(r, asId: _resolve(r.id, r.mac, r.name))) {
              changed.add(r);
            }
          }
        } finally {
          _applyingKeys = false;
        }
        _keysSent = [
          _keysSent,
          _maxAt(changed),
        ].reduce((a, b) => a > b ? a : b);
        if (home.role == SyncRole.hub && changed.isNotEmpty) {
          await _broadcast({
            't': 'keys',
            'k': [for (final r in changed) r.toJson()],
          }, skip: from);
        }
      case 'control':
        await _onControl(from, m);
      case 'result':
        final req = '${m['req']}';
        final err = m['err'] as String?;
        final fwd = _forwarded.remove(req);
        if (fwd != null) {
          await _sendTo(fwd.$1, {'t': 'result', 'req': fwd.$2, 'err': ?err});
        } else {
          _pending[req]?.complete(err);
        }
      case 'screens':
        screens = [
          for (final j in (m['s'] as List? ?? const []))
            ScreenId.fromJson((j as Map).cast()),
        ];
        notifyListeners();
    }
  }

  Future<void> _onControl(SyncSession from, Map<String, Object?> m) async {
    final req = '${m['req']}';
    final owner = '${m['o']}';
    if (owner == home.me.id) {
      String? err;
      try {
        await connections.control(
          '${m['id']}',
          DeviceCommand('${m['s']}', m['v'] as Object),
          here: true,
        );
      } catch (e) {
        err = _plainError(e);
      }
      await _sendTo(from, {'t': 'result', 'req': req, 'err': ?err});
      return;
    }
    final to = home.role == SyncRole.hub ? _members[owner] : null;
    if (to == null) {
      await _sendTo(from, {
        't': 'result',
        'req': req,
        'err': 'The screen holding that device is not connected',
      });
      return;
    }
    final fwd = _hex(randomBytes(6));
    _forwarded[fwd] = (from, req);
    await _sendTo(to, {...m, 'req': fwd});
  }

  // ---- keys ---------------------------------------------------------------

  void _onKeys() {
    if (_applyingKeys) return;
    final news = keys.records.where((r) => r.at > _keysSent).toList();
    if (news.isEmpty) return;
    _keysSent = _maxAt(news);
    unawaited(
      _broadcast({
        't': 'keys',
        'k': [for (final r in news) r.toJson()],
      }),
    );
  }

  /// A key that came from a screen that knows the device under another id
  /// (iOS), for a device this screen had not heard yet: copy it to this
  /// screen's id once the device shows up.
  Future<void> _adoptKeys() async {
    for (final r in keys.records) {
      if (r.value == null || tracker[r.id] != null) continue;
      final local = _resolve(r.id, r.mac, r.name);
      if (local == r.id) continue;
      _applyingKeys = true;
      try {
        await keys.apply(r, asId: local);
      } finally {
        _applyingKeys = false;
      }
    }
  }

  /// This screen's id for a device another screen calls [id]: the same id,
  /// the same MAC, or failing those the only device with that name.
  String _resolve(String id, String? mac, String? name) {
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
    return id;
  }
}

String _plainError(Object e) =>
    '$e'.replaceFirst(RegExp(r'^(Bad state|StateError|Exception): '), '');

int _maxAt(Iterable<KeyRecord> rs) => rs.fold(0, (m, r) => r.at > m ? r.at : m);

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
