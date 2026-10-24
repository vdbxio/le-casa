// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Victron "Instant Readout" decoder. Victron devices broadcast a product
// advertisement in manufacturer data (company id 0x02E1). The record is
// AES-128-CTR encrypted with a per-device key you copy from VictronConnect.
// Record layouts ported from victron-ble (MIT, https://github.com/keshavdv/victron-ble).

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'bit_reader.dart';
import 'decoded.dart';
import 'decoder.dart';
import 'raw_advertisement.dart';
import 'victron_models.dart';

const int victronCompanyId = 0x02E1;

enum VictronRecord {
  solarCharger(0x01, 'Solar charger'),
  batteryMonitor(0x02, 'Battery monitor'),
  inverter(0x03, 'Inverter'),
  dcDcConverter(0x04, 'DC/DC converter'),
  smartLithium(0x05, 'Smart Lithium'),
  inverterRs(0x06, 'Inverter RS'),
  gxDevice(0x07, 'GX device'),
  acCharger(0x08, 'AC charger'),
  smartBatteryProtect(0x09, 'Smart Battery Protect'),
  lynxSmartBms(0x0A, 'Lynx Smart BMS'),
  multiRs(0x0B, 'Multi RS'),
  veBus(0x0C, 'VE.Bus'),
  dcEnergyMeter(0x0D, 'DC energy meter'),
  orionXs(0x0F, 'Orion XS');

  final int id;
  final String label;
  const VictronRecord(this.id, this.label);

  static VictronRecord? byId(int id) {
    for (final r in values) {
      if (r.id == id) return r;
    }
    return null;
  }
}

const Map<int, String> victronOperationMode = {
  0: 'Off',
  1: 'Low power',
  2: 'Fault',
  3: 'Bulk',
  4: 'Absorption',
  5: 'Float',
  6: 'Storage',
  7: 'Equalize (manual)',
  9: 'Inverting',
  11: 'Power supply',
  245: 'Starting up',
  246: 'Repeated absorption',
  247: 'Recondition',
  248: 'Battery safe',
  249: 'Active',
  252: 'External control',
  255: 'Not available',
};

const Map<int, String> victronAlarmReason = {
  0: 'No alarm',
  1: 'Low voltage',
  2: 'High voltage',
  4: 'Low SOC',
  8: 'Low starter voltage',
  16: 'High starter voltage',
  32: 'Low temperature',
  64: 'High temperature',
  128: 'Mid voltage',
  256: 'Overload',
  512: 'DC ripple',
  1024: 'Low V AC out',
  2048: 'High V AC out',
  4096: 'Short circuit',
  8192: 'BMS lockout',
};

/// The unencrypted header of a Victron product advertisement.
class VictronHeader {
  final int modelId;
  final VictronRecord? record;
  final int recordId;
  final int iv;
  final int keyByte0;
  final Uint8List encrypted;

  VictronHeader({
    required this.modelId,
    required this.record,
    required this.recordId,
    required this.iv,
    required this.keyByte0,
    required this.encrypted,
  });

  String get modelName =>
      victronModelNames[modelId] ?? 'Victron 0x${modelId.toRadixString(16)}';

  /// Returns null when this is not a Victron product advertisement
  /// (prefix byte 0x10) or too short.
  static VictronHeader? parse(Uint8List data) {
    if (data.length < 9 || data[0] != 0x10) return null;
    final bd = ByteData.sublistView(data);
    final recordId = data[4];
    return VictronHeader(
      modelId: bd.getUint16(2, Endian.little),
      record: VictronRecord.byId(recordId),
      recordId: recordId,
      iv: bd.getUint16(5, Endian.little),
      keyByte0: data[7],
      encrypted: data.sublist(8),
    );
  }
}

class VictronDecoder implements Decoder {
  final KeyProvider keyFor;

  const VictronDecoder({this.keyFor = noKeys});

