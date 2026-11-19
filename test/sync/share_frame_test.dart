import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/leproto/leproto.dart';
import 'package:lecasa/sync/share_frame.dart';

void main() {
  final key = ShareKey(Uint8List.fromList(List.generate(32, (i) => i)));

  test('a frame seals and opens, as manufacturer data or a UUID', () {
    final f = shareSeal(
      key,
      '1a2b3c4d',
      0x01020304,
      const ShareValues(3, 9, 4, 13.27, -12.5),
    );
    expect(f.length, shareFrameLen);
    expect(f[0], shareMagic);
    expect(f[1], 0x1a);
    for (final heard in [
      shareFind({0xFFFF: f}, const []),
      shareFind(const {}, ['0000fcd2-0000-1000-8000-00805f9b34fb', lepUuid(f)]),
    ]) {
      expect(heard?.seq, 0x01020304);
      final v = shareOpen(key, '1a2b3c4d', heard!)!;
      expect((v.device, v.gen, v.at), (3, 9, 4));
      expect(v.a, closeTo(13.27, 0.01));
      expect(v.b, -12.5);
    }
    // Another screen with the same first byte, another key: no.
    final heard = shareFind({0xFFFF: f}, const [])!;
    expect(shareOpen(key, '1a2b3c4e', heard), isNull);
    expect(shareOpen(ShareKey(Uint8List(32)), '1a2b3c4d', heard), isNull);
    // A Le'Proto command or a sync advert is not a share frame.
    expect(shareFind({0xFFFF: Uint8List(16)..[0] = 0x4C}, const []), isNull);
    expect(shareFind({0xFFFF: Uint8List(12)..[0] = 0x53}, const []), isNull);
  });

  test('keep and missing values come through as such', () {
    final f = shareSeal(
      key,
      '1a2b3c4d',
      7,
      const ShareValues(0, 0, 0, null, null, hasB: false),
    );
    final v = shareOpen(key, '1a2b3c4d', shareFind({0xFFFF: f}, const [])!)!;
    expect((v.hasA, v.a), (true, null));
    expect(v.hasB, isFalse);
  });

  test('a status word goes as its code', () {
    final f = shareSeal(
      key,
      '1a2b3c4d',
      8,
      const ShareValues(0, 0, 0, null, 2.5, textA: 'Running'),
    );
    final v = shareOpen(key, '1a2b3c4d', shareFind({0xFFFF: f}, const [])!)!;
    expect(v.codeA, textCode('Running'));
    expect(v.a, isNull);
    expect((v.codeB, v.b), (null, 2.5));
    // Codes of the standard words do not collide.
    expect(standardWords.map(textCode).toSet().length, standardWords.length);
  });

  test('half floats hold dashboard numbers', () {
    for (final x in [0.0, 1.0, -1.0, 3.312, 70.5, 26.72, 1500.0, 0.001]) {
      expect(fromHalf(toHalf(x)), closeTo(x, x.abs() * 0.001 + 1e-6));
    }
    expect(fromHalf(toHalf(1e6)), double.infinity);
    expect(fromHalf(toHalf(double.nan)), isNull);
  });

  test('the sequence floor climbs four a second', () {
    final t = DateTime.utc(2026, 11, 17);
    expect(
      shareSeqFloor(t.add(const Duration(seconds: 1))) - shareSeqFloor(t),
      4,
    );
  });
}
