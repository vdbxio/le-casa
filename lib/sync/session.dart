// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// One link between two screens, after framing: the pairing handshake, the
// hello that proves both sides hold the home key, and sealed JSON messages
// from then on. M is the screen that connected, H the one it connected to
// (H for host; any screen in a home can be either). No Bluetooth in here, so it runs
// in unit tests over an in-memory pipe.
//
// Pairing, a new screen (M) and one already in the home (H):
//   M -> H  pair   {pub, id, name}
//   H -> M  pair   {pub, commit = SHA-256(nonce H), id, name}
//   M -> H  nonce  {nonce M}
//   H -> M  reveal {nonce H}          M checks it against the commitment
//   both show the six-digit code; each person taps Match
//   H -> M  sealed {t: home, key, name}  (key from the ECDH secret)
// H commits to its nonce before it sees M's, so a device in
// the middle cannot search for keys that make the two codes agree.
//
// Every later link:
//   M -> H  hello  {home tag, nonce, id, name}
//   H -> M  hello  {nonce, id, name}
//   M -> H  sealed {t: join}
//   H -> M  sealed {t: welcome}
// The first sealed message each side opens proves the other has the key.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'crypto.dart';
import 'framing.dart';

const _plain = 0x01;
const _sealed = 0x02;

/// Sealed, with the JSON deflated first. Readings and beacons shrink to a
/// third or so, and every byte a screen sends costs the M10 scan time.
const _sealedZ = 0x03;
final _zlib = ZLibCodec(level: 6);
const protocolVersion = 1;

/// Who is on the other end of a link.
class ScreenId {
  /// Random, made once per install.
  final String id;

  /// What the person called the screen ("Kitchen iPad").
  final String name;

  const ScreenId(this.id, this.name);

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static ScreenId fromJson(Map<String, Object?> j) =>
      ScreenId('${j['id']}', '${j['name'] ?? 'Screen'}');

  @override
  bool operator ==(Object other) => other is ScreenId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Shows the pairing code and the other screen's name, and completes with
/// true when the person says both screens show the same number.
/// [abandoned] completes if the other side gives up first, so the prompt
/// can close itself.
typedef ConfirmCode = Future<bool> Function(
  String code,
  ScreenId peer,
  Future<void> abandoned,
);

class SyncRefused implements Exception {
  final String message;
  const SyncRefused(this.message);
  @override
  String toString() => message;
}

/// What a new screen gets out of pairing.
class JoinedHome {
  final Uint8List key;
  final String name;

  /// The screen that let this one in.
  final ScreenId via;
  const JoinedHome(this.key, this.name, this.via);
}

/// An authenticated link, either end. Messages are JSON objects with a
/// `t` field naming their type.
class SyncSession {
  final MessageLink _link;
  final ScreenId peer;
  final SealKey _tx;
  final SealKey _rx;
  final _in = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription? _sub;

  SyncSession._(this._link, this.peer, this._tx, this._rx);

  Stream<Map<String, Object?>> get messages => _in.stream;

  Future<void> get closed => _link.link.closed;

  /// The other screen reads deflated messages. Learnt from its beacon (it
  /// says `z`) or from a deflated message; until then it may be an older
  /// version, so messages go out plain.
  bool peerInflates = false;

  void _start(Stream<Uint8List> raw) {
    _sub = raw.listen(
      (m) {
        try {
          if (m.isEmpty || (m[0] != _sealed && m[0] != _sealedZ)) return;
          List<int> body = _rx.open(Uint8List.sublistView(m, 1));
          if (m[0] == _sealedZ) {
            body = _zlib.decode(body);
            peerInflates = true;
          }
          final j = jsonDecode(utf8.decode(body));
          if (j is! Map<String, Object?>) return;
          if (j['t'] == 'hi' && j['o'] == peer.id && j['z'] == true) {
            peerInflates = true;
          }
          _in.add(j);
        } catch (_) {
          // Garbage, a replay or bad deflate data: drop it, the link stays
          // up.
        }
      },
      onDone: () {
        if (!_in.isClosed) _in.close();
      },
    );
  }

