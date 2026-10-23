// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Bit-field reader for Victron "extra manufacturer data", LSB first.
// Ported from victron-ble (MIT, https://github.com/keshavdv/victron-ble).

class BitReader {
  final List<int> _data;
  int _index = 0;

  BitReader(this._data);

  int get bitsLeft => _data.length * 8 - _index;

  int readBit() {
    final bit = (_data[_index >> 3] >> (_index & 7)) & 1;
    _index++;
    return bit;
  }

  int readUnsigned(int numBits) {
    var value = 0;
    for (var i = 0; i < numBits; i++) {
      value |= readBit() << i;
    }
    return value;
  }

  int readSigned(int numBits) => toSigned(readUnsigned(numBits), numBits);

  static int toSigned(int value, int numBits) =>
      (value & (1 << (numBits - 1))) != 0 ? value - (1 << numBits) : value;
}
