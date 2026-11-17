// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Le'Proto share frame: live readings from one screen to the others of its
// home as a 16-byte advert, so a screen like the M10 (which hears next to
// nothing while it holds a GATT link) gets them without connecting. The
// first visit still carries the whole reading (labels, units, text); the
// frames then refresh its numbers two at a time. See docs/sync.md.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'crypto.dart';

/// First byte of a share frame ('S'), on air as manufacturer data 0xFFFF
/// (Android) or as the first byte of a 128-bit service UUID (iOS).
const int shareMagic = 0x53;
const int shareFrameLen = 16;

/// A half-float that means "keep the value you have" (text, or a value
/// that does not fit): a quiet NaN with a payload.
const int _keep = 0x7E01;
const int _nan = 0x7E00;

/// Seconds since 2026-11-01 times four: a floor for the sequence number,
/// so a restarted screen still climbs past what the others last took.
int shareSeqFloor(DateTime now) =>
    now.toUtc().difference(DateTime.utc(2026, 11)).inMilliseconds ~/ 250;

class ShareKey {
  final Uint8List key;
  ShareKey(Uint8List homeKey)
    : key = hkdf(homeKey, Uint8List(0), 'LeCasa share v0', 16);
}

/// What one frame says: the [index] and [gen] of a device in the sender's
/// share table, and the values of its readings [at] and [at] + 1.
class ShareValues {
  final int device;
  final int gen;
  final int at;
  final double? a;
  final double? b;

  /// False where the frame said to keep the value already held.
  final bool hasA;
  final bool hasB;

  const ShareValues(
    this.device,
    this.gen,
    this.at,
    this.a,
    this.b, {
    this.hasA = true,
    this.hasB = true,
  });
}

/// A frame heard: who sent it (the first byte of its screen id) and the
/// sealed bytes, opened later against each screen that byte could be.
class HeardShare {
  final int src;
  final int seq;
  final Uint8List frame;
  const HeardShare(this.src, this.seq, this.frame);
}

Uint8List _nonce(Uint8List screen4, int seq) => Uint8List.fromList([
  ...screen4,
  seq & 0xFF,
  (seq >> 8) & 0xFF,
  (seq >> 16) & 0xFF,
  (seq >> 24) & 0xFF,
  ...ascii.encode('LeCaS'),
]);

Uint8List _screen4(String shortScreen) {
  final out = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    out[i] = int.parse(shortScreen.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Seals one frame. [screen] is the sender's [shortScreen] id (8 hex).
Uint8List shareSeal(ShareKey k, String screen, int seq, ShareValues v) {
  final s4 = _screen4(screen);
  final header = Uint8List.fromList([
    shareMagic,
    s4[0],
    seq & 0xFF,
    (seq >> 8) & 0xFF,
    (seq >> 16) & 0xFF,
    (seq >> 24) & 0xFF,
  ]);
  final a = v.hasA ? toHalf(v.a) : _keep;
  final b = v.hasB ? toHalf(v.b) : _keep;
  final plain = Uint8List.fromList([
    (v.device & 0xF) << 4 | (v.gen & 0xF),
    v.at & 0xFF,
    a & 0xFF,
    a >> 8,
    b & 0xFF,
    b >> 8,
  ]);
  final ccm = CCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(k.key), 32, _nonce(s4, seq), header),
    );
  return Uint8List.fromList([...header, ...ccm.process(plain)]);
}

/// The frame in an advert, or null: manufacturer data 0xFFFF of 16 bytes
/// starting with [shareMagic], or a 128-bit UUID whose on-air first byte is.
HeardShare? shareFind(Map<int, Uint8List> mfr, List<String> longUuids) {
  Uint8List? f;
  final m = mfr[0xFFFF];
  if (m != null && m.length == shareFrameLen && m[0] == shareMagic) f = m;
  if (f == null) {
    for (final u in longUuids) {
      final h = u.replaceAll('-', '');
      if (h.length != 32) continue;
      final bytes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        bytes[15 - i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
      }
      if (bytes[0] == shareMagic) {
        f = bytes;
        break;
      }
    }
  }
  if (f == null) return null;
  final seq = f[2] | f[3] << 8 | f[4] << 16 | f[5] << 24;
  return HeardShare(f[1], seq, f);
}

/// Opens [h] as sent by [screen], or null if the MIC does not verify.
ShareValues? shareOpen(ShareKey k, String screen, HeardShare h) {
  final s4 = _screen4(screen);
  if (s4[0] != h.src) return null;
  try {
    final ccm = CCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(k.key),
          32,
          _nonce(s4, h.seq),
          Uint8List.sublistView(h.frame, 0, 6),
        ),
      );
    final p = ccm.process(Uint8List.sublistView(h.frame, 6));
    final a = p[2] | p[3] << 8;
    final b = p[4] | p[5] << 8;
    return ShareValues(
      p[0] >> 4,
      p[0] & 0xF,
      p[1],
      fromHalf(a),
      fromHalf(b),
      hasA: a != _keep,
      hasB: b != _keep,
    );
  } on InvalidCipherTextException {
    return null;
  } on StateError {
    // pointycastle's CCM says "mac check in CCM failed" this way.
    return null;
  } on ArgumentError {
    return null;
  }
}

/// IEEE 754 half precision, round to nearest; null and NaN as NaN. Good to
/// about three significant figures: 13.27 V, 70.5 %, 3.312 V a cell.
int toHalf(double? v) {
  if (v == null || v.isNaN) return _nan;
  final bits = ByteData(4)..setFloat32(0, v);
  final f = bits.getUint32(0);
  final sign = (f >> 16) & 0x8000;
  var exp = ((f >> 23) & 0xFF) - 127 + 15;
  var mant = f & 0x7FFFFF;
  if (exp >= 31) return sign | 0x7C00; // too big: infinity
  if (exp <= 0) {
    if (exp < -10) return sign; // too small: zero
    mant |= 0x800000;
    final shift = 14 - exp;
    var half = mant >> shift;
    if ((mant >> (shift - 1)) & 1 != 0) half++;
    return sign | half;
  }
  var half = sign | exp << 10 | mant >> 13;
  if (mant & 0x1000 != 0) half++; // may carry into the exponent, which is right
  return half;
}

double? fromHalf(int h) {
  final sign = h & 0x8000 != 0 ? -1.0 : 1.0;
  final exp = (h >> 10) & 0x1F;
  final mant = h & 0x3FF;
  if (exp == 31) return mant == 0 ? sign * double.infinity : null;
  if (exp == 0) return sign * mant / 1024 * 6.103515625e-05;
  return sign * (1 + mant / 1024) * _pow2(exp - 15);
}

double _pow2(int e) {
  var r = 1.0;
  for (var i = 0; i < e.abs(); i++) {
    r *= 2;
  }
  return e < 0 ? 1 / r : r;
}