  Future<void> send(Map<String, Object?> message) {
    final m = peerInflates
        ? _sealDeflated(_tx, message)
        : _seal(_tx, message);
    SyncTraffic.sent(m.length);
    return _link.send(m);
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _link.close();
    if (!_in.isClosed) await _in.close();
  }

  // ---- connecting side --------------------------------------------------------

  /// Opens a session to another screen with the home key. Throws
  /// [SyncRefused] when it belongs to another home or the key is wrong.
  static Future<SyncSession> connect(
    MessageLink link,
    ScreenId me,
    Uint8List homeKey, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final inbox = _Inbox(link.messages);
    try {
      final nonce = randomBytes(16);
      await link.send(
        _plainMsg({
          't': 'hello',
          'v': protocolVersion,
          'home': homeTag(homeKey),
          'nonce': _hex(nonce),
          ...me.toJson(),
        }),
      );
      final reply = await inbox.plain(timeout);
      _refusedIf(reply);
      if (reply['t'] != 'hello') throw const SyncRefused('Unexpected reply');
      final hub = ScreenId.fromJson(reply);
      final hubNonce = _unhex(reply['nonce']);
      final salt = Uint8List.fromList([...nonce, ...hubNonce]);
      final tx = SealKey(hkdf(homeKey, salt, 'lecasa m2h'));
      final rx = SealKey(hkdf(homeKey, salt, 'lecasa h2m'));
      await link.send(_seal(tx, {'t': 'join'}));
      final w = await inbox.sealed(rx, timeout);
      if (w['t'] != 'welcome') {
        throw const SyncRefused('That screen did not let us in');
      }
      final s = SyncSession._(link, hub, tx, rx);
      s._start(inbox.rest());
      return s;
    } catch (_) {
      inbox.cancel();
      rethrow;
    }
  }

  /// Pairs with a screen that is adding new ones. Returns the home
  /// key once both people have confirmed the code. The link is spent
  /// afterwards; connect again with [connect].
  static Future<JoinedHome> pair(
    MessageLink link,
    ScreenId me,
    ConfirmCode confirm, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final inbox = _Inbox(link.messages);
    try {
      final key = EphemeralKey.generate();
      final nonce = randomBytes(16);
      await link.send(
        _plainMsg({
          't': 'pair',
          'v': protocolVersion,
          'pub': _hex(key.public),
          ...me.toJson(),
        }),
      );
      final r1 = await inbox.plain(timeout);
      _refusedIf(r1);
      if (r1['t'] != 'pair') throw const SyncRefused('Unexpected reply');
      final hub = ScreenId.fromJson(r1);
      final hubPub = _unhex(r1['pub']);
      final commit = _unhex(r1['commit']);
      await link.send(_plainMsg({'t': 'nonce', 'nonce': _hex(nonce)}));
      final r2 = await inbox.plain(timeout);
      _refusedIf(r2);
      final hubNonce = _unhex(r2['nonce']);
      if (!_same(sha256(hubNonce), commit)) {
        throw const SyncRefused(
          'The other screen broke its promise; try again',
        );
      }
      final shared = key.agree(hubPub);
      final code = pairingCode(
        shared: shared,
        clientPublic: key.public,
        hubPublic: hubPub,
        clientNonce: nonce,
        hubNonce: hubNonce,
      );
      final salt = Uint8List.fromList([...nonce, ...hubNonce]);
      final rx = SealKey(hkdf(shared, salt, 'lecasa pair'));
      // Wait for both: our person's answer and the hub's key (which only
      // comes once the hub's person said yes).
      final homeMsg = inbox.sealed(rx, const Duration(minutes: 3));
      homeMsg.ignore();
      final abandoned = Completer<void>();
      homeMsg.then(
        (_) {},
        onError: (_) {
          if (!abandoned.isCompleted) abandoned.complete();
        },
      );
      final ok = await confirm(code, hub, abandoned.future);
      if (!ok) {
        await link.send(
          _plainMsg({'t': 'no', 'why': 'The codes did not match'}),
        );
        throw const SyncRefused('Cancelled');
      }
      final Map<String, Object?> h;
      try {
        h = await homeMsg;
      } on SyncRefused {
        rethrow;
      } on TimeoutException {
        throw const SyncRefused('The other screen did not confirm in time');
      }
      if (h['t'] != 'home') throw const SyncRefused('Unexpected reply');
      final homeKey = _unhex(h['key']);
      if (homeKey.length != 32) throw const SyncRefused('Bad home key');
      return JoinedHome(homeKey, '${h['name'] ?? 'Home'}', hub);
    } finally {
      inbox.cancel();
    }
  }

