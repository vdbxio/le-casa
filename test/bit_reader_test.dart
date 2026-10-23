import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/bit_reader.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';

// Vectors from victron-ble tests/test_base.py.
void main() {
  test('toSigned', () {
    expect(BitReader.toSigned(0x000, 12), 0x000);
    expect(BitReader.toSigned(0x7FF, 12), 0x7FF);
    expect(BitReader.toSigned(0x800, 12), -0x800);
    expect(BitReader.toSigned(0xCAD, 12), -0x353);
    expect(BitReader.toSigned(0xFFF, 12), -0x001);
    expect(BitReader.toSigned(0x10, 5), -0x10);
    expect(BitReader.toSigned(0x1F, 5), -0x01);
  });

  test('read LSB first', () {
    final r = BitReader(fromHex('1a2b3c4d5e6f7890'));
    expect(r.readBit(), 0);
    expect(r.readBit(), 1);
    expect(r.readBit(), 0);
    expect(r.readBit(), 1);
    expect(r.readUnsigned(6), 0x31);
    expect(r.readSigned(6), 0x0A);
    expect(r.readSigned(4), -0x04);
    expect(r.readUnsigned(11), 0x4D3);
    expect(r.readBit(), 0);
    expect(r.readUnsigned(32), 0x90786F5E);
  });
}
