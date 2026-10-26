// Replays a GATT trace recorded from aiobmsble's own test suite (see
// tool/aiobmsble/) against a Dart BMS driver.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';

import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';

bool debug = false;

class TraceSession implements GattSession {
  final List<Map<String, dynamic>> io;
  int _pos = 0;
  final List<String> mismatches = [];
  @override
  final List<GattChar> characteristics = [];
  final Map<int, GattChar> _byHandle = {};
  final Map<GattChar, int> _handleOf = {};
  final Map<String, StreamController<Uint8List>> _streams = {};

  TraceSession(List<Map<String, dynamic>> events) : io = events {
    final connect = events.where((e) => e['e'] == 'connect').toList();
    final svcs = connect.isEmpty
        ? const []
        : (connect.first['services'] as List? ?? const []);
    for (final s in svcs) {
      if (s is! Map || s['c'] == null) continue;
      final p = (s['p'] as List).cast<String>();
      final c = GattChar(
        s['c'] as String,
        service: s['s'] as String?,
        canRead: p.contains('read'),
        canWrite: p.contains('write'),
        canWriteWithoutResponse: p.contains('write-without-response'),
        canNotify: p.contains('notify') || p.contains('indicate'),
      );
      characteristics.add(c);
      _byHandle[s['h'] as int] = c;
      _handleOf[c] = s['h'] as int;
    }
    for (final e in io) {
      if (e['c'] == null) continue;
      final u = _uuid(e['c'] as String);
      if (u == null) continue;
      if (characteristics.any((c) => c.uuid == u)) continue;
      characteristics.add(
        GattChar(
          u,
          canRead: true,
          canWrite: false,
          canWriteWithoutResponse: true,
          canNotify: true,
        ),
      );
    }
  }

  static String? _uuid(String spec) {
    if (spec.startsWith('handle:')) return null;
    return spec.split('#').first;
  }

  bool _same(GattChar c, String spec) {
    if (spec.startsWith('handle:')) {
      return _byHandle[int.parse(spec.substring(7))] == c;
    }
    final parts = spec.split('#');
    if (parts.length == 2 && _handleOf.containsKey(c)) {
      return _handleOf[c] == int.parse(parts[1]);
    }
    return c.uuid == parts.first;
  }

  bool get exhausted => _pos >= io.length;

  final Map<String, List<Uint8List>> _pending = {};

  static const markers = {
    'update',
    'info_req',
    'result',
    'info',
    'error',
    'disconnect',
  };

  /// The replay reached the step that starts at event [index]. Anything
  /// the driver did not consume before it is dropped, and notifications
  /// right after it (pushed by the device on its own) are delivered.
  void enter(int index) {
    if (index + 1 > _pos) _pos = index + 1;
    // After a step has returned the driver is idle, so what the device
    // pushes before the next call is all in by then.
    _deliverFollowing(
      spontaneous: true,
      between: const {'result', 'info', 'error'}.contains(io[index]['e']),
    );
  }

  /// Delivers the notifications that follow the event just consumed.
  /// Those the Python mock sent from inside the BMS's own call (same asyncio
  /// task) arrive before that call returns; those a mock task pushed arrive
  /// together once the driver has gone back to waiting, the way asyncio
  /// runs every ready task before it resumes a waiter.
  /// [inlineOk] is false where no listener can be attached yet.
  void _deliverFollowing({
    bool spontaneous = false,
    bool inlineOk = true,
    bool between = false,
  }) {
    final inline = <(String, Uint8List)>[];
    final bursts = <List<(String, Uint8List)>>[];
    int? lastTask;
    while (_pos < io.length &&
        const {
          'rx',
          'notify_on',
          'connect',
          'notify_off',
        }.contains(io[_pos]['e'])) {
      final e = io[_pos++];
      if (e['e'] != 'rx') continue;
      final spec = e['c'] as String;
      final data = fromHex(e['d'] as String);
      final GattChar? target = spec.startsWith('handle:')
          ? _byHandle[int.parse(spec.substring(7))]
          : null;
      final uuid = target?.uuid ?? _uuid(spec)!;
      if (!_streams.containsKey(uuid)) {
        _pending.putIfAbsent(uuid, () => []).add(data);
        continue;
      }
      final task = (e['k'] as int?) ?? 1;
      if (between || (task == 0 && !spontaneous && inlineOk)) {
        inline.add((uuid, data));
      } else {
        if (bursts.isEmpty || task != lastTask) bursts.add([]);
        bursts.last.add((uuid, data));
        lastTask = task;
      }
    }
    _emit(inline);
    if (bursts.isNotEmpty) {
      Future<void>(() {
        for (final b in bursts) {
          _emit(b);
        }
      });
    }
  }

