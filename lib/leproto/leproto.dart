// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Le'Proto v0: the connectionless command frame Le'Casa sends to Le'devices,
// and the Le'LED state carried in its BTHome advert. The spec and the
// reference C++ are in firmware/le-led (PROTOCOL.md, le_proto.cpp); the
// tests check this against the same vectors.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Company id the frame goes out under as manufacturer data. 0xFFFF is the
/// Bluetooth SIG's id for testing; a shipping product needs a real one.
const int leProtoCompanyId = 0xFFFF;

const int _magic = 0x4C;
const int _typeCommand = 0x01;

/// Le'Proto opcodes (PROTOCOL.md).
abstract final class LepOp {
  static const power = 0x01;
  static const brightness = 0x02;
  static const color = 0x03;
  static const white = 0x04;
  static const cct = 0x05;
  static const effect = 0x06;
  static const effectArgs = 0x07;
  static const palette = 0x08;
  static const preset = 0x09;
  static const wake = 0x0C;
}

Uint8List _aes(Uint8List key, Uint8List block) {
  final e = AESEngine()..init(true, KeyParameter(key));
  final out = Uint8List(16);
  e.processBlock(block, 0, out, 0);
  return out;
}

/// The keys and address a device's one key gives.
class LepKeys {
  final Uint8List key;
  final Uint8List down;
  final Uint8List dst;

  LepKeys._(this.key, this.down, this.dst);

  factory LepKeys(Uint8List key) {
    final down = _aes(
      key,
      Uint8List.fromList(ascii.encode('LeProto-down-v0\x00')),
    );
    final dst = _aes(
      key,
      Uint8List.fromList(ascii.encode('LeProto-dstid-v0')),
    ).sublist(0, 3);
    return LepKeys._(key, down, dst);
  }

  String get dstHex =>
      dst.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// One 16-byte command frame: 9 readable header bytes (the AES-CCM
/// associated data), then the encrypted opcode and two arguments and a
/// 4-byte MIC.
Uint8List lepSeal(LepKeys k, int slot, int seq, int op, int a0, int a1) {
  final header = Uint8List.fromList([
    _magic,
    _typeCommand,
    ...k.dst,
    slot & 3,
    seq & 0xFF,
    (seq >> 8) & 0xFF,
    (seq >> 16) & 0xFF,
  ]);
  final nonce = Uint8List.fromList([
    ...k.dst,
    slot & 3,
    seq & 0xFF,
    (seq >> 8) & 0xFF,
    (seq >> 16) & 0xFF,
    header[1],
    0x01,
    ...ascii.encode('LEPR'),
  ]);
  final ccm = CCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(k.down), 32, nonce, header));
  final ct = ccm.process(Uint8List.fromList([op & 0xFF, a0 & 0xFF, a1 & 0xFF]));
  return Uint8List.fromList([...header, ...ct]);
}

/// The frame as the 128-bit service UUID an iOS app can advertise. A UUID
/// goes on air little-endian, so the string is the frame reversed.
String lepUuid(Uint8List frame) {
  final h = frame.reversed
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

int rgbTo565(int r, int g, int b) =>
    ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);

(int, int, int) rgbFrom565(int c) {
  final r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
  return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
}

/// The 10 bytes of Le'LED state in the advert's raw (0x54) object.
class LeLedState {
  final int rev;
  final int ackSlot;
  final int ackSeqLow;
  final int bri;
  final int r, g, b;
  final int fx;
  final int pal;
  final int sx;
  final int ix;
  final int preset;

  const LeLedState({
    required this.rev,
    required this.ackSlot,
    required this.ackSeqLow,
    required this.bri,
    required this.r,
    required this.g,
    required this.b,
    required this.fx,
    required this.pal,
    required this.sx,
    required this.ix,
    required this.preset,
  });

  static LeLedState? parse(List<int> raw) {
    if (raw.length < 10) return null;
    final (r, g, b) = rgbFrom565(raw[3] | raw[4] << 8);
    return LeLedState(
      rev: raw[0],
      ackSlot: raw[1] >> 6,
      ackSeqLow: raw[1] & 0x3F,
      bri: raw[2],
      r: r,
      g: g,
      b: b,
      fx: raw[5],
      pal: raw[6],
      sx: raw[7],
      ix: raw[8],
      preset: raw[9],
    );
  }

  String get colourHex =>
      [r, g, b].map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  /// Whether this state acknowledges the command [seq] from [slot].
  bool acks(int slot, int seq) => ackSlot == slot && ackSeqLow == (seq & 0x3F);
}

/// A few of WLED's effect names, for the card. The rest show as a number.
const Map<int, String> wledEffects = {
  0: 'Solid colour',
  1: 'Blink',
  2: 'Breathe',
  3: 'Wipe',
  8: 'Colorloop',
  9: 'Rainbow',
  10: 'Scan',
  13: 'Theater',
  15: 'Running',
  38: 'Aurora',
  63: 'Pride',
  65: 'Palette',
  66: 'Fire 2012',
  74: 'Colortwinkles',
  101: 'Pacifica',
};