  // ---- host side -----------------------------------------------------------

  /// Handles a link from a screen that connected to this one. Returns a
  /// session for a screen that
  /// proved it has the home key, or null after a pairing (successful or
  /// not), after which the link should be closed.
  ///
  /// [confirm] is null while this screen is not adding new ones.
  static Future<SyncSession?> accept(
    MessageLink link,
    ScreenId me, {
    required Uint8List homeKey,
    required String homeName,
    ConfirmCode? confirm,
    void Function(ScreenId member)? onPaired,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final inbox = _Inbox(link.messages);
    var handedOver = false;
    try {
      final first = await inbox.plain(timeout);
      switch (first['t']) {
        case 'hello':
          if (first['home'] != homeTag(homeKey)) {
            await link.send(_plainMsg({'t': 'no', 'why': 'Another home'}));
            return null;
          }
          final member = ScreenId.fromJson(first);
          final nonce = randomBytes(16);
          await link.send(
            _plainMsg({
              't': 'hello',
              'v': protocolVersion,
              'nonce': _hex(nonce),
              ...me.toJson(),
            }),
          );
          final salt = Uint8List.fromList([
            ..._unhex(first['nonce']),
            ...nonce,
          ]);
          final rx = SealKey(hkdf(homeKey, salt, 'lecasa m2h'));
          final tx = SealKey(hkdf(homeKey, salt, 'lecasa h2m'));
          final j = await inbox.sealed(rx, timeout);
          if (j['t'] != 'join') return null;
          await link.send(_seal(tx, {'t': 'welcome'}));
          final s = SyncSession._(link, member, tx, rx);
          s._start(inbox.rest());
          handedOver = true;
          return s;
        case 'pair':
          if (confirm == null) {
            await link.send(
              _plainMsg({
                't': 'no',
                'why':
                    'That screen is not adding screens. Tap "Add a screen or '
                    'phone" on it first.',
              }),
            );
            return null;
          }
          final member = ScreenId.fromJson(first);
          final memberPub = _unhex(first['pub']);
          final key = EphemeralKey.generate();
          final nonce = randomBytes(16);
          await link.send(
            _plainMsg({
              't': 'pair',
              'v': protocolVersion,
              'pub': _hex(key.public),
              'commit': _hex(sha256(nonce)),
              ...me.toJson(),
            }),
          );
          final n = await inbox.plain(timeout);
          if (n['t'] != 'nonce') return null;
          final memberNonce = _unhex(n['nonce']);
          await link.send(_plainMsg({'t': 'reveal', 'nonce': _hex(nonce)}));
          final shared = key.agree(memberPub);
          final code = pairingCode(
            shared: shared,
            clientPublic: memberPub,
            hubPublic: key.public,
            clientNonce: memberNonce,
            hubNonce: nonce,
          );
          // A "no" from the member closes the dialog on our side too.
          final refused = inbox.plain(const Duration(minutes: 3));
          refused.ignore();
          final abandoned = refused.then((_) {}, onError: (_) {});
          final ok = await Future.any([
            confirm(code, member, abandoned),
            abandoned.then((_) => false),
          ]);
          if (!ok) return null;
          final salt = Uint8List.fromList([...memberNonce, ...nonce]);
          final tx = SealKey(hkdf(shared, salt, 'lecasa pair'));
          await link.send(
            _seal(tx, {'t': 'home', 'key': _hex(homeKey), 'name': homeName}),
          );
          onPaired?.call(member);
          return null;
        default:
          return null;
      }
    } on FormatException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      if (!handedOver) inbox.cancel();
    }
  }
}

void _refusedIf(Map<String, Object?> m) {
  if (m['t'] == 'no') throw SyncRefused('${m['why'] ?? 'Refused'}');
}

Uint8List _plainMsg(Map<String, Object?> j) =>
    Uint8List.fromList([_plain, ...utf8.encode(jsonEncode(j))]);

Uint8List _seal(SealKey k, Map<String, Object?> j) =>
    Uint8List.fromList([_sealed, ...k.seal(utf8.encode(jsonEncode(j)))]);

Uint8List _sealDeflated(SealKey k, Map<String, Object?> j) =>
    Uint8List.fromList([
      _sealedZ,
      ...k.seal(Uint8List.fromList(_zlib.encode(utf8.encode(jsonEncode(j))))),
    ]);

/// Bytes and messages screen sync sent since the last [take], for the
/// once-a-minute radio log.
class SyncTraffic {
  static int _bytes = 0;
  static int _messages = 0;

