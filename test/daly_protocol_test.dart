import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/drivers/daly_driver.dart';
import 'package:lecasa/drivers/daly_protocol.dart';

import 'fake_session.dart';
import 'helpers.dart';

/// Builds a D2 status frame for a 4S pack with the given register values.
Uint8List d2StatusFrame({
  int registers = 62,
  List<int> cellsMv = const [3295, 3305, 3315, 3325],
  List<int> tempsC = const [20, 21],
  int voltage01 = 132, // 13.2 V
  int current01 = 30000 + 25, // +2.5 A
  int soc01 = 876,
  int chargeState = 1,
  int remaining01 = 1050,
  int cycles = 57,
  int balancer = 0,
  int chargeMos = 1,
  int dischargeMos = 1,
  BigInt? alarm,
  int mosTempRaw = 0,
}) {
  final data = Uint8List(registers * 2);
  final bd = ByteData.sublistView(data);
  void reg(int r, int v) => bd.setUint16(r * 2, v, Endian.big);
  for (var i = 0; i < cellsMv.length; i++) {
    reg(i, cellsMv[i]);
  }
  for (var i = 0; i < tempsC.length; i++) {
    reg(32 + i, tempsC[i] + 40);
  }
  reg(40, voltage01);
  reg(41, current01);
  reg(42, soc01);
  reg(47, chargeState);
  reg(48, remaining01);
  reg(49, cellsMv.length);
  reg(50, tempsC.length);
  reg(51, cycles);
  reg(52, balancer);
  reg(53, chargeMos);
  reg(54, dischargeMos);
  final a = alarm ?? BigInt.zero;
  for (var i = 0; i < 8; i++) {
    data[116 + i] = ((a >> (8 * (7 - i))) & BigInt.from(0xFF)).toInt();
  }
  if (registers == 80) reg(66, mosTempRaw);
  final frame = Uint8List(3 + data.length + 2);
  frame[0] = 0xD2;
  frame[1] = 0x03;
  frame[2] = data.length;
  frame.setRange(3, 3 + data.length, data);
  final crc = crc16Modbus(frame, frame.length - 2);
  frame[frame.length - 2] = crc & 0xFF;
  frame[frame.length - 1] = crc >> 8;
  return frame;
}