  static Decoded _instantReadoutOff(Uint8List data) {
    String model = 'Victron device';
    final info = <String, String>{};
    if (data.length >= 4) {
      final id = ByteData.sublistView(data).getUint16(2, Endian.little);
      model = victronModelNames[id] ?? model;
      info['model id'] = '0x${id.toRadixString(16).toUpperCase()}';
    }
    return Decoded(
      protocol: 'Victron',
      kind: DeviceKind.needsSetup,
      model: model,
      needs:
          'Instant Readout is off. In VictronConnect open the device, '
          'Settings > Product info, turn on "Instant readout via Bluetooth", '
          'then paste its key here.',
      info: info,
    );
  }

  @override
  String get name => 'Victron';

  @override
  bool matches(RawAdvertisement adv) {
    final d = adv.manufacturerData[victronCompanyId];
    return d != null && d.isNotEmpty && d[0] == 0x10;
  }

  @override
  Decoded? decode(RawAdvertisement adv) {
    final data = adv.manufacturerData[victronCompanyId];
    if (data == null) return null;
    final h = VictronHeader.parse(data);
    if (h == null) {
      // A short product advert with no Instant Readout record: the device
      // exists but is not broadcasting readings yet.
      return _instantReadoutOff(data);
    }

    final info = <String, String>{
      'model id': '0x${h.modelId.toRadixString(16).toUpperCase()}',
      'record type':
          h.record?.label ?? 'unknown (0x${h.recordId.toRadixString(16)})',
      'counter': '${h.iv}',
    };

    final kind = switch (h.record) {
      VictronRecord.solarCharger => DeviceKind.solar,
      VictronRecord.batteryMonitor ||
      VictronRecord.smartLithium ||
      VictronRecord.lynxSmartBms => DeviceKind.battery,
      _ => DeviceKind.power,
    };

    final key = keyFor(adv.id);
    if (key == null) {
      // Still grouped by what it is: a Victron MPPT without a key is shown
      // under Solar with a "needs key" note, not hidden away.
      return Decoded(
        protocol: 'Victron',
        kind: kind,
        model: h.modelName,
        needs:
            'Needs the encryption key from VictronConnect '
            '(Settings > Product info > Instant readout > Show)',
        info: info,
      );
    }
    if (key.length != 16 || key[0] != h.keyByte0) {
      return Decoded(
        protocol: 'Victron',
        kind: kind,
        model: h.modelName,
        needs:
            'Key does not match this device (first byte should be '
            '${h.keyByte0.toRadixString(16).padLeft(2, '0')})',
        info: info,
      );
    }

    final plain = decryptCtr(key, h.iv, h.encrypted);
    final readings = <Reading>[];
    switch (h.record) {
      case VictronRecord.solarCharger:
        readings.addAll(parseSolarCharger(plain));
      case VictronRecord.batteryMonitor:
        readings.addAll(parseBatteryMonitor(plain));
      case VictronRecord.dcDcConverter:
        readings.addAll(parseDcDcConverter(plain));
      default:
        return Decoded(
          protocol: 'Victron',
          kind: kind,
          model: h.modelName,
          needs: 'Record type "${info['record type']}" is not decoded yet',
          info: {...info, 'decrypted': hex(plain)},
        );
    }
    return Decoded(
      protocol: 'Victron',
      kind: kind,
      model: h.modelName,
      readings: readings,
      info: info,
    );
  }

  /// AES-128-CTR where the 128-bit counter starts at [iv] and is treated as
  /// a little-endian integer (the Victron/pycryptodome convention).
  static Uint8List decryptCtr(Uint8List key, int iv, Uint8List data) {
    final aes = AESEngine()..init(true, KeyParameter(key));
    final out = Uint8List(data.length);
    final block = Uint8List(16);
    final ks = Uint8List(16);
    var counter = iv;
    for (var off = 0; off < data.length; off += 16) {
      block.fillRange(0, 16, 0);
      var c = counter;
      for (var i = 0; i < 16 && c != 0; i++) {
        block[i] = c & 0xFF;
        c >>= 8;
      }
      aes.processBlock(block, 0, ks, 0);
      final n = (data.length - off).clamp(0, 16);
      for (var i = 0; i < n; i++) {
        out[off + i] = data[off + i] ^ ks[i];
      }
      counter++;
    }
    return out;
  }

