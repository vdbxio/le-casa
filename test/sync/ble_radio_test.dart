import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/sync/ble_radio.dart';

void main() {
  group('a link this screen gives up on', () {
    const settle = Duration(milliseconds: 50);

    test('is disconnected at once when nothing is in flight', () async {
      var disconnected = false;
      final done = await disconnectWhenIdle(
        null,
        () async => disconnected = true,
        'test',
        settle: settle,
      );
      expect(done, isTrue);
      expect(disconnected, isTrue);
    });

    test('waits for its last write to finish first', () async {
      final write = Completer<void>();
      var disconnected = false;
      final done = disconnectWhenIdle(
        write.future,
        () async => disconnected = true,
        'test',
        settle: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(disconnected, isFalse);
      write.complete();
      expect(await done, isTrue);
      expect(disconnected, isTrue);
    });

    test('is disconnected after a write that failed', () async {
      var disconnected = false;
      final done = await disconnectWhenIdle(
        Future<void>.error(StateError('write failed')),
        () async => disconnected = true,
        'test',
        settle: settle,
      );
      expect(done, isTrue);
      expect(disconnected, isTrue);
    });

    test('is left alone while a write stays stuck', () async {
      var disconnected = false;
      final done = await disconnectWhenIdle(
        Completer<void>().future,
        () async => disconnected = true,
        'test',
        settle: settle,
      );
      expect(done, isFalse);
      expect(disconnected, isFalse, reason: 'that disconnect crashed the M10');
    });
  });

  test('sync chunks fit one Bluetooth packet', () {
    expect(syncChunkMax, lessThanOrEqualTo(244));
  });
}