void main() {
  group('Daly framing', () {
    test('requests match the known-good byte sequences', () {
      expect(
        dalyReadRequest(DalyProtocol.d2, 0x0000, 62),
        fromHex('d2 03 00 00 00 3e d7 b9'),
      );
      expect(
        dalyReadRequest(DalyProtocol.d2, 0x003E, 9),
        fromHex('d2 03 00 3e 00 09 f7 a3'),
      );
      expect(
        dalyReadRequest(DalyProtocol.p81, 0x0000, 64),
        fromHex('81 03 00 00 00 40 5b fa'),
      );
    });

    test('assembler joins chunks and checks the CRC', () {
      final frame = d2StatusFrame();
      final asm = DalyFrameAssembler(DalyProtocol.d2);
      final chunks = chunked(frame);
      expect(chunks.length, 7);
      for (final c in chunks.take(6)) {
        expect(asm.add(c), isNull);
      }
      expect(asm.add(chunks.last), frame);
    });

    test('assembler drops a frame with a bad CRC and recovers', () {
      final bad = Uint8List.fromList(d2StatusFrame());
      bad[10] ^= 0xFF;
      final asm = DalyFrameAssembler(DalyProtocol.d2);
      expect(asm.add(bad), isNull);
      final good = d2StatusFrame();
      expect(asm.add(good), good);
    });

    test('assembler recovers when it joins mid-frame', () {
      final frame = d2StatusFrame();
      final asm = DalyFrameAssembler(DalyProtocol.d2);
      // Tail of an earlier frame, containing a stray 0xD2, then a good one.
      final tail = Uint8List.fromList([
        ...frame.sublist(60, 100),
        0xD2,
        0x03,
        0x10,
        ...frame.sublist(100),
      ]);
      expect(asm.add(tail), isNull);
      Uint8List? got;
      for (final c in chunked(frame)) {
        got ??= asm.add(c);
      }
      expect(got, frame);
    });

    test('assembler ignores noise before the start byte', () {
      final frame = d2StatusFrame();
      final asm = DalyFrameAssembler(DalyProtocol.d2);
      final noisy = Uint8List.fromList([0x00, 0x11, ...frame]);
      expect(asm.add(noisy), frame);
    });
  });

  group('Daly D2 status', () {
    test('decodes a 4S LiFePO4 pack', () {
      final s = parseDalyD2Status(d2StatusFrame())!;
      expect(s.voltage, 13.2);
      expect(s.current, 2.5);
      expect(s.soc, 87.6);
      expect(s.cellVoltages, [3.295, 3.305, 3.315, 3.325]);
      expect(s.temperatures, [20.0, 21.0]);
      expect(s.remainingAh, 105.0);
      expect(s.cycles, 57);
      expect(s.chargeStateText, 'charging');
      expect(s.chargeMos, isTrue);
      expect(s.dischargeMos, isTrue);
      expect(s.balancing, isFalse);
      expect(s.deltaMv, 30);
      expect(s.power, closeTo(33.0, 0.001));
      expect(s.alarms, isEmpty);
      expect(s.mosTemperature, isNull);
    });

    test('negative current is discharge', () {
      final s = parseDalyD2Status(
        d2StatusFrame(current01: 30000 - 123, chargeState: 2),
      )!;
      expect(s.current, -12.3);
      expect(s.chargeStateText, 'discharging');
    });

    test('alarm bits map to names', () {
      // Bit 48 = register 0x3A low byte bit 0: cell voltage too high.
      // Bit 16 = register 0x3C low byte bit 0: charging MOS over-temp.
      final mask = (BigInt.one << 48) | (BigInt.one << 16);
      final s = parseDalyD2Status(d2StatusFrame(alarm: mask))!;
      expect(s.alarms, [
        'Charging MOS over-temperature warning',
        'Warning: cell voltage too high',
      ]);
    });

    test('80-register frame carries the MOS temperature', () {
      final s = parseDalyD2Status(
        d2StatusFrame(registers: 80, mosTempRaw: 40 + 31),
      )!;
      expect(s.mosTemperature, 31.0);
    });

    test('rejects other sizes', () {
      final short = Uint8List.fromList([0xD2, 0x03, 4, 0, 0, 0, 0, 0, 0]);
      final crc = crc16Modbus(short, 7);
      short[7] = crc & 0xFF;
      short[8] = crc >> 8;
      expect(parseDalyD2Status(short), isNull);
    });

    test('decodes the real frame from an 8S DL-694201312BA module', () {
      // Captured 2026-10-24 over bleak from a Mac (single notification,
      // MTU 512). 8 LiFePO4 cells, pack discharging.
      final frame = fromHex(
        'd2037c0cf30cf30cf10cf30cf40cf60cf30cf3'
        '000000000000000000000000000000000000000000000000'
        '000000000000000000000000000000000000000000000000'
        '003a003a000000000000000000000000'
        '010974f503620cf60cf1003a003a00020a9f00080002008a'
        '0000000100010cf3000500a10000000000000000915f',
      );
      expect(frame.length, 129);
      final asm = DalyFrameAssembler(DalyProtocol.d2);
      expect(asm.add(frame), frame, reason: 'CRC must check out');
      final s = parseDalyD2Status(frame)!;
      expect(s.cellVoltages, [
        3.315,
        3.315,
        3.313,
        3.315,
        3.316,
        3.318,
        3.315,
        3.315,
      ]);
      expect(s.temperatures, [18.0, 18.0]);
      expect(s.voltage, 26.5);
      expect(s.current, -5.9);
      expect(s.soc, 86.6);
      expect(s.chargeStateText, 'discharging');
      expect(s.remainingAh, 271.9);
      expect(s.cycles, 138);
      expect(s.balancing, isFalse);
      expect(s.chargeMos, isTrue);
      expect(s.dischargeMos, isTrue);
      expect(s.deltaMv, 5);
      expect(s.alarms, isEmpty);
      // The module's own power register says 161 W; V*I gives 156 W.
      expect(s.power, closeTo(-156.4, 0.1));
      expect(s.toDecoded('DL-694201312BA').model, 'Daly smart BMS (8S)');
    });

    test('toDecoded is a Battery device with the headline readings', () {
      final d = parseDalyD2Status(d2StatusFrame())!.toDecoded('DL-TEST');
      expect(d.kind, DeviceKind.battery);
      expect(d.model, 'Daly smart BMS (4S)');
      expect(d.needs, isNull);
      final byLabel = {for (final r in d.readings) r.label: r};
      expect(byLabel['state of charge']!.display, '87.6 %');
      expect(byLabel['voltage']!.display, '13.2 V');
      expect(byLabel['current']!.display, '2.5 A');
      expect(byLabel['power']!.display, '33 W');
      expect(byLabel['cell 1']!.display, '3.295 V');
      expect(byLabel['temperature 2']!.display, '21 °C');
      expect(d.info['module'], 'DL-TEST');
    });
  });

  group('Daly driver', () {
    final chars = [
      const GattChar(
        '0000fff1-0000-1000-8000-00805f9b34fb',
        canNotify: true,
        canRead: true,
      ),
      const GattChar(
        '0000fff2-0000-1000-8000-00805f9b34fb',
        canWrite: true,
        canWriteWithoutResponse: true,
      ),
    ];
    final dalyAdv = adv(
      id: 'C8:47:80:12:34:56',
      mac: 'C8:47:80:12:34:56',
      name: 'DL-694201312BA',
      manufacturerData: {0x0402: 'c84780123456'},
    );

    test('talks D2 to a new module, in 20-byte chunks', () async {
      final session = FakeSession(
        characteristics: chars,
        onWrite: (c, data) {
          if (data[0] != 0xD2) return const [];
          final reg = (data[2] << 8) | data[3];
          if (reg == 0x0000) return chunked(d2StatusFrame());
          return const []; // no MOS block on this module
        },
      );
      final d = await const DalyDriver().read(session, dalyAdv);
      expect(d.model, 'Daly smart BMS (4S)');
      expect(d.info['protocol'], 'D2');
      // Early status request, status request, then the optional MOS request.
      expect(session.writes.length, 3);
      expect(session.writes.first, fromHex('d2 03 00 00 00 3e d7 b9'));
    });

    test('falls back to 0x81 when D2 gets no answer', () async {
      Uint8List p81(int reg, int count, void Function(ByteData) fill) {
        final data = Uint8List(count * 2);
        fill(ByteData.sublistView(data));
        final f = Uint8List(data.length + 5);
        f[0] = 0x51;
        f[1] = 0x03;
        f[2] = data.length;
        f.setRange(3, 3 + data.length, data);
        final crc = crc16Modbus(f, f.length - 2);
        f[f.length - 2] = crc & 0xFF;
        f[f.length - 1] = crc >> 8;
        return f;
      }

      final session = FakeSession(
        characteristics: chars,
        onWrite: (c, data) {
          if (data[0] != 0x81) return const [];
          final reg = (data[2] << 8) | data[3];
          if (reg == 0x0000) {
            return chunked(
              p81(0, 64, (bd) {
                for (var i = 0; i < 8; i++) {
                  bd.setUint16(i * 2, 3300 + i, Endian.big);
                }
                bd.setUint16(0x30 * 2, 40 + 18, Endian.big);
                bd.setUint16(0x38 * 2, 264, Endian.big);
                bd.setUint16(0x39 * 2, 30000 - 50, Endian.big);
                bd.setUint16(0x3A * 2, 500, Endian.big);
                bd.setUint16(0x3C * 2, 8, Endian.big);
                bd.setUint16(0x3D * 2, 1, Endian.big);
              }),
            );
          }
          if (reg == 0x0041) {
            return chunked(
              p81(0x41, 62, (bd) {
                bd.setUint16((0x48 - 0x41) * 2, 2, Endian.big);
                bd.setUint16((0x4B - 0x41) * 2, 2000, Endian.big);
                bd.setUint16((0x4C - 0x41) * 2, 12, Endian.big);
                bd.setUint16((0x52 - 0x41) * 2, 1, Endian.big);
                bd.setUint16((0x53 - 0x41) * 2, 0, Endian.big);
              }),
            );
          }
          return const [];
        },
      );
      final d = await const DalyDriver().read(session, dalyAdv);
      expect(d.model, 'Daly smart BMS (8S)');
      expect(d.info['protocol'], '0x81');
      final byLabel = {for (final r in d.readings) r.label: r};
      expect(byLabel['voltage']!.display, '26.4 V');
      expect(byLabel['current']!.display, '-5 A');
      expect(byLabel['state of charge']!.display, '50 %');
      expect(byLabel['temperature']!.display, '18 °C');
      expect(byLabel['remaining']!.display, '200 Ah');
      expect(byLabel['cycles']!.display, '12');
      expect(byLabel['charge MOSFET']!.display, 'on');
      expect(byLabel['discharge MOSFET']!.display, 'off');
      expect(byLabel['state']!.display, 'discharging');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a device without the Daly characteristics is unsupported', () {
      final session = FakeSession(
        characteristics: const [
          GattChar('00002a19-0000-1000-8000-00805f9b34fb'),
        ],
      );
      expect(
        () => const DalyDriver().read(session, dalyAdv),
        throwsA(isA<UnsupportedDeviceException>()),
      );
    });
  });
}
