// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/voice/wake_word.dart';

void main() {
  // sherpa-onnx reads each line as word pieces then :boost #threshold
  // @name, split at spaces, and exits the app when a piece is not in its
  // tokens: a space in the name ("@hey gary") killed it on the M10.
  test('wake keywords are pieces, then options with no spaces', () {
    final lines = wakeKeywords.trim().split('\n');
    expect(lines, isNotEmpty);
    for (final l in lines) {
      final parts = l.trim().split(' ');
      final options = parts.skipWhile((p) => !RegExp('^[:#@]').hasMatch(p));
      final pieces = parts.takeWhile((p) => !RegExp('^[:#@]').hasMatch(p));
      expect(pieces, isNotEmpty, reason: l);
      expect(options.map((o) => o[0]), [':', '#', '@'], reason: l);
      for (final p in pieces) {
        // The model's pieces are upper case, optionally after ▁.
        expect(p, matches(RegExp(r'^▁?[A-Z]+$')), reason: l);
      }
    }
  });
}
