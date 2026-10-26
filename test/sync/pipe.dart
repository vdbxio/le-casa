import 'dart:async';
import 'dart:typed_data';

import 'package:lecasa/sync/framing.dart';

/// Two [ChunkLink] ends joined in memory, with a small chunk size so
/// messages really get split.
class PipeEnd implements ChunkLink {
  @override
  final int maxChunk;
  final _in = StreamController<Uint8List>();
  late PipeEnd _other;
  final _closed = Completer<void>();

  /// Every chunk this end sent, for tests that look at the air.
  final List<Uint8List> sent = [];

  PipeEnd._(this.maxChunk);

  static (PipeEnd, PipeEnd) pair({int maxChunk = 20}) {
    final a = PipeEnd._(maxChunk);
    final b = PipeEnd._(maxChunk);
    a._other = b;
    b._other = a;
    return (a, b);
  }

  @override
  Stream<Uint8List> get chunks => _in.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> sendChunk(Uint8List chunk) async {
    if (_closed.isCompleted) throw StateError('closed');
    if (chunk.length > maxChunk) throw StateError('chunk too big');
    sent.add(chunk);
    _other._in.add(Uint8List.fromList(chunk));
  }

  @override
  Future<void> close() async {
    for (final e in [this, _other]) {
      if (!e._closed.isCompleted) {
        e._closed.complete();
        await e._in.close();
      }
    }
  }
}

(MessageLink, MessageLink) messagePipe({int maxChunk = 20}) {
  final (a, b) = PipeEnd.pair(maxChunk: maxChunk);
  return (MessageLink(a), MessageLink(b));
}
