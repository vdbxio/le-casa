// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// The cryptography behind screen sync. Every screen in a home shares one
// 32-byte home key, handed over once at pairing time inside an ECDH
// (P-256) channel whose six-digit code both people compare. After that,
// each link derives fresh AES-GCM keys from the home key and two random
// nonces, so nothing travels over the air in the clear but the handshake.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

final _curve = ECDomainParameters('secp256r1');

SecureRandom _seeded() {
  final r = Random.secure();
  return FortunaRandom()..seed(
    KeyParameter(Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)))),
  );
}

final SecureRandom _random = _seeded();

Uint8List randomBytes(int n) => _random.nextBytes(n);

Uint8List sha256(List<int> data) =>
    SHA256Digest().process(Uint8List.fromList(data));

/// HKDF-SHA256 (RFC 5869).
Uint8List hkdf(Uint8List ikm, Uint8List salt, String info, [int length = 32]) {
  final d = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(ikm, length, salt, utf8.encode(info)));
  final out = Uint8List(length);
  d.deriveKey(null, 0, out, 0);
  return out;
}

/// A P-256 key pair for one pairing attempt. Never stored.
class EphemeralKey {
  final ECPrivateKey _private;

  /// Uncompressed public point, 65 bytes.
  final Uint8List public;

  EphemeralKey._(this._private, this.public);

  factory EphemeralKey.generate() {
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), _random));
    final pair = gen.generateKeyPair();
    return EphemeralKey._(pair.privateKey, pair.publicKey.Q!.getEncoded(false));
  }

  /// The shared secret with [peerPublic]. Throws on a point that is not on
  /// the curve.
  Uint8List agree(Uint8List peerPublic) {
    final q = _curve.curve.decodePoint(peerPublic);
    if (q == null || q.isInfinity) throw const FormatException('Bad key');
    final a = ECDHBasicAgreement()..init(_private);
    final z = a.calculateAgreement(ECPublicKey(q, _curve));
    return _bigToBytes(z, 32);
  }
}

Uint8List _bigToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

/// The number both screens show while pairing. Mixes both public keys,
/// both nonces and the shared secret, so a device in the middle ends up
/// with a different number on each side.
String pairingCode({
  required Uint8List shared,
  required Uint8List clientPublic,
  required Uint8List hubPublic,
  required Uint8List clientNonce,
  required Uint8List hubNonce,
}) {
  final h = sha256([
    ...utf8.encode('lecasa pair code v1'),
    ...clientPublic,
    ...hubPublic,
    ...clientNonce,
    ...hubNonce,
    ...shared,
  ]);
  final n = ByteData.sublistView(h).getUint32(0) % 1000000;
  return n.toString().padLeft(6, '0');
}

/// Short public label of a home key: goes in adverts and the hello so a
/// screen finds its own hub among the neighbours'. Reveals nothing about
/// the key.
String homeTag(Uint8List homeKey) =>
    _hex(sha256([...utf8.encode('lecasa home tag'), ...homeKey]).sublist(0, 4));

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// AES-256-GCM in one direction of one link. The 12-byte nonce is four
/// zero bytes and a message counter, which the receiver insists only goes
/// up, so a recorded message cannot be played back.
class SealKey {
  final Uint8List key;
  int _sent = 0;
  int _received = 0;

  SealKey(this.key);

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  /// Counter (8 bytes) followed by ciphertext and tag.
  Uint8List seal(Uint8List plain) {
    _sent++;
    final c = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), 128, _nonce(_sent), Uint8List(0)),
      );
    final body = c.process(plain);
    final out = Uint8List(8 + body.length);
    ByteData.sublistView(out).setUint64(0, _sent);
    out.setRange(8, out.length, body);
    return out;
  }

  /// Throws [FormatException] when the message was not sealed with this
  /// key, was changed, or is a replay.
  Uint8List open(Uint8List sealed) {
    if (sealed.length < 8 + 16) throw const FormatException('Too short');
    final counter = ByteData.sublistView(sealed).getUint64(0);
    if (counter <= _received) throw const FormatException('Replayed');
    final c = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(key), 128, _nonce(counter), Uint8List(0)),
      );
    final Uint8List plain;
    try {
      plain = c.process(Uint8List.sublistView(sealed, 8));
    } on InvalidCipherTextException {
      throw const FormatException('Not sealed with our key');
    } on ArgumentError {
      throw const FormatException('Not sealed with our key');
    }
    _received = counter;
    return plain;
  }
}