  static List<Reading> parseSolarCharger(Uint8List d) {
    final r = BitReader(_pad(d, 12));
    final state = r.readUnsigned(8);
    final error = r.readUnsigned(8);
    final voltage = r.readSigned(16);
    final current = r.readSigned(16);
    final yieldToday = r.readUnsigned(16);
    final solarPower = r.readUnsigned(16);
    final load = r.readUnsigned(9);
    return [
      Reading('charge state', victronOperationMode[state] ?? 'state $state'),
      Reading('charger error', error == 0 ? 'none' : 'error $error'),
      Reading('battery voltage', voltage == 0x7FFF ? null : voltage / 100, 'V'),
      Reading('battery current', current == 0x7FFF ? null : current / 10, 'A'),
      Reading(
        'yield today',
        yieldToday == 0xFFFF ? null : yieldToday * 10,
        'Wh',
      ),
      Reading('solar power', solarPower == 0xFFFF ? null : solarPower, 'W'),
      Reading('load current', load == 0x1FF ? null : load / 10, 'A'),
    ];
  }

  static List<Reading> parseBatteryMonitor(Uint8List d) {
    final r = BitReader(_pad(d, 16));
    final ttg = r.readUnsigned(16);
    final voltage = r.readSigned(16);
    final alarm = r.readUnsigned(16);
    final aux = r.readUnsigned(16);
    final auxMode = r.readUnsigned(2);
    final current = r.readSigned(22);
    final consumed = r.readUnsigned(20);
    final soc = r.readUnsigned(10);
    final out = [
      Reading('state of charge', soc == 0x3FF ? null : soc / 10, '%'),
      Reading('voltage', voltage == 0x7FFF ? null : voltage / 100, 'V'),
      Reading('current', current == 0x3FFFFF ? null : current / 1000, 'A'),
      Reading('consumed', consumed == 0xFFFFF ? null : -consumed / 10, 'Ah'),
      Reading('time to go', ttg == 0xFFFF ? null : ttg, 'min'),
      Reading('alarm', victronAlarmReason[alarm] ?? 'alarm $alarm'),
    ];
    switch (auxMode) {
      case 0:
        out.add(
          Reading('starter voltage', BitReader.toSigned(aux, 16) / 100, 'V'),
        );
      case 1:
        out.add(Reading('midpoint voltage', aux / 100, 'V'));
      case 2:
        out.add(
          Reading(
            'temperature',
            aux == 0xFFFF ? null : _round2(aux / 100 - 273.15),
            '°C',
          ),
        );
      default:
        break;
    }
    return out;
  }

  static List<Reading> parseDcDcConverter(Uint8List d) {
    final r = BitReader(_pad(d, 12));
    final state = r.readUnsigned(8);
    final error = r.readUnsigned(8);
    final inV = r.readUnsigned(16);
    final outV = r.readSigned(16);
    final offReason = r.readUnsigned(32);
    return [
      Reading('state', victronOperationMode[state] ?? 'state $state'),
      Reading('error', error == 0 ? 'none' : 'error $error'),
      Reading('input voltage', inV == 0xFFFF ? null : inV / 100, 'V'),
      Reading('output voltage', outV == 0x7FFF ? null : outV / 100, 'V'),
      Reading('off reason', '0x${offReason.toRadixString(16)}'),
    ];
  }

  static Uint8List _pad(Uint8List d, int n) => d.length >= n ? d : Uint8List(n)
    ..setRange(0, d.length, d);

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}
