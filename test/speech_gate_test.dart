// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/voice/speech_gate.dart';

Float32List _tone(double seconds, double amp) {
  final n = (seconds * SpeechGate.rate).round();
  return Float32List.fromList([
    for (var i = 0; i < n; i++) amp * math.sin(i * 2 * math.pi * 220 / 16000),
  ]);
}

void main() {
  test('one utterance between quiet stretches', () {
    final g = SpeechGate();
    final out = [
      ...g.add(_tone(1, 0.001)),
      ...g.add(_tone(1.2, 0.3)),
      ...g.add(_tone(1.5, 0.001)),
    ];
    expect(out, hasLength(1));
    // The sound, plus pre-roll before and the quiet that ended it.
    final secs = out.single.length / SpeechGate.rate;
    expect(secs, greaterThan(1.2));
    expect(secs, lessThan(2.4));
  });

  test('a click is dropped', () {
    final g = SpeechGate();
    final out = [
      ...g.add(_tone(1, 0.001)),
      ...g.add(_tone(0.1, 0.5)),
      ...g.add(_tone(1.5, 0.001)),
    ];
    expect(out, isEmpty);
  });

  test('a steady hum is not speech', () {
    final g = SpeechGate(minLevel: 0.001);
    // A fan: the floor rises to meet it before it counts.
    final out = [for (var i = 0; i < 20; i++) ...g.add(_tone(0.5, 0.004))];
    expect(out.length, lessThanOrEqualTo(1));
    expect(g.add(_tone(2, 0.004)), isEmpty);
  });

  test('long speech is cut', () {
    final g = SpeechGate(maxFrames: 100);
    final out = g.add(_tone(5, 0.3));
    expect(out, isNotEmpty);
    expect(out.first.length, 100 * SpeechGate.frame);
  });

  test('flush ends speech on tap', () {
    final g = SpeechGate();
    g.add(_tone(0.5, 0.001));
    g.add(_tone(1, 0.3));
    expect(g.inSpeech, isTrue);
    expect(g.flush(), isNotNull);
    expect(g.inSpeech, isFalse);
  });

  test('keepLast keeps the end of speech in progress', () {
    final g = SpeechGate();
    g.add(_tone(0.5, 0.001));
    g.add(_tone(4, 0.3));
    g.keepLast(100);
    final out = g.add(_tone(1.5, 0.001));
    // Two seconds kept, plus the quiet that ended it.
    expect(out.single.length, (100 + g.endFrames) * SpeechGate.frame);
  });

  test('pcm16 to float', () {
    final b = Uint8List.fromList([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00]);
    expect(SpeechGate.fromPcm16(b), [-1.0, 32767 / 32768, 0.0]);
  });

  group('wake word', () {
    test('finds the command after it', () {
      expect(
        afterWakeWord('Hey, Gary, turn the lights blue.'),
        'turn the lights blue.',
      );
      expect(
        afterWakeWord('Hey Garry turn off the fridge'),
        'turn off the fridge',
      );
      expect(afterWakeWord('Gary. Lights off.'), 'Lights off.');
      expect(
        afterWakeWord('Okay Gary what is the battery at?'),
        'what is the battery at?',
      );
    });

    test('alone, waits for a command', () {
      expect(afterWakeWord('Hey, Gary.'), '');
      expect(afterWakeWord('Gary?'), '');
    });

    test('ignores the name later on', () {
      expect(afterWakeWord('I told Gary about it'), isNull);
      expect(afterWakeWord('Garrison Keillor'), isNull);
      expect(afterWakeWord(''), isNull);
    });
  });

  group('command in a transcript', () {
    test('the first sentence after the wake word', () {
      expect(
        commandIn('Hey Gary. Hey Gary, turn on the outside LEDs. Hey Gary'),
        'turn on the outside LEDs.',
      );
      expect(commandIn('Outside on.'), 'Outside on.');
      expect(commandIn('Hey, Gary.'), '');
    });

    test('a stream of TV talk is not a command', () {
      expect(
        commandIn(
          'when he turns to cover it up he is crying and the whole town '
          'knows it by now',
        ),
        isNull,
      );
    });
  });
}
