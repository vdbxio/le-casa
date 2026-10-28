// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import '../decoders/decoded.dart';
import '../drivers/alpicool_driver.dart';
import '../drivers/driver.dart';
import '../drivers/ideal_led.dart';
import '../drivers/switchbot_driver.dart';

/// What a voice command can do to a device.
enum VoiceKind { light, plug, fridge, sensor }

/// One device as voice sees it: the name people call it and what it shows.
class VoiceDevice {
  final String id;
  final String name;
  final VoiceKind kind;
  final Decoded? state;

  const VoiceDevice(this.id, this.name, this.kind, this.state);

  Object? value(String label) =>
      state?.readings.where((r) => r.label == label).firstOrNull?.value;

  /// Sorts a device into what voice can do with it; null for ones it
  /// leaves alone (phones, setup adverts).
  static VoiceKind? kindOf(Decoded? d, {required bool controllable}) {
    if (d == null) return null;
    if (controllable) {
      if (d.kind == DeviceKind.lights) return VoiceKind.light;
      if (d.kind == DeviceKind.switches) return VoiceKind.plug;
      if (d.protocol == 'Alpicool') return VoiceKind.fridge;
    }
    return switch (d.kind) {
      DeviceKind.needsSetup ||
      DeviceKind.improv ||
      DeviceKind.background => null,
      _ when d.readings.isEmpty => null,
      _ => VoiceKind.sensor,
    };
  }
}

/// A change voice is about to make.
class VoiceCommand {
  final VoiceDevice device;
  final DeviceCommand command;

  /// What it does, for the screen: "Kitchen strip: blue".
  final String summary;

  const VoiceCommand(this.device, this.command, this.summary);
}

/// What came of something said.
sealed class VoiceOutcome {
  /// What Whistle heard.
  final String heard;
  const VoiceOutcome(this.heard);
}

/// Changes to make now.
class VoiceAct extends VoiceOutcome {
  final List<VoiceCommand> commands;
  const VoiceAct(super.heard, this.commands);
}

/// Changes Needle was unsure of: shown as "Did you mean…?" for a tap.
class VoiceConfirm extends VoiceOutcome {
  final List<VoiceCommand> commands;
  const VoiceConfirm(super.heard, this.commands);
}

/// An answer to a question, shown on screen.
class VoiceAnswer extends VoiceOutcome {
  final String answer;
  const VoiceAnswer(super.heard, this.answer);
}

/// Nothing Le'Casa can do with it.
class VoiceNotUnderstood extends VoiceOutcome {
  const VoiceNotUnderstood(super.heard);
}

/// Extra colours people say that the light page has no button for.
const voiceColours = <(String, int)>[
  ...lightColours,
  ('Pink', 0xFF2080),
  ('Yellow', 0xFFC000),
  ('Cyan', 0x00FFFF),
];

/// The enum value that picks every light at once.
const allLights = 'all lights';

/// The answer to "how are my batteries?": every battery at once.
const allBatteries = 'all batteries';

/// The answer to "how much solar today?": every solar charger at once.
const allSolar = 'all solar';

/// Turns the devices in the home into Needle tools, and Needle's answers
/// back into device commands. Pure Dart, so it is tested without the
/// engine.
class VoiceCatalog {
  final List<VoiceDevice> devices;

  /// Calls at or above this go out at once; lower ones are asked about.
  /// The base model scored a correct "turn the kitchen lights blue" at
  /// 0.19 on the Mac, so the bar sits low and the screen shows what it did.
  final double actAt;

  /// Below this a call is not even asked about: on the M10 room noise
  /// came back as "Did you mean … off?" at 0.013.
  final double askAt;

  VoiceCatalog(
    Iterable<VoiceDevice> devices, {
    this.actAt = 0.1,
    this.askAt = 0.05,
  }) : devices = _uniqueNames(devices);

  static List<VoiceDevice> _uniqueNames(Iterable<VoiceDevice> all) {
    final seen = <String, int>{};
    return [
      for (final d in all)
        if (d.name.trim().isNotEmpty)
          () {
            final key = d.name.trim().toLowerCase();
            final n = seen[key] = (seen[key] ?? 0) + 1;
            return n == 1
                ? d
                : VoiceDevice(d.id, '${d.name.trim()} $n', d.kind, d.state);
          }(),
    ];
  }

  Iterable<VoiceDevice> of(VoiceKind k) => devices.where((d) => d.kind == k);

  List<String> _names(Iterable<VoiceDevice> ds) => [for (final d in ds) d.name];

