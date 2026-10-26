import 'dart:async';
import 'dart:typed_data';

import 'package:lecasa/ble/gatt_session.dart';

/// A scripted GATT device: fixed characteristics, canned read values, and
/// a hook that turns each write into zero or more notification chunks.
class FakeSession implements ClosableSession {
  @override
  final List<GattChar> characteristics;
  final Map<String, Uint8List> readValues;
  final List<Uint8List> Function(GattChar c, Uint8List data)? onWrite;
  final Map<String, List<Uint8List>> onSubscribe;
  final List<Uint8List> writes = [];
  final Map<String, StreamController<Uint8List>> _streams = {};
  bool closed = false;
  @override
  bool droppedByDevice = false;
  final _dropped = Completer<void>();

  /// Simulates the device ending the link.
  void drop() {
    droppedByDevice = true;
    if (!_dropped.isCompleted) _dropped.complete();
  }

  @override
  Future<void> get onDisconnected => _dropped.future;

  FakeSession({
    required this.characteristics,
    this.readValues = const {},
    this.onWrite,
    this.onSubscribe = const {},
  });

  @override
  Future<Uint8List> read(GattChar c) async =>
      readValues[c.uuid] ?? (throw StateError('no value for ${c.uuid}'));

  @override
  Future<void> write(
    GattChar c,
    Uint8List data, {
    bool withResponse = true,
  }) async {
    writes.add(data);
    final replies = onWrite?.call(c, data) ?? const [];
    // Replies arrive on whichever notify characteristic is subscribed.
    for (final r in replies) {
      for (final s in _streams.values) {
        s.add(r);
      }
    }
  }

  @override
  Future<Stream<Uint8List>> subscribe(GattChar c) async {
    final ctl = _streams.putIfAbsent(
      c.uuid,
      () => StreamController<Uint8List>.broadcast(),
    );
    // Values the device pushes on its own after subscription. A timer, not
    // a microtask, so the driver has listened by the time they arrive.
    final initial = onSubscribe[c.uuid];
    if (initial != null) {
      Future<void>.delayed(const Duration(milliseconds: 5), () {
        for (final v in initial) {
          ctl.add(v);
        }
      });
    }
    return ctl.stream;
  }

  @override
  Future<void> close() async {
    closed = true;
    for (final s in _streams.values) {
      await s.close();
    }
  }
}

/// Splits a frame into BLE-sized notification chunks.
List<Uint8List> chunked(Uint8List frame, [int size = 20]) => [
  for (var i = 0; i < frame.length; i += size)
    Uint8List.sublistView(
      frame,
      i,
      i + size > frame.length ? frame.length : i + size,
    ),
];