  static void sent(int bytes) {
    _bytes += bytes;
    _messages++;
  }

  static ({int bytes, int messages}) take() {
    final out = (bytes: _bytes, messages: _messages);
    _bytes = 0;
    _messages = 0;
    return out;
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(Object? s) {
  final t = '$s';
  if (t.length.isOdd) throw const FormatException('Bad hex');
  return Uint8List.fromList([
    for (var i = 0; i < t.length; i += 2)
      int.parse(t.substring(i, i + 2), radix: 16),
  ]);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Buffers incoming messages during the handshake so none slip past
/// between two awaits, then hands the rest to the session.
class _Inbox {
  final _queue = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];
  late final StreamSubscription<Uint8List> _sub;
  StreamController<Uint8List>? _rest;
  bool _done = false;

  _Inbox(Stream<Uint8List> source) {
    _sub = source.listen(
      (m) {
        final r = _rest;
        if (r != null) {
          r.add(m);
        } else if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(m);
        } else {
          _queue.add(m);
        }
      },
      onDone: () {
        _done = true;
        for (final w in _waiters) {
          w.completeError(const SyncRefused('The link closed'));
        }
        _waiters.clear();
        _rest?.close();
      },
    );
  }

  Future<Uint8List> _next(Duration timeout) {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    if (_done) return Future.error(const SyncRefused('The link closed'));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(c);
        throw TimeoutException('No answer from the other screen');
      },
    );
  }

  Future<Map<String, Object?>> plain(Duration timeout) async {
    final m = await _next(timeout);
    if (m.isEmpty || m[0] != _plain) {
      throw const FormatException('Expected plain');
    }
    final j = jsonDecode(utf8.decode(Uint8List.sublistView(m, 1)));
    if (j is! Map<String, Object?>) {
      throw const FormatException('Not an object');
    }
    return j;
  }

  Future<Map<String, Object?>> sealed(SealKey k, Duration timeout) async {
    final m = await _next(timeout);
    if (m.isNotEmpty && m[0] == _plain) {
      final j = jsonDecode(utf8.decode(Uint8List.sublistView(m, 1)));
      if (j is Map && j['t'] == 'no') {
        throw SyncRefused('${j['why'] ?? 'Refused'}');
      }
      throw const FormatException('Expected sealed');
    }
    if (m.isEmpty || m[0] != _sealed) {
      throw const FormatException('Expected sealed');
    }
    final j = jsonDecode(utf8.decode(k.open(Uint8List.sublistView(m, 1))));
    if (j is! Map<String, Object?>) {
      throw const FormatException('Not an object');
    }
    return j;
  }

  /// Everything after the handshake, starting with anything already queued.
  Stream<Uint8List> rest() {
    final r = StreamController<Uint8List>();
    _queue.forEach(r.add);
    _queue.clear();
    if (_done) r.close();
    _rest = r;
    return r.stream;
  }

  void cancel() {
    _sub.cancel();
    for (final w in _waiters) {
      w.completeError(const SyncRefused('Cancelled'));
    }
    _waiters.clear();
  }
}
