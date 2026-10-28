// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/drivers/alpicool_driver.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/drivers/ideal_led.dart';
import 'package:lecasa/drivers/switchbot_driver.dart';
import 'package:lecasa/voice/voice_tools.dart';

Decoded _light({String colour = '#FF0000', int brightness = 40}) => Decoded(
  protocol: 'iDeal LED',
  model: 'iDeal LED strip',
  kind: DeviceKind.lights,
  readings: [
    const Reading(LightSetting.on, true),
    const Reading(LightSetting.pattern, idealSolid),
    Reading(LightSetting.colour, colour),
    Reading(LightSetting.brightness, brightness, '%'),
  ],
);

final _fridge = Decoded(
  protocol: 'Alpicool',
  model: 'Alpicool fridge',
  kind: DeviceKind.appliance,
  readings: const [
    Reading(FridgeSetting.power, true),
    Reading('temperature', 4, '°C'),
    Reading(FridgeSetting.target, 3, '°C'),
  ],
  info: const {'settable range': '-20 to 20 °C'},
);

final _shunt = Decoded(
  protocol: 'Victron',
  model: 'SmartShunt',
  kind: DeviceKind.battery,
  readings: const [
    Reading('state of charge', 87.0, '%'),
    Reading('voltage', 13.2, 'V'),
  ],
);

VoiceCatalog _home() => VoiceCatalog([
  VoiceDevice('k', 'Kitchen strip', VoiceKind.light, _light()),
  VoiceDevice('b', 'Bed strip', VoiceKind.light, _light(colour: '#0000FF')),
  VoiceDevice('p', 'Kettle', VoiceKind.plug, null),
  VoiceDevice('f', 'Fridge', VoiceKind.fridge, _fridge),
  VoiceDevice('s', 'Lilith', VoiceKind.sensor, _shunt),
]);

Map<String, Object?> _call(
  String name,
  Map<String, Object?> args, {
  double confidence = 0.9,
  String heard = '',
}) => {
  'function_calls': [
    {'name': name, 'arguments': args},
  ],
  'confidence': confidence,
  'audio_text': heard,
};

