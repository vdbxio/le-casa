// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// BTHome v2 object table. Source: https://bthome.io/format/ and the
// bthome-ble reference parser (MIT, https://github.com/Bluetooth-Devices/bthome-ble).

enum BtFormat {
  uint,
  sint,
  bin,
  event,
  text,
  raw,
  timestamp,
  deviceType,
  firmware,
}

class BtObject {
  final String label;
  final int length; // bytes; for text/raw this is the length-prefix size (1)
  final BtFormat format;
  final double factor;
  final String unit;

  const BtObject(
    this.label,
    this.length,
    this.format, {
    this.factor = 1,
    this.unit = '',
  });
}

const Map<int, BtObject> bthomeObjects = {
  0x00: BtObject('packet id', 1, BtFormat.uint),
  0x01: BtObject('battery', 1, BtFormat.uint, unit: '%'),
  0x02: BtObject('temperature', 2, BtFormat.sint, factor: 0.01, unit: '°C'),
  0x03: BtObject('humidity', 2, BtFormat.uint, factor: 0.01, unit: '%'),
  0x04: BtObject('pressure', 3, BtFormat.uint, factor: 0.01, unit: 'hPa'),
  0x05: BtObject('illuminance', 3, BtFormat.uint, factor: 0.01, unit: 'lux'),
  0x06: BtObject('mass', 2, BtFormat.uint, factor: 0.01, unit: 'kg'),
  0x07: BtObject('mass', 2, BtFormat.uint, factor: 0.01, unit: 'lb'),
  0x08: BtObject('dew point', 2, BtFormat.sint, factor: 0.01, unit: '°C'),
  0x09: BtObject('count', 1, BtFormat.uint),
  0x0A: BtObject('energy', 3, BtFormat.uint, factor: 0.001, unit: 'kWh'),
  0x0B: BtObject('power', 3, BtFormat.uint, factor: 0.01, unit: 'W'),
  0x0C: BtObject('voltage', 2, BtFormat.uint, factor: 0.001, unit: 'V'),
  0x0D: BtObject('pm2.5', 2, BtFormat.uint, unit: 'µg/m³'),
  0x0E: BtObject('pm10', 2, BtFormat.uint, unit: 'µg/m³'),
  0x0F: BtObject('generic boolean', 1, BtFormat.bin),
  0x10: BtObject('power', 1, BtFormat.bin),
  0x11: BtObject('opening', 1, BtFormat.bin),
  0x12: BtObject('co2', 2, BtFormat.uint, unit: 'ppm'),
  0x13: BtObject('tvoc', 2, BtFormat.uint, unit: 'µg/m³'),
  0x14: BtObject('moisture', 2, BtFormat.uint, factor: 0.01, unit: '%'),
  0x15: BtObject('battery low', 1, BtFormat.bin),
  0x16: BtObject('battery charging', 1, BtFormat.bin),
  0x17: BtObject('carbon monoxide', 1, BtFormat.bin),
  0x18: BtObject('cold', 1, BtFormat.bin),
  0x19: BtObject('connectivity', 1, BtFormat.bin),
  0x1A: BtObject('door', 1, BtFormat.bin),
  0x1B: BtObject('garage door', 1, BtFormat.bin),
  0x1C: BtObject('gas', 1, BtFormat.bin),
  0x1D: BtObject('heat', 1, BtFormat.bin),
  0x1E: BtObject('light', 1, BtFormat.bin),
  0x1F: BtObject('lock', 1, BtFormat.bin),
  0x20: BtObject('moisture', 1, BtFormat.bin),
  0x21: BtObject('motion', 1, BtFormat.bin),
  0x22: BtObject('moving', 1, BtFormat.bin),
  0x23: BtObject('occupancy', 1, BtFormat.bin),
  0x24: BtObject('plug', 1, BtFormat.bin),
  0x25: BtObject('presence', 1, BtFormat.bin),
  0x26: BtObject('problem', 1, BtFormat.bin),
  0x27: BtObject('running', 1, BtFormat.bin),
  0x28: BtObject('safety', 1, BtFormat.bin),
  0x29: BtObject('smoke', 1, BtFormat.bin),
  0x2A: BtObject('sound', 1, BtFormat.bin),
  0x2B: BtObject('tamper', 1, BtFormat.bin),
  0x2C: BtObject('vibration', 1, BtFormat.bin),
  0x2D: BtObject('window', 1, BtFormat.bin),
  0x2E: BtObject('humidity', 1, BtFormat.uint, unit: '%'),
  0x2F: BtObject('moisture', 1, BtFormat.uint, unit: '%'),
  0x3A: BtObject('button', 1, BtFormat.event),
  0x3C: BtObject('dimmer', 2, BtFormat.event),
  0x3D: BtObject('count', 2, BtFormat.uint),
  0x3E: BtObject('count', 4, BtFormat.uint),
  0x3F: BtObject('rotation', 2, BtFormat.sint, factor: 0.1, unit: '°'),
  0x40: BtObject('distance', 2, BtFormat.uint, unit: 'mm'),
  0x41: BtObject('distance', 2, BtFormat.uint, factor: 0.1, unit: 'm'),
  0x42: BtObject('duration', 3, BtFormat.uint, factor: 0.001, unit: 's'),
  0x43: BtObject('current', 2, BtFormat.uint, factor: 0.001, unit: 'A'),
  0x44: BtObject('speed', 2, BtFormat.uint, factor: 0.01, unit: 'm/s'),
  0x45: BtObject('temperature', 2, BtFormat.sint, factor: 0.1, unit: '°C'),
  0x46: BtObject('uv index', 1, BtFormat.uint, factor: 0.1),
  0x47: BtObject('volume', 2, BtFormat.uint, factor: 0.1, unit: 'L'),
  0x48: BtObject('volume', 2, BtFormat.uint, unit: 'mL'),
  0x49: BtObject(
    'volume flow rate',
    2,
    BtFormat.uint,
    factor: 0.001,
    unit: 'm³/h',
  ),
  0x4A: BtObject('voltage', 2, BtFormat.uint, factor: 0.1, unit: 'V'),
  0x4B: BtObject('gas', 3, BtFormat.uint, factor: 0.001, unit: 'm³'),
  0x4C: BtObject('gas', 4, BtFormat.uint, factor: 0.001, unit: 'm³'),
  0x4D: BtObject('energy', 4, BtFormat.uint, factor: 0.001, unit: 'kWh'),
  0x4E: BtObject('volume', 4, BtFormat.uint, factor: 0.001, unit: 'L'),
  0x4F: BtObject('water', 4, BtFormat.uint, factor: 0.001, unit: 'L'),
  0x50: BtObject('timestamp', 4, BtFormat.timestamp),
  0x51: BtObject('acceleration', 2, BtFormat.uint, factor: 0.001, unit: 'm/s²'),
  0x52: BtObject('gyroscope', 2, BtFormat.uint, factor: 0.001, unit: '°/s'),
  0x53: BtObject('text', 1, BtFormat.text),
  0x54: BtObject('raw', 1, BtFormat.raw),
  0x55: BtObject('volume storage', 4, BtFormat.uint, factor: 0.001, unit: 'L'),
  0x56: BtObject('conductivity', 2, BtFormat.uint, unit: 'µS/cm'),
  0x57: BtObject('temperature', 1, BtFormat.sint, unit: '°C'),
  0x58: BtObject('temperature', 1, BtFormat.sint, factor: 0.35, unit: '°C'),
  0x59: BtObject('count', 1, BtFormat.sint),
  0x5A: BtObject('count', 2, BtFormat.sint),
  0x5B: BtObject('count', 4, BtFormat.sint),
  0x5C: BtObject('power', 4, BtFormat.sint, factor: 0.01, unit: 'W'),
  0x5D: BtObject('current', 2, BtFormat.sint, factor: 0.001, unit: 'A'),
  0x5E: BtObject('direction', 2, BtFormat.uint, factor: 0.01, unit: '°'),
  0x5F: BtObject('precipitation', 2, BtFormat.uint, factor: 0.1, unit: 'mm'),
  0x60: BtObject('channel', 1, BtFormat.uint),
  0x61: BtObject('rotational speed', 2, BtFormat.uint, unit: 'rpm'),
  0x62: BtObject('speed', 4, BtFormat.sint, factor: 0.000001, unit: 'm/s'),
  0x63: BtObject(
    'acceleration',
    4,
    BtFormat.sint,
    factor: 0.000001,
    unit: 'm/s²',
  ),
  0x64: BtObject('light level', 1, BtFormat.uint),
  0x65: BtObject('settings revision', 1, BtFormat.uint),
  0xF0: BtObject('device type id', 2, BtFormat.deviceType),
  0xF1: BtObject('firmware version', 4, BtFormat.firmware),
  0xF2: BtObject('firmware version', 3, BtFormat.firmware),
};

const Map<int, String> bthomeButtonEvents = {
  0x00: 'none',
  0x01: 'press',
  0x02: 'double_press',
  0x03: 'triple_press',
  0x04: 'long_press',
  0x05: 'long_double_press',
  0x06: 'long_triple_press',
  0x80: 'hold_press',
  0xFE: 'hold_press',
};

const Map<int, String> bthomeDimmerEvents = {
  0x00: 'none',
  0x01: 'rotate_left',
  0x02: 'rotate_right',
};