  final _emitQueue = <(String, Uint8List)>[];
  bool _emitting = false;

  /// Delivers [items] in order. A handler that writes while being called
  /// can trigger more inline rx; that is queued behind the current item
  /// instead of re-entering the stream controller.
  void _emit(List<(String, Uint8List)> items) {
    _emitQueue.addAll(items);
    if (_emitting) return;
    _emitting = true;
    try {
      while (_emitQueue.isNotEmpty) {
        final (uuid, data) = _emitQueue.removeAt(0);
        if (debug) print('RX ${hex(data, sep: '')}');
        final ctl = _streams[uuid];
        if (ctl != null && !ctl.isClosed) ctl.add(data);
      }
    } finally {
      _emitting = false;
    }
  }

  Map<String, dynamic>? _next(String kind) {
    // rx left over from an earlier step arrived after Python had moved on.
    _deliverFollowing();
    if (_pos >= io.length) {
      mismatches.add('unexpected $kind after end of trace');
      return null;
    }
    final e = io[_pos];
    if (markers.contains(e['e'])) {
      mismatches.add('$kind beyond the end of the step (next: ${e['e']})');
      return null;
    }
    if (e['e'] != kind) {
      mismatches.add('expected ${e['e']} ${e['c']} ${e['d'] ?? ''}, got $kind');
      return null;
    }
    _pos++;
    return e;
  }

  @override
  Future<Uint8List> read(GattChar c) async {
    final e = _next('read');
    if (e == null || !_same(c, e['c'] as String)) {
      if (e != null) mismatches.add('read ${c.uuid}, trace has ${e['c']}');
      throw TimeoutException('trace mismatch');
    }
    _raise(e);
    final v = fromHex(e['d'] as String);
    _deliverFollowing();
    return v;
  }

  @override
  Future<void> write(
    GattChar c,
    Uint8List data, {
    bool withResponse = true,
  }) async {
    if (debug) print('W ${hex(data, sep: '')} pos=$_pos');
    final e = _next('write');
    if (e == null) {
      throw TimeoutException('trace mismatch on write ${hex(data, sep: '')}');
    }
    final want = e['d'] as String;
    final got = hex(data, sep: '');
    if (!_same(c, e['c'] as String) || want != got) {
      mismatches.add('write ${c.uuid} $got, trace has ${e['c']} $want');
      throw TimeoutException('trace mismatch');
    }
    _raise(e);
    _deliverFollowing();
  }

  void _raise(Map<String, dynamic> e) {
    switch (e['raise']) {
      case null:
        return;
      case 'TimeoutError':
        throw TimeoutException('recorded write timeout');
      case 'BleakCharacteristicNotFoundError':
        throw const UnsupportedDeviceException(
          'recorded: no such characteristic',
        );
      default:
        throw Exception('recorded ${e['raise']}');
    }
  }

  @override
  Future<Stream<Uint8List>> subscribe(GattChar c) async {
    final ctl = _streams.putIfAbsent(
      c.uuid,
      () => StreamController<Uint8List>.broadcast(sync: true),
    );
    final pending = _pending.remove(c.uuid);
    if (pending != null) {
      Future<void>(() => _emit([for (final d in pending) (c.uuid, d)]));
    }
    _deliverFollowing(inlineOk: false);
    return ctl.stream;
  }
}
