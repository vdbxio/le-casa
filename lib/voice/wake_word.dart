// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asset_files.dart';

/// "Hey, Gary" in the keyword spotter's word pieces (its bpe.model), with
/// the usual ways of saying it. `:` boosts the phrase, `#` is how sure the
/// spotter must be (lower hears more and wakes more by mistake), `@` the
/// name it reports.
const wakeKeywords = '''
▁HE Y ▁GA RY :2.0 #0.25 @hey_gary
▁HI ▁GA RY :2.0 #0.25 @hey_gary
▁O K ▁GA RY :2.0 #0.25 @hey_gary
''';

/// Listens for "Hey, Gary" with sherpa-onnx's keyword spotter: a tiny
/// streaming speech model that only ever looks for the phrase, so a TV or a
/// conversation in the room does not wake it and nothing said is written
/// down. It runs on a worker isolate; feed it the mic and it calls back.
class WakeWord {
  final SendPort _to;
  final ReceivePort _from;
  final Isolate _isolate;

  WakeWord._(this._to, this._from, this._isolate, void Function() onWake) {
    _from.listen((m) {
      if (m == 'wake') {
        onWake();
      } else if (m is int) {
        _inFlight--;
        _busyUs += m;
      }
    });
  }

  /// Chunks sent and not yet decoded. A slow chip that falls behind would
  /// otherwise queue the mic up in memory until Android kills the app.
  var _inFlight = 0;
  static const _maxInFlight = 8;
  var _dropped = 0;
  var _busyUs = 0;
  var _heardUs = 0;
  final _since = Stopwatch()..start();

  static const _files = [
    'encoder.onnx',
    'decoder.onnx',
    'joiner.onnx',
    'tokens.txt',
  ];

  /// Copies the model out of the app bundle once (sherpa-onnx reads files)
  /// and starts the spotter. Throws when the model is not in this build.
  static Future<WakeWord> start(void Function() onWake) async {
    String? dir;
    for (final f in _files) {
      dir = File(await voiceFile('assets/voice/kws/$f')).parent.path;
    }
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_worker, (
      ready.sendPort,
      dir!,
    ), debugName: 'wake word');
    final first = await ready.first;
    if (first is String) {
      isolate.kill();
      throw StateError(first);
    }
    final from = ReceivePort();
    final to = first as SendPort;
    to.send(from.sendPort);
    return WakeWord._(to, from, isolate, onWake);
  }

  /// 16 kHz mono samples in [-1, 1]. Dropped while the spotter is behind.
  void add(Float32List samples) {
    if (_inFlight >= _maxInFlight) {
      _dropped++;
    } else {
      _inFlight++;
      _heardUs += samples.length * 1000000 ~/ 16000;
      _to.send(TransferableTypedData.fromList([samples]));
    }
    if (_since.elapsed.inSeconds >= 30) {
      // How hard the spotter works per second of sound, for slow tablets.
      debugPrint(
        'voice: wake word decoded ${_heardUs ~/ 1000} ms of sound in '
        '${_busyUs ~/ 1000} ms, dropped $_dropped chunks',
      );
      _since.reset();
      _busyUs = _heardUs = _dropped = 0;
    }
  }

  /// Forgets what it has heard, after a command.
  void reset() => _to.send('reset');

  void dispose() {
    _from.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _worker((SendPort, String) args) {
  final (ready, dir) = args;
  final sherpa.KeywordSpotter kws;
  try {
    sherpa.initBindings();
    kws = sherpa.KeywordSpotter(
      sherpa.KeywordSpotterConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$dir/encoder.onnx',
            decoder: '$dir/decoder.onnx',
            joiner: '$dir/joiner.onnx',
          ),
          tokens: '$dir/tokens.txt',
          numThreads: 1,
          debug: false,
        ),
        keywordsBuf: wakeKeywords,
        keywordsBufSize: utf8.encode(wakeKeywords).length,
      ),
    );
  } catch (e) {
    ready.send('The wake word could not start: $e');
    return;
  }
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  var stream = kws.createStream();
  SendPort? reply;
  inbox.listen((m) {
    if (m is SendPort) {
      reply = m;
    } else if (m == 'reset') {
      stream.free();
      stream = kws.createStream();
    } else if (m is TransferableTypedData) {
      final watch = Stopwatch()..start();
      stream.acceptWaveform(
        samples: m.materialize().asFloat32List(),
        sampleRate: 16000,
      );
      while (kws.isReady(stream)) {
        kws.decode(stream);
        if (kws.getResult(stream).keyword.isNotEmpty) {
          kws.reset(stream);
          reply?.send('wake');
        }
      }
      reply?.send(watch.elapsedMicroseconds);
    }
  });
}