  bool get isEmpty => devices.isEmpty;

  /// Words Whistle should favour: device names, colours, scenes and the
  /// wake word.
  List<String> get keywords => [
    'Hey Gary',
    'Gary',
    ...devices.map((d) => d.name),
    for (final (name, _) in voiceColours) name.toLowerCase(),
    if (of(VoiceKind.light).isNotEmpty)
      for (final p in idealPatterns) p.name.toLowerCase(),
  ];

  /// The Needle tools for these devices, in the flat form the engine
  /// takes. Tools with no device to act on are left out, so Needle cannot
  /// pick them.
  List<Map<String, Object?>> get tools {
    final lights = _names(of(VoiceKind.light));
    final switchable = [
      if (lights.length > 1) allLights,
      ...lights,
      ..._names(of(VoiceKind.plug)),
      ..._names(of(VoiceKind.fridge)),
    ];
    final fridges = _names(of(VoiceKind.fridge));
    Map<String, Object?> device(List<String> names, String what) => {
      'type': 'string',
      'description': what,
      'enum': names,
    };
    Map<String, Object?> tool(
      String name,
      String description,
      Map<String, Object?> props, {
      List<String> required = const ['device'],
      List<String>? triggers,
    }) => {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': props,
        'required': required,
      },
      'triggers': ?triggers,
    };
    final lightNames = [if (lights.length > 1) allLights, ...lights];
    return [
      if (switchable.isNotEmpty) ...[
        tool(
          'turn_on',
          'Turn a light, plug or fridge on.',
          {'device': device(switchable, 'what to turn on')},
          triggers: [r'\b(turn|switch|put)\b.*\bon\b'],
        ),
        tool(
          'turn_off',
          'Turn a light, plug or fridge off.',
          {'device': device(switchable, 'what to turn off')},
          triggers: [r'\b(turn|switch|shut|put)\b.*\boff\b'],
        ),
      ],
      if (lights.isNotEmpty) ...[
        tool(
          'set_light_color',
          'Change the colour of a light.',
          {
            'device': device(lightNames, 'the light'),
            'color': {
              'type': 'string',
              'enum': [for (final (n, _) in voiceColours) n.toLowerCase()],
            },
          },
          required: ['device', 'color'],
        ),
        tool(
          'set_light_brightness',
          'Dim or brighten a light, in percent.',
          {
            'device': device(lightNames, 'the light'),
            'brightness': {'type': 'integer', 'minimum': 1, 'maximum': 100},
          },
          required: ['device', 'brightness'],
        ),
        tool(
          'set_light_scene',
          'Play an animated scene or effect on a light.',
          {
            'device': device(lightNames, 'the light'),
            'scene': {
              'type': 'string',
              'enum': [for (final p in idealPatterns) p.name.toLowerCase()],
            },
          },
          required: ['device', 'scene'],
        ),
      ],
      if (fridges.isNotEmpty)
        tool(
          'set_fridge_temperature',
          'Set the fridge temperature.',
          {
            'device': device(fridges, 'the fridge'),
            'temperature': {'type': 'integer', 'minimum': -30, 'maximum': 30},
          },
          required: ['device', 'temperature'],
        ),
      if (devices.isNotEmpty)
        tool(
          'get_reading',
          'Answer a question about a device: battery level, solar power, '
              'temperature, humidity, whether it is on.',
          {'device': device(_names(devices), 'the device asked about')},
        ),
    ];
  }

  VoiceDevice? _named(Object? name) {
    final n = '$name'.trim().toLowerCase();
    return devices.where((d) => d.name.toLowerCase() == n).firstOrNull;
  }

  List<VoiceDevice> _targets(Object? name, [VoiceKind? only]) {
    if ('$name'.trim().toLowerCase() == allLights) {
      return of(VoiceKind.light).toList();
    }
    final d = _named(name);
    return d == null || (only != null && d.kind != only) ? [] : [d];
  }

  /// Reads one engine response. [response] is the decoded JSON
  /// `needle_complete` returns.
  VoiceOutcome interpret(Map<String, Object?> response, {String? heard}) {
    final text =
        heard ??
        (response['audio_text'] ?? response['text'] ?? '').toString().trim();
    List<Map<String, Object?>> calls(Object? v) => [
      if (v is List)
        for (final c in v)
          if (c is Map) c.cast<String, Object?>(),
    ];
    final made = calls(response['function_calls']);
    final held = calls(response['suppressed_calls']);
    final conf = (response['confidence'] as num?)?.toDouble();
    final sure = made.isNotEmpty && (conf == null || conf >= actAt);
    final picked = made.isNotEmpty ? made : held;
    if (picked.isEmpty || (!sure && (conf ?? 0) < askAt)) {
      return VoiceNotUnderstood(text);
    }

    final commands = <VoiceCommand>[];
    final answers = <String>[];
    for (final c in picked) {
      final args = (c['arguments'] as Map?)?.cast<String, Object?>() ?? {};
      final name = _polarity('${c['name']}', text);
      if (name == 'get_reading') {
        final asked = '${args['device']}'.trim().toLowerCase();
        final d = _named(args['device']);
        if (asked == allBatteries) {
          answers.add(batteries());
        } else if (asked == allSolar) {
          answers.add(solar());
        } else if (d != null) {
          answers.add(describe(d));
        }
        continue;
      }
      commands.addAll(commandsFor(name, args));
    }
    if (answers.isNotEmpty && commands.isEmpty) {
      return VoiceAnswer(text, answers.join('\n'));
    }
    if (commands.isEmpty) return VoiceNotUnderstood(text);
    return sure ? VoiceAct(text, commands) : VoiceConfirm(text, commands);
  }

  /// Needle sometimes keeps the tool but loses the "off" ("switch off the
  /// bed strip" came back as a plain set call on the Mac). The words said
  /// decide between the paired on and off tools.
  static String _polarity(String tool, String heard) {
    if (tool != 'turn_on' && tool != 'turn_off') return tool;
    final h = ' ${heard.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), ' ')} ';
    final off = h.contains(' off ');
    final on = h.contains(' on ');
    if (off && !on) return 'turn_off';
    if (on && !off) return 'turn_on';
    return tool;
  }

  /// The device commands for one tool call; empty when it names nothing
  /// Le'Casa knows.
  List<VoiceCommand> commandsFor(String tool, Map<String, Object?> args) {
    final out = <VoiceCommand>[];
    switch (tool) {
      case 'turn_on' || 'turn_off':
        final on = tool == 'turn_on';
        for (final d in _targets(args['device'])) {
          final setting = switch (d.kind) {
            VoiceKind.light => LightSetting.on,
            VoiceKind.plug => SwitchSetting.on,
            VoiceKind.fridge => FridgeSetting.power,
            VoiceKind.sensor => null,
          };
          if (setting == null) continue;
          out.add(
            VoiceCommand(
              d,
              DeviceCommand(setting, on),
              '${d.name}: ${on ? 'on' : 'off'}',
            ),
          );
        }
      case 'set_light_color':
        final want = '${args['color']}'.toLowerCase();
        final colour = voiceColours
            .where((c) => c.$1.toLowerCase() == want)
            .firstOrNull;
        if (colour == null) break;
        for (final d in _targets(args['device'], VoiceKind.light)) {
          out.add(
            VoiceCommand(
              d,
              DeviceCommand(LightSetting.colour, {
                'rgb': colour.$2,
                'brightness': _brightness(d),
              }),
              '${d.name}: $want',
            ),
          );
        }
      case 'set_light_brightness':
        final pct = (args['brightness'] as num?)?.toInt().clamp(1, 100);
        if (pct == null) break;
        for (final d in _targets(args['device'], VoiceKind.light)) {
          // Brightness has no command of its own: send the look again.
          final p = idealPatternNamed(d.value(LightSetting.pattern));
          final rgb = idealLedRgb(d.value(LightSetting.colour)) ?? 0xFFFFFF;
          final command = p != null && p.name != idealSolid
              ? DeviceCommand(LightSetting.pattern, {
                  'pattern': p.name,
                  'rgb': rgb,
                  'speed': (d.value(LightSetting.speed) as num? ?? 80).toInt(),
                  'brightness': pct,
                })
              : DeviceCommand(LightSetting.colour, {
                  'rgb': rgb,
                  'brightness': pct,
                });
          out.add(VoiceCommand(d, command, '${d.name}: $pct %'));
        }
      case 'set_light_scene':
        final want = '${args['scene']}'.toLowerCase();
        final p = idealPatterns
            .where((p) => p.name.toLowerCase() == want)
            .firstOrNull;
        if (p == null) break;
        for (final d in _targets(args['device'], VoiceKind.light)) {
          out.add(
            VoiceCommand(
              d,
              DeviceCommand(LightSetting.pattern, {
                'pattern': p.name,
                'rgb': idealLedRgb(d.value(LightSetting.colour)) ?? 0xFFFFFF,
                'speed': (d.value(LightSetting.speed) as num? ?? 80).toInt(),
                'brightness': _brightness(d),
              }),
              '${d.name}: ${p.name.toLowerCase()}',
            ),
          );
        }
      case 'set_fridge_temperature':
        final t = (args['temperature'] as num?)?.toInt();
        if (t == null) break;
        for (final d in _targets(args['device'], VoiceKind.fridge)) {
          final range = _range(d);
          final v = range == null ? t : t.clamp(range.$1, range.$2);
          final unit =
              d.state?.readings
                  .where((r) => r.label == FridgeSetting.target)
                  .firstOrNull
                  ?.unit ??
              '°C';
          out.add(
            VoiceCommand(
              d,
              DeviceCommand(FridgeSetting.target, v),
              '${d.name}: $v $unit',
            ),
          );
        }
    }
    return out;
  }

  static int _brightness(VoiceDevice d) =>
      (d.value(LightSetting.brightness) as num? ?? 100).toInt().clamp(1, 100);

  static (int, int)? _range(VoiceDevice d) {
    final m = RegExp(r'^(-?\d+) to (-?\d+)')
        .firstMatch(d.state?.info['settable range'] ?? '');
    return m == null ? null : (int.parse(m[1]!), int.parse(m[2]!));
  }

  /// A device's readings in a line: "Lilith: 87 % state of charge, 13.2 V".
  /// "Lilith 73 %, discharging 198 W, about 11 h left", a line for each
  /// battery that has readings.
  String batteries() {
    final lines = <String>[];
    for (final d in devices.where((d) => d.state?.kind == DeviceKind.battery)) {
      final soc = _num(d, 'state of charge');
      if (soc == null) continue;
      final v = _num(d, 'voltage');
      final a = _num(d, 'current');
      final w = v != null && a != null ? (v * a).round() : null;
      final flow = switch (w) {
        null => null,
        _ when w.abs() < 5 => 'resting',
        _ when w > 0 => 'charging ${w.abs()} W',
        _ => 'discharging ${w.abs()} W',
      };
      final ttg = _num(d, 'time to go');
      final left = ttg != null && w != null && w < -5
          ? 'about ${_hours(ttg)} left'
          : null;
      lines.add(
        '${d.name} ${soc.round()} %${[?flow, ?left].map((s) => ', $s').join()}',
      );
    }
    return lines.isEmpty ? 'No battery readings yet' : lines.join('\n');
  }

  /// "Solar 0 W now, 3.7 kWh today (Luna 50 3.4 kWh, Sol 30 0.3 kWh)".
  String solar() {
    final ds = [
      for (final d in devices)
        if (d.state?.kind == DeviceKind.solar) d,
    ];
    if (ds.isEmpty) return 'No solar readings yet';
    var now = 0.0;
    var today = 0.0;
    final each = <String>[];
    for (final d in ds) {
      now += _num(d, 'solar power') ?? _num(d, 'power') ?? 0;
      final y = _num(d, 'yield today');
      if (y != null) {
        today += y;
        each.add('${d.name} ${_kwh(y)}');
      }
    }
    final split = ds.length > 1 && each.isNotEmpty
        ? ' (${each.join(', ')})'
        : '';
    return 'Solar ${now.round()} W now, ${_kwh(today)} today$split';
  }

  static double? _num(VoiceDevice d, String label) {
    for (final r in d.state?.readings ?? const <Reading>[]) {
      if (r.label == label && r.value is num) {
        return (r.value as num).toDouble();
      }
    }
    return null;
  }

  static String _kwh(double wh) =>
      wh < 1000 ? '${wh.round()} Wh' : '${(wh / 1000).toStringAsFixed(1)} kWh';

  static String _hours(double minutes) => minutes < 90
      ? '${minutes.round()} min'
      : '${(minutes / 60).round()} h';

  static String describe(VoiceDevice d, {int most = 4}) {
    final rs = [
      for (final r in d.state?.readings ?? const <Reading>[])
        if (r.value != null) r,
    ];
    if (rs.isEmpty) return "${d.name}: no readings yet";
    return '${d.name}: '
        '${rs.take(most).map(_say).join(', ')}';
  }

  /// "power 0 W"; a plain on/off reading is just "off", not "on off".
  static String _say(Reading r) {
    final l = r.label.toLowerCase();
    if (r.value is bool && (l == 'on' || l == 'power' || l == 'state')) {
      return r.display;
    }
    return '${r.label} ${r.display}';
  }
}
