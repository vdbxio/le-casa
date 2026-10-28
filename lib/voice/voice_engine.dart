// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'needle.dart';

/// Thrown when the engine or its models are not in this build, or the
/// engine reports an error.
class VoiceEngineError implements Exception {
  final String message;
  const VoiceEngineError(this.message);
  @override
  String toString() => message;
}

/// Cactus's engine on a worker isolate of its own, since it is one
/// process-global model that blocks while it thinks. Requests queue: the
/// worker answers them one at a time.
class VoiceEngine {
  final SendPort _to;
  final ReceivePort _from;
  final Isolate _isolate;
  final _waiting = <int, Completer<Object?>>{};
  var _next = 0;

  VoiceEngine._(this._to, this._from, this._isolate) {
    _from.listen((m) {
      final (id, ok, value) = m as (int, bool, Object?);
      final c = _waiting.remove(id);
      if (c == null) return;
      ok ? c.complete(value) : c.completeError(VoiceEngineError('$value'));
    });
  }

  /// Starts the worker and loads the models from the .cact files at
  /// [needle] and [whistle]. Without [needle] it only transcribes.
  static Future<VoiceEngine> start(String? needle, String whistle) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _worker,
      ready.sendPort,
      debugName: 'voice',
    );
    final from = ReceivePort();
    final to = await ready.first as SendPort;
    to.send(from.sendPort);
    final e = VoiceEngine._(to, from, isolate);
    try {
      await e._ask('load', [?needle, whistle]);
    } catch (_) {
      e.dispose();
      rethrow;
    }
    return e;
  }

  Future<Object?> _ask(String op, Object? arg) {
    final id = _next++;
    final c = _waiting[id] = Completer<Object?>();
    _to.send((id, op, arg));
    return c.future;
  }

  /// Sets the tools Needle may call and the words Whistle should favour.
  /// Call again when devices come and go.
  Future<void> configure({
    required String system,
    required List<Map<String, Object?>> tools,
    required List<String> keywords,
  }) => _ask('init', (system, jsonEncode(tools), keywords.join('\n')));

  /// Speech to text: 16 kHz mono samples in [-1, 1].
  Future<Map<String, Object?>> transcribe(
    Float32List pcm, {
    bool keywords = true,
  }) async => (await _ask('transcribe', (
    TransferableTypedData.fromList([pcm]),
    keywords,
  )) as Map).cast();

  /// One turn: what was said ([pcm]) or typed ([text]) in, Needle's JSON
  /// answer out, with the transcript under `audio_text` for speech.
  Future<Map<String, Object?>> complete({
    String? text,
    Float32List? pcm,
  }) async {
    assert((text == null) != (pcm == null));
    return (await _ask('complete', (
      text,
      pcm == null ? null : TransferableTypedData.fromList([pcm]),
    )) as Map).cast();
  }

  void dispose() {
    for (final c in _waiting.values) {
      c.completeError(const VoiceEngineError('Voice stopped'));
    }
    _waiting.clear();
    _from.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

const _outBytes = 1 << 18;

void _worker(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  SendPort? reply;
  final out = calloc<Uint8>(_outBytes).cast<Utf8>();
  var keywords = nullptr.cast<Utf8>();
  final english = 'en'.toNativeUtf8();

  String lastError() {
    final p = needle_last_error();
    return p == nullptr ? 'unknown error' : p.toDartString();
  }

  Map<String, Object?> parse(int rc) {
    final s = out.toDartString();
    if (rc < 0) throw VoiceEngineError(s.isNotEmpty ? s : lastError());
    return (jsonDecode(s) as Map).cast();
  }

  Pointer<Float> samples(TransferableTypedData t, void Function(int) n) {
    final pcm = t.materialize().asFloat32List();
    final p = calloc<Float>(pcm.isEmpty ? 1 : pcm.length);
    p.asTypedList(pcm.length).setAll(0, pcm);
    n(pcm.length);
    return p;
  }

  inbox.listen((m) {
    if (m is SendPort) {
      reply = m;
      return;
    }
    final (id, op, arg) = m as (int, String, Object?);
    try {
      final watch = Stopwatch()..start();
      Object? result;
      switch (op) {
        case 'load':
          for (final path in arg as List) {
            // Read straight into native memory, with no copy on the Dart
            // heap. Kept for the life of the process: the engine uses the
            // weights where they lie.
            final f = File(path as String).openSync();
            try {
              final n = f.lengthSync();
              final p = malloc<Uint8>(n);
              final view = p.asTypedList(n);
              var at = 0;
              while (at < n) {
                final got = f.readIntoSync(
                  view,
                  at,
                  math.min(n, at + (1 << 20)),
                );
                if (got <= 0) throw VoiceEngineError('Short read of $path');
                at += got;
              }
              if (needle_load(p, n) < 0) throw VoiceEngineError(lastError());
            } finally {
              f.closeSync();
            }
          }
          final want = (arg.length > 1 ? needleText : 0) | needleSpeech;
          if (needle_models() & want != want) {
            throw const VoiceEngineError('A voice model did not load');
          }
        case 'init':
          final (system, tools, words) = arg as (String, String, String);
          final s = system.toNativeUtf8();
          final t = tools.toNativeUtf8();
          try {
            if (needle_models() & needleText != 0 &&
                needle_init(s, t, nullptr) < 0) {
              throw VoiceEngineError(lastError());
            }
          } finally {
            calloc.free(s);
            calloc.free(t);
          }
          if (keywords != nullptr) calloc.free(keywords);
          keywords = words.isEmpty ? nullptr : words.toNativeUtf8();
          needle_set_audio(english, keywords, 0);
        case 'transcribe':
          final (t, biased) = arg as (TransferableTypedData, bool);
          var n = 0;
          final p = samples(t, (c) => n = c);
          try {
            result = parse(
              needle_transcribe(
                p,
                n,
                english,
                biased ? keywords : nullptr,
                0,
                out,
                _outBytes,
              ),
            );
          } finally {
            calloc.free(p);
          }
        case 'complete':
          final (text, t) = arg as (String?, TransferableTypedData?);
          // Every command stands alone.
          needle_reset();
          if (text != null) {
            final s = text.toNativeUtf8();
            try {
              result = parse(
                needle_complete(s, nullptr, 0, 512, out, _outBytes),
              );
            } finally {
              calloc.free(s);
            }
          } else {
            var n = 0;
            final p = samples(t!, (c) => n = c);
            try {
              result = parse(
                needle_complete(nullptr, p, n, 512, out, _outBytes),
              );
            } finally {
              calloc.free(p);
            }
          }
      }
      if (result is Map) result['ms'] = watch.elapsedMilliseconds;
      reply!.send((id, true, result));
    } catch (e) {
      reply!.send((id, false, '$e'));
    }
  });
}
