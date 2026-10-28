// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/voice/wake_share.dart';

void main() {
  final at = DateTime(2026, 10, 28, 5, 20);

  test('the screen that heard it most clearly answers', () {
    final peers = [PeerWake('bbbb0000', 30, at)];
    expect(answeredBy('aaaa0000', 18, at, peers)?.screen, 'bbbb0000');
    expect(answeredBy('aaaa0000', 34, at, peers), isNull);
  });

  test('a tie goes to one screen only', () {
    final a = answeredBy('aaaa0000', 20, at, [PeerWake('bbbb0000', 20, at)]);
    final b = answeredBy('bbbb0000', 20, at, [PeerWake('aaaa0000', 20, at)]);
    expect(a?.screen, 'bbbb0000');
    expect(b, isNull);
  });

  test('an older wake word is another command', () {
    final old = at.subtract(const Duration(seconds: 5));
    expect(
      answeredBy('aaaa0000', 10, at, [PeerWake('bbbb0000', 40, old)]),
      isNull,
    );
  });

  test("an iPhone's claim that arrives late still counts", () {
    final late = at.add(const Duration(milliseconds: 3600));
    expect(
      answeredBy('aaaa0000', 10, at, [PeerWake('bbbb0000', 12, late)])?.screen,
      'bbbb0000',
    );
  });

  test('a claim from an earlier wake word does not count', () {
    final old = at.subtract(const Duration(seconds: 27));
    expect(
      answeredBy('aaaa0000', 1, at, [PeerWake('bbbb0000', 1, old)]),
      isNull,
    );
  });
}
