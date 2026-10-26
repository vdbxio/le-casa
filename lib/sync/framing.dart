// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Splits sync messages into GATT-sized chunks and joins them again. GATT
// writes with response and notifications on one link arrive in order, so
// one header byte is enough: the top bit marks the last chunk of a
// message.

import 'dart:async';
import 'dart:typed_data';

/// Moves raw chunks over one link. The BLE hub and member sides implement
/// it; tests wire two of them together in memory.
abstract interface class ChunkLink {
  /// Largest chunk the other side can take, header byte included.
  int get maxChunk;

  Future<void> sendChunk(Uint8List chunk);

  Stream<Uint8List> get chunks;

  /// Completes when the link goes away.
  Future<void> get closed;

  Future<void> close();
}

const _last = 0x80;

/// Whole messages over a [ChunkLink]. Sends one message at a time so
/// chunks of two messages never interleave.
class MessageLink {
  final ChunkLink link;
  final _out = StreamController<Uint8List>.broadcast();
  final _pending = BytesBuilder(copy: false);
  StreamSubscription? _sub;
  Future<void> _queue = Future.value();

  /// Stops a peer from making us buffer without end.
  static const maxMessage = 256 * 1024;

  /// A chunk the other end never acknowledges would hold up every later
  /// message while the link still looks up. Give up and close instead.
  static const chunkTimeout = Duration(seconds: 15);

  MessageLink(this.link) {
    _sub = link.chunks.listen(_onChunk, onDone: _out.close);
  }

  Stream<Uint8List> get messages => _out.stream;

  void _onChunk(Uint8List c) {
    if (c.isEmpty) return;
    _pending.add(Uint8List.sublistView(c, 1));
    if (_pending.length > maxMessage) {
      _pending.clear();
      return;
    }
    if (c[0] & _last != 0) _out.add(_pending.takeBytes());
  }

  Future<void> send(Uint8List message) {
    final f = _queue.then((_) => _send(message));
    // Keep the queue going after a failed send; the caller sees the error.
    _queue = f.catchError((_) {});
    return f;
  }

  Future<void> _send(Uint8List m) async {
    final room = link.maxChunk - 1;
    if (room < 1) throw StateError('Link too small');
    var i = 0;
    do {
      final end = (i + room).clamp(0, m.length);
      final chunk = Uint8List(1 + end - i);
      chunk[0] = end == m.length ? _last : 0;
      chunk.setRange(1, chunk.length, m, i);
      try {
        await link.sendChunk(chunk).timeout(chunkTimeout);
      } on TimeoutException {
        unawaited(close());
        rethrow;
      }
      i = end;
    } while (i < m.length);
  }

  Future<void> close() async {
    await _sub?.cancel();
    await link.close();
    if (!_out.isClosed) await _out.close();
  }
}
