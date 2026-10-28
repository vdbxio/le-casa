// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;
import 'dart:typed_data';

/// Cuts the microphone into utterances, so the engine only works when
/// someone speaks. A loudness gate over a running noise floor: cheap
/// enough to run all the time on a tablet.
class SpeechGate {
  static const rate = 16000;
  static const frame = 320; // 20 ms

  /// Speech must be this many times louder than the room...
  final double overFloor;

  /// ...and at least this loud (RMS of samples in [-1, 1]).
  final double minLevel;

  /// Quiet this long ends an utterance.
  final int endFrames;

  /// Kept from before the start, so the first sound is not clipped.
  final int prerollFrames;

  /// Frames of sound in a row before an utterance starts.
  final int startFrames;

  /// Utterances are cut at this length.
  final int maxFrames;

  /// Shorter ones are dropped as clicks and bumps.
  final int minFrames;

  SpeechGate({
    this.overFloor = 3,
    this.minLevel = 0.012,
    this.endFrames = 40,
    this.prerollFrames = 15,
    this.startFrames = 3,
    this.maxFrames = 500,
    this.minFrames = 20,
  });

  double floor = 0.005;
  final _pending = <double>[];
  final _preroll = <Float32List>[];
  final _speech = <Float32List>[];
  var _loud = 0;
  var _quiet = 0;

  /// Whether an utterance has started and not ended.
  bool get inSpeech => _speech.isNotEmpty;

  /// The latest frame's level over the floor, 0..1, for a level meter.
  double level = 0;

  /// Feeds microphone samples; returns each utterance that ended.
  List<Float32List> add(Float32List samples) {
    final done = <Float32List>[];
    _pending.addAll(samples);
    var at = 0;
    while (_pending.length - at >= frame) {
      final f = Float32List.fromList(_pending.sublist(at, at + frame));
      at += frame;
      final u = _frame(f);
      if (u != null) done.add(u);
    }
    _pending.removeRange(0, at);
    return done;
  }

  /// Ends any utterance now, as when the person taps stop.
  Float32List? flush() {
    if (_speech.isEmpty) return null;
    final out = _join(_speech);
    _reset();
    return out;
  }

  /// Drops all but the last [frames] of an utterance in progress, keeping
  /// the sound before it. For the wake word: what follows "Hey, Gary" in
  /// the same breath is already in here by the time the spotter hears it.
  void keepLast(int frames) {
    if (_speech.length > frames) {
      _speech.removeRange(0, _speech.length - frames);
    }
  }

  void _reset() {
    _speech.clear();
    _preroll.clear();
    _loud = 0;
    _quiet = 0;
  }

  Float32List? _frame(Float32List f) {
    var sum = 0.0;
    for (final s in f) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / f.length);
    final loud = rms > math.max(floor * overFloor, minLevel);
    level = (rms / math.max(floor * overFloor * 4, minLevel * 4)).clamp(0, 1);
    if (!loud) {
      // The floor follows the room down quickly and up slowly.
      floor = rms < floor
          ? floor * 0.9 + rms * 0.1
          : floor * 0.995 + rms * 0.005;
    }
    if (_speech.isEmpty) {
      _preroll.add(f);
      if (_preroll.length > prerollFrames) _preroll.removeAt(0);
      _loud = loud ? _loud + 1 : 0;
      if (_loud >= startFrames) {
        _speech.addAll(_preroll);
        _preroll.clear();
        _quiet = 0;
      }
      return null;
    }
    _speech.add(f);
    _quiet = loud ? 0 : _quiet + 1;
    if (_quiet >= endFrames || _speech.length >= maxFrames) {
      final keep = _speech.length - _quiet >= minFrames;
      final out = keep ? _join(_speech) : null;
      _reset();
      return out;
    }
    return null;
  }

  static Float32List _join(List<Float32List> fs) {
    final out = Float32List(fs.length * frame);
    for (var i = 0; i < fs.length; i++) {
      out.setAll(i * frame, fs[i]);
    }
    return out;
  }

  /// 16-bit little-endian PCM from the microphone to samples in [-1, 1].
  static Float32List fromPcm16(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final data = ByteData.sublistView(bytes);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}

/// "Hey, Gary" (or just "Gary") at the start of what Whistle heard, and
/// the rest of it. Null when the wake word is not there; the name said
/// later in a sentence does not count. Whistle spells the name a few ways;
/// the keyword bias keeps it mostly to "Gary".
String? afterWakeWord(String heard) {
  final m = RegExp(
    r"^\W*(?:(?:hey|hay|hi|ok|okay|a|eh)\W+)?(?:gary|garry|gerry|gari|garey|cary|carey)\b[\W]*(.*)$",
    caseSensitive: false,
  ).firstMatch(heard.trim());
  return m?[1]!.trim();
}
