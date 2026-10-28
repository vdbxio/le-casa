// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// "Hey, Gary" in the keyword spotter's word pieces (its bpe.model), with
/// the usual ways of saying it. `:` boosts the phrase, `#` is how sure the
/// spotter must be (lower hears more and wakes more by mistake), `@` the
/// name it reports.
const wakeKeywords = '''
▁HE Y ▁GA RY :2.0 #0.25 @hey gary
▁HI ▁GA RY :2.0 #0.25 @hey gary
▁O K ▁GA RY :2.0 #0.25 @hey gary
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
      if (m == 'wake') onWake();
    });
  }

  static const _files = [
    'encoder.onnx',
    'decoder.onnx',
    'joiner.onnx',
    'tokens.txt',
  ];

  /// Copies the model out of the app bundle (sherpa-onnx reads files) and
  /// starts the spotter. Throws when the model is not in this build.
  static Future<WakeWord> start(void Function() onWake) async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/kws',
    );
    await dir.create(recursive: true);
    for (final f in _files) {
      final data = await rootBundle.load('assets/voice/kws/$f');
      final out = File('${dir.path}/$f');
      if (!await out.exists() || await out.length() != data.lengthInBytes) {
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
    }
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_worker, (
      ready.sendPort,
      dir.path,
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

  /// 16 kHz mono samples in [-1, 1].
  void add(Float32List samples) =>
      _to.send(TransferableTypedData.fromList([samples]));

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
    }
  });
}