void main() {
  test('tools only offer what the home has', () {
    final names = [
      for (final t in VoiceCatalog([
        VoiceDevice('p', 'Kettle', VoiceKind.plug, null),
      ]).tools)
        t['name'],
    ];
    expect(names, ['turn_on', 'turn_off', 'get_reading']);
    final all = [for (final t in _home().tools) t['name']];
    expect(all, contains('set_light_color'));
    expect(all, contains('set_fridge_temperature'));
  });

  test('device names are an enum, with all lights when there are two', () {
    final on = _home().tools.firstWhere((t) => t['name'] == 'turn_on');
    final props = (on['parameters'] as Map)['properties'] as Map;
    expect((props['device'] as Map)['enum'], [
      allLights,
      'Kitchen strip',
      'Bed strip',
      'Kettle',
      'Fridge',
    ]);
  });

  test('same names get a number', () {
    final c = VoiceCatalog([
      VoiceDevice('a', 'Strip', VoiceKind.light, null),
      VoiceDevice('b', 'strip', VoiceKind.light, null),
    ]);
    expect(c.devices.map((d) => d.name), ['Strip', 'strip 2']);
  });

  test('a colour keeps the brightness the light has', () {
    final o = _home().interpret(
      _call('set_light_color', {'device': 'Kitchen strip', 'color': 'blue'}),
    );
    expect(o, isA<VoiceAct>());
    final c = (o as VoiceAct).commands.single;
    expect(c.device.id, 'k');
    expect(c.command.setting, LightSetting.colour);
    expect(c.command.value, {'rgb': 0x0000FF, 'brightness': 40});
    expect(c.summary, 'Kitchen strip: blue');
  });

  test('brightness re-sends the colour', () {
    final o = _home().interpret(
      _call('set_light_brightness', {'device': 'Bed strip', 'brightness': 75}),
    );
    final c = (o as VoiceAct).commands.single;
    expect(c.command.value, {'rgb': 0x0000FF, 'brightness': 75});
  });

  test('all lights turns off every light', () {
    final o = _home().interpret(
      _call('turn_off', {'device': allLights}, heard: 'lights off'),
    );
    final cs = (o as VoiceAct).commands;
    expect(cs.map((c) => c.device.id), ['k', 'b']);
    expect(cs.every((c) => c.command.value == false), isTrue);
  });

  test('the words said fix a lost "off"', () {
    final o = _home().interpret(
      _call('turn_on', {
        'device': 'Bed strip',
      }, heard: 'Switch off the bed strip.'),
    );
    final c = (o as VoiceAct).commands.single;
    expect(c.command.setting, LightSetting.on);
    expect(c.command.value, false);
  });

  test('plugs and fridges use their own settings', () {
    final h = _home();
    final plug = h.interpret(_call('turn_on', {'device': 'Kettle'}));
    expect(
      (plug as VoiceAct).commands.single.command.setting,
      SwitchSetting.on,
    );
    final fridge = h.interpret(_call('turn_off', {'device': 'Fridge'}));
    expect(
      (fridge as VoiceAct).commands.single.command.setting,
      FridgeSetting.power,
    );
  });

  test('fridge temperature is held to its range', () {
    final o = _home().interpret(
      _call('set_fridge_temperature', {'device': 'Fridge', 'temperature': -40}),
    );
    final c = (o as VoiceAct).commands.single;
    expect(c.command.setting, FridgeSetting.target);
    expect(c.command.value, -20);
    expect(c.summary, 'Fridge: -20 °C');
  });

  test('questions are answered from readings', () {
    final o = _home().interpret(_call('get_reading', {'device': 'Lilith'}));
    expect(
      (o as VoiceAnswer).answer,
      'Lilith: state of charge 87 %, voltage 13.2 V',
    );
  });

  test('low confidence asks first', () {
    final o = _home().interpret(
      _call('turn_on', {'device': 'Kettle'}, confidence: 0.07),
    );
    expect(o, isA<VoiceConfirm>());
  });

  test('a withheld call is offered to confirm', () {
    final o = _home().interpret({
      'function_calls': <Object>[],
      'suppressed_calls': [
        {
          'name': 'turn_on',
          'arguments': {'device': 'Kettle'},
        },
      ],
      'confidence': 0.08,
    });
    expect(o, isA<VoiceConfirm>());
  });

  test('noise-level confidence is not asked about', () {
    final o = _home().interpret(
      _call('turn_off', {'device': 'Kettle'}, confidence: 0.013),
    );
    expect(o, isA<VoiceNotUnderstood>());
  });

  test('a refusal or an unknown device is not understood', () {
    final h = _home();
    expect(
      h.interpret({'function_calls': <Object>[], 'audio_text': 'sing'}),
      isA<VoiceNotUnderstood>(),
    );
    expect(
      h.interpret(_call('turn_on', {'device': 'Toaster'})),
      isA<VoiceNotUnderstood>(),
    );
  });

  test('kinds come from the decoded device', () {
    expect(VoiceDevice.kindOf(_light(), controllable: true), VoiceKind.light);
    expect(VoiceDevice.kindOf(_fridge, controllable: true), VoiceKind.fridge);
    expect(VoiceDevice.kindOf(_fridge, controllable: false), VoiceKind.sensor);
    expect(VoiceDevice.kindOf(_shunt, controllable: false), VoiceKind.sensor);
  });

  test('commands carry DeviceCommand', () {
    final c = _home().commandsFor('turn_on', {'device': 'Kettle'}).single;
    expect(c.command, isA<DeviceCommand>());
  });

  test('batteries and solar are answered all at once', () {
    Decoded kind(DeviceKind k, List<Reading> rs) =>
        Decoded(protocol: 'test', model: 'test', kind: k, readings: rs);
    final home = VoiceCatalog([
      VoiceDevice(
        'l',
        'Lilith',
        VoiceKind.sensor,
        kind(DeviceKind.battery, const [
          Reading('state of charge', 72.6, '%'),
          Reading('voltage', 26.51, 'V'),
          Reading('current', -7.458, 'A'),
          Reading('time to go', 688, 'min'),
        ]),
      ),
      VoiceDevice('d', 'Battery 12BA', VoiceKind.sensor, null),
      VoiceDevice(
        's',
        'Sol 30',
        VoiceKind.sensor,
        kind(DeviceKind.solar, const [
          Reading('yield today', 270, 'Wh'),
          Reading('solar power', 0, 'W'),
        ]),
      ),
      VoiceDevice(
        'u',
        'Luna 50',
        VoiceKind.sensor,
        kind(DeviceKind.solar, const [
          Reading('yield today', 3430, 'Wh'),
          Reading('solar power', 0, 'W'),
        ]),
      ),
    ]);
    expect(
      home.batteries(),
      'Lilith 73 %, discharging 198 W, about 11 h left',
    );
    expect(
      home.solar(),
      'Solar 0 W now, 3.7 kWh today (Sol 30 270 Wh, Luna 50 3.4 kWh)',
    );
    final o = home.interpret({
      'function_calls': [
        {
          'name': 'get_reading',
          'arguments': {'device': allSolar},
        },
      ],
      'confidence': 1.0,
    }, heard: 'how much solar today');
    expect((o as VoiceAnswer).answer, home.solar());
  });
}
