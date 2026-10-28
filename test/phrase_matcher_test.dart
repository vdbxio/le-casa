// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/voice/phrase_matcher.dart';
import 'package:lecasa/voice/voice_tools.dart';

Decoded _kind(DeviceKind k, [List<Reading> rs = const []]) =>
    Decoded(protocol: 'test', model: 'test', kind: k, readings: rs);

final _home = VoiceCatalog([
  VoiceDevice('k', 'Kitchen strip', VoiceKind.light, _kind(DeviceKind.lights)),
  VoiceDevice('b', 'Bed strip', VoiceKind.light, _kind(DeviceKind.lights)),
  VoiceDevice('p', 'Kettle', VoiceKind.plug, _kind(DeviceKind.switches)),
  VoiceDevice('f', 'Fridge', VoiceKind.fridge, _kind(DeviceKind.appliance)),
  VoiceDevice(
    's',
    'Lilith',
    VoiceKind.sensor,
    _kind(DeviceKind.battery, const [Reading('state of charge', 80.0, '%')]),
  ),
  VoiceDevice(
    'm',
    'Sol 30',
    VoiceKind.sensor,
    _kind(DeviceKind.solar, const [Reading('power', 120, 'W')]),
  ),
]);

Object? _m(String said, [VoiceCatalog? home]) {
  final calls = matchPhrase(home ?? _home, said);
  if (calls == null) return null;
  return [
    for (final c in calls) [c['name'], c['arguments']],
  ];
}

void main() {
  test('on and off by name', () {
    expect(_m('Turn off the kitchen strip.'), [
      [
        'turn_off',
        {'device': 'Kitchen strip'},
      ],
    ]);
    expect(_m('kitchen lights on'), [
      [
        'turn_on',
        {'device': 'Kitchen strip'},
      ],
    ]);
    expect(_m('Switch the kettle on please'), [
      [
        'turn_on',
        {'device': 'Kettle'},
      ],
    ]);
    expect(_m('turn the fridge off'), [
      [
        'turn_off',
        {'device': 'Fridge'},
      ],
    ]);
  });

  test('the lights means all of them', () {
    expect(_m('Lights off.'), [
      [
        'turn_off',
        {'device': allLights},
      ],
    ]);
    expect(_m('turn everything on'), [
      [
        'turn_on',
        {'device': allLights},
      ],
    ]);
  });

  test('colours and scenes', () {
    expect(_m('Turn the kitchen lights blue.'), [
      [
        'set_light_color',
        {'device': 'Kitchen strip', 'color': 'blue'},
      ],
    ]);
    expect(_m('make the bed strip warm'), [
      [
        'set_light_color',
        {'device': 'Bed strip', 'color': 'warm'},
      ],
    ]);
    expect(_m('rainbow flow on the kitchen strip'), [
      [
        'set_light_scene',
        {'device': 'Kitchen strip', 'scene': 'rainbow flow'},
      ],
    ]);
  });

  test('brightness', () {
    expect(_m('Dim the bed strip to 20%.'), [
      [
        'set_light_brightness',
        {'device': 'Bed strip', 'brightness': 20},
      ],
    ]);
    expect(_m('kitchen strip seventy five percent'), [
      [
        'set_light_brightness',
        {'device': 'Kitchen strip', 'brightness': 75},
      ],
    ]);
    expect(_m('dim the lights'), [
      [
        'set_light_brightness',
        {'device': allLights, 'brightness': 30},
      ],
    ]);
  });

  test('fridge temperature', () {
    expect(_m('Set the fridge to 3 degrees.'), [
      [
        'set_fridge_temperature',
        {'device': 'Fridge', 'temperature': 3},
      ],
    ]);
    expect(_m('fridge minus four'), [
      [
        'set_fridge_temperature',
        {'device': 'Fridge', 'temperature': -4},
      ],
    ]);
  });

  test('questions', () {
    expect(_m("What's the battery at?"), [
      [
        'get_reading',
        {'device': allBatteries},
      ],
    ]);
    expect(_m('How much solar are we getting'), [
      [
        'get_reading',
        {'device': allSolar},
      ],
    ]);
    expect(_m('is the kettle on'), [
      [
        'get_reading',
        {'device': 'Kettle'},
      ],
    ]);
  });

  test('a number in a name is not a setting', () {
    expect(_m('what is sol 30 doing'), [
      [
        'get_reading',
        {'device': 'Sol 30'},
      ],
    ]);
  });

  test('a single light needs no name', () {
    final one = VoiceCatalog([
      VoiceDevice('k', 'Kitchen strip', VoiceKind.light, null),
    ]);
    expect(_m('make it purple', one), [
      [
        'set_light_color',
        {'device': 'Kitchen strip', 'color': 'purple'},
      ],
    ]);
  });

  test('a single light is not switched by talk around it', () {
    final one = VoiceCatalog([
      VoiceDevice('o', 'Outside', VoiceKind.light, null),
    ]);
    expect(_m('turn it off', one), [
      [
        'turn_off',
        {'device': 'Outside'},
      ],
    ]);
    // The TV beside the iPad.
    expect(_m('he came back on him and that is when', one), isNull);
    expect(_m('she wore the blue dress to the party', one), isNull);
  });

  test('an LED strip and a sensor of the same name', () {
    final home = VoiceCatalog([
      VoiceDevice('l', 'Outside LEDs', VoiceKind.light, null),
      VoiceDevice('k', 'Kitchen strip', VoiceKind.light, null),
      VoiceDevice('c', 'Battery Chargers', VoiceKind.plug, null),
      VoiceDevice(
        'o',
        'Outside',
        VoiceKind.sensor,
        _kind(DeviceKind.climate, const [Reading('temperature', 15.6, '°C')]),
      ),
      VoiceDevice(
        'b',
        'Battery 12BA',
        VoiceKind.sensor,
        _kind(DeviceKind.battery, const [Reading('voltage', 13.2, 'V')]),
      ),
    ]);
    // As the M10 heard it.
    expect(_m('turn off the outside leg.', home), [
      [
        'turn_off',
        {'device': 'Outside LEDs'},
      ],
    ]);
    expect(_m('Set outside to rainbow flow.', home), [
      [
        'set_light_scene',
        {'device': 'Outside LEDs', 'scene': 'rainbow flow'},
      ],
    ]);
    expect(_m('said outside to rainbow', home), [
      [
        'set_light_scene',
        {'device': 'Outside LEDs', 'scene': 'rainbow flow'},
      ],
    ]);
    expect(_m('how warm is it outside', home), [
      [
        'get_reading',
        {'device': 'Outside'},
      ],
    ]);
    expect(_m('turn off the battery chargers', home), [
      [
        'turn_off',
        {'device': 'Battery Chargers'},
      ],
    ]);
    // One battery by name, or any of them.
    expect(_m("how's my battery?", home), [
      [
        'get_reading',
        {'device': allBatteries},
      ],
    ]);
    // Whistle on the iPhone, for "how's my batteries".
    expect(_m('has my batteries.', home), [
      [
        'get_reading',
        {'device': allBatteries},
      ],
    ]);
    expect(_m('how are my batteries?', home), [
      [
        'get_reading',
        {'device': allBatteries},
      ],
    ]);
  });

  test('anything else is left for Needle', () {
    expect(_m('I think the game is on later'), isNull);
    expect(_m('what time is it'), isNull);
    expect(_m(''), isNull);
    // Two strips and no hint which.
    expect(_m('strip blue'), [
      [
        'set_light_color',
        {'device': allLights, 'color': 'blue'},
      ],
    ]);
  });
}
