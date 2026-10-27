// Vectors from sblibs/pySwitchbot (MIT) tests/test_adv_parser.py and
import 'package:lecasa/decoders/raw_advertisement.dart';
// Bluetooth-Devices/govee-ble (Apache-2.0) tests/test_parser.py, with the
// values those tests expect.

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/govee.dart';
import 'package:lecasa/decoders/registry.dart';

import 'helpers.dart';

Map<String, Object?> values(Decoded out) => {
  for (final r in out.readings) r.label: r.value,
};

void main() {
  group('SwitchBot', () {
    test('Meter, service and manufacturer data', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '5400e4069835'},
          manufacturerData: {0x0969: 'd7c17d5deb43de03069835'},
        ),
      )!;
      expect(out.model, 'SwitchBot Meter');
      expect(out.kind, DeviceKind.climate);
      expect(values(out), {
        'temperature': 24.6,
        'humidity': 53,
        'battery': 100,
      });
      expect(out.info['mac'], 'D7:C1:7D:5D:EB:43');
    });

    test('Indoor/Outdoor Meter, then a packet without service data', () {
      final reg = DecoderRegistry.standard();
      const mfr = {0x0969: 'aabbccddeeffe00f06983500'};
      final first = reg.decode(
        adv(serviceData: {0xFD3D: '7700e4'}, manufacturerData: mfr),
      )!;
      expect(first.model, 'SwitchBot Indoor/Outdoor Meter');
      expect(values(first), {
        'temperature': 24.6,
        'humidity': 53,
        'battery': 100,
      });
      // A passive scan may only bring the manufacturer data.
      final second = reg.decode(adv(manufacturerData: mfr))!;
      expect(values(second), {'temperature': 24.6, 'humidity': 53});
    });

    test('a manufacturer packet from an unknown SwitchBot is not guessed', () {
      final out = DecoderRegistry.standard().decode(
        adv(manufacturerData: {0x0969: 'aabbccddeeffe00f06983500'}),
      );
      expect(out?.protocol, isNot('SwitchBot'));
    });

    test('Meter Pro CO2', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '350064'},
          manufacturerData: {0x0969: 'b0e9fe543215b7e4079ba4003702d500'},
        ),
      )!;
      expect(values(out), {
        'temperature': 27.7,
        'humidity': 36,
        'battery': 100,
        'co2': 725,
      });
    });

    test('Hub 2', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '7600'},
          manufacturerData: {0x0969: 'aabbccddeeff00ff66541af182079a3200'},
        ),
      )!;
      expect(values(out), {
        'temperature': 26.7,
        'humidity': 50,
        'illuminance': 10,
      });
    });

    test('Contact Sensor', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '64406405007500f812'},
          manufacturerData: {0x0969: 'e7ab46ac8f927c0f001104'},
        ),
      )!;
      expect(out.kind, DeviceKind.security);
      expect(values(out), {
        'open': true,
        'motion': true,
        'light': true,
        'button presses': 2,
        'battery': 100,
      });
    });

    test('Water Leak Detector', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '26004e'},
          manufacturerData: {0x0969: 'c43430374c7a184e98675e94513c0500000000'},
        ),
      )!;
      expect(values(out), {'leak': false, 'tampered': false, 'battery': 78});
    });

    test('Plug Mini (US)', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '6700'},
          manufacturerData: {0x0969: 'AABBCCDDEEFF0080003C000A'},
        ),
      )!;
      expect(out.kind, DeviceKind.switches);
      expect(values(out), {'on': true, 'power': 1.0, 'wifi signal': -60});
    });

    test('an off Plug Mini draws nothing, whatever it last measured', () {
      // Chloe's BC0A just after switching off still sends ~532 W.
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '6700'},
          manufacturerData: {0x0969: 'AABBCCDDEEFF0000003C14C8'},
        ),
      )!;
      expect(values(out)['on'], false);
      expect(values(out)['power'], 0.0);
    });

    test('Curtain reports how open it is', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          serviceData: {0xFD3D: '63c058001104'},
          manufacturerData: {0x0969: 'e7ab46ac8f927c0f001104'},
        ),
      )!;
      // pySwitchbot reports 100 for this packet (its "position" is
      // inverted by default); Le'Casa says the same thing as 100 % open.
      expect(values(out)['position'], 100);
      expect(values(out)['battery'], 88);
    });
  });

  group('Govee', () {
    test('H5075, with the iBeacon tail glued on', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          name: 'GVH5075_2762',
          manufacturerData: {
            0xEC88: '000341c264004c000215494e54454c4c495f524f434b535f48575075f2ff0c',
          },
        ),
      )!;
      expect(out.model, 'Govee H5075');
      expect(values(out), {
        'temperature': 21.3,
        'humidity': 44.2,
        'battery': 100,
      });
    });

    test("Chloe's H5075, captured on the Mac", () {
      final out = DecoderRegistry.standard().decode(
        adv(name: 'GVH5075_3804', manufacturerData: {0xEC88: '00040ff66400'}),
      )!;
      expect(values(out), {
        'temperature': 26.6,
        'humidity': 23.0,
        'battery': 100,
      });
    });

    test('H5074', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          name: 'Govee_H5074_5FF4',
          manufacturerData: {
            0xEC88: '00e609bc126402',
            0x004C: '0215494e54454c4c495f524f434b535f48575075f2ffc2',
          },
        ),
      )!;
      expect(values(out), {
        'temperature': 25.34,
        'humidity': 47.96,
        'battery': 100,
      });
    });

    test('H5100', () {
      final out = DecoderRegistry.standard().decode(
        adv(name: 'GVH5100_7738', manufacturerData: {0x0001: '010103465464'}),
      )!;
      expect(out.model, 'Govee H5100');
      expect(values(out), {
        'temperature': 21.4,
        'humidity': 61.2,
        'battery': 100,
      });
    });

    test('H5140 CO2', () {
      final out = DecoderRegistry.standard().decode(
        adv(name: 'GV5140303A', manufacturerData: {0x0001: '0101033dee023e00'}),
      )!;
      expect(values(out), {'temperature': 21.2, 'humidity': 46.2, 'co2': 574});
    });

    test('H5106 below freezing', () {
      final out = DecoderRegistry.standard().decode(
        adv(name: 'GVH5106_4E05', manufacturerData: {0x0001: '010181867cd8'}),
      )!;
      expect(values(out), {'temperature': -2.5, 'humidity': 59.1, 'pm2.5': 0});
    });

    test('H5178 outdoor sensor error, then the indoor one', () {
      final reg = DecoderRegistry.standard();
      final out = reg.decode(
        adv(
          name: 'B51782BC8',
          manufacturerData: {0x0001: '0101010003e7e40001'},
        ),
      )!;
      expect(values(out), {
        'outdoor temperature': null,
        'outdoor humidity': null,
        'outdoor battery': 100,
      });
    });

    test('H5182 probes; an empty socket reads as nothing', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          name: 'F34DC3CB-9CCF-336F-3CB1-3C6F525509E6',
          manufacturerData: {
            0x2730: '6301000101e40101ffff120301ffff00004c000215494e54454c4c495f524f434b535f48575075f2ff0c',
          },
          serviceUuids: [0x8251],
        ),
      )!;
      expect(values(out), {
        'probe 1': null,
        'probe 1 alarm': 46.11,
        'probe 2': null,
        'probe 2 alarm': 0.0,
      });
    });

    test('H5184 probes 1 and 2', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          name: 'GVH5184_XXXX',
          manufacturerData: {0x1B36: '2001000101e401860c1cffff860af0ffff'},
        ),
      )!;
      expect(values(out), {
        'probe 1': 31.0,
        'probe 1 alarm': null,
        'probe 2': 28.0,
        'probe 2 alarm': null,
      });
    });

    test('H5055 six-probe thermometer', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          manufacturerData: {
            0xAF2F: '55006401201a00ffffffff201900ffffffff0000',
          },
          serviceUuids: [0x5550],
        ),
      )!;
      expect(values(out), {
        'probe 1': 26.0,
        'probe 1 alarm': null,
        'probe 1 low alarm': null,
        'battery': 100,
      });
    });

    test('H5121 motion is an event', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          name: 'GV5121195A',
          manufacturerData: {
            0xEF88: '59940000f0b91937ae50b6372c866ac2f3d061e717c02cef',
          },
        ),
      )!;
      expect(out.model, 'Govee H5121 Motion Sensor');
      expect(values(out), {'battery': 100});
      expect(out.events.single.kind, 'motion');
    });

    test('H5123 door open', () {
      final out = DecoderRegistry.standard().decode(
        adv(
          name: 'GV51230B3D',
          manufacturerData: {
            0xEF88: '3dec0000de4377d55e55f991496e36bdc67f8b2c27067497',
          },
        ),
      )!;
      expect(values(out), {'open': true, 'battery': 100});
    });

    test('a bad CRC is not a reading', () {
      expect(
        decodeGovee(
          adv(name: 'GV5121195A'),
          0xEF88,
          fromHex('59940000f0b91937ae50b6372c866ac2f3d061e717c00000'),
        ),
        isNull,
      );
    });
  });
}
