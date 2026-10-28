// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import '../decoders/decoded.dart';
import '../drivers/ideal_led.dart';
import 'voice_tools.dart';

/// Reads the everyday commands straight from the words, with no model:
/// "kitchen lights blue", "turn off the kettle", "fridge to 3 degrees",
/// "what's the battery at". Instant on any tablet; Needle 3 takes about
/// 40 s a command on the PRITOM M10's 32-bit chip, so it only gets what
/// this cannot read, on screens fast enough to run it.
///
/// Returns tool calls in the shape Needle does, for
/// [VoiceCatalog.interpret], or null when the words are not one of these.
List<Map<String, Object?>>? matchPhrase(VoiceCatalog home, String heard) {
  final words = _words(heard);
  if (words.isEmpty) return null;
  final text = ' ${words.join(' ')} ';
  bool has(String w) => text.contains(' $w ');
  bool any(Iterable<String> ws) => ws.any(has);

  final off = any(const ['off', 'shut', 'kill']);
  final on = !off && any(const ['on', 'start']);
  final asks =
      const {
        'what',
        'whats',
        'how',
        'hows',
        // "How's" as the iPhone heard it.
        'has',
        'is',
        'are',
        'does',
        'did',
        'tell',
        'show',
      }.contains(words.first) ||
      has('status') ||
      // "My batteries?" with nothing to switch is a question too.
      (_topic(text) != null && !on && !off);
  final lights = home.of(VoiceKind.light).toList();
  final target = _device(home, words, control: !asks);
  // A number in the device's own name ("Sol 30") is not a setting.
  final named = target == null ? const <String>{} : _words(target.name).toSet();
  final number = _number([
    for (final w in words)
      if (!named.contains(w)) w,
  ]);

  Map<String, Object?> call(String name, Map<String, Object?> args) => {
    'name': name,
    'arguments': args,
  };

  if (asks) {
    // "How are my batteries?", "how much solar today?": all of them, unless
    // one was named ("how is Lilith").
    final topic = _topic(text);
    // "Batteries" also matches a battery's name ("Battery 12BA"); the plural
    // still means every battery.
    final every = topic == DeviceKind.battery && words.contains('batteries');
    // "How's my battery?" names no battery in particular: only a word of
    // the name beyond "battery" or "solar" picks one ("how is Lilith").
    final said = words.map(_stem).toSet();
    final picked =
        target != null &&
        _words(target.name)
            .map(_stem)
            .any(
              (w) =>
                  !_filler.contains(w) &&
                  !const {'battery', 'solar', 'charger'}.contains(w) &&
                  said.contains(w),
            );
    if (topic != null &&
        (every || !picked || target?.state?.kind != topic) &&
        home.devices.any((d) => d.state?.kind == topic)) {
      return [
        call('get_reading', {
          'device': topic == DeviceKind.battery ? allBatteries : allSolar,
        }),
      ];
    }
    final d = target ?? _askedAbout(home, text);
    return d == null
        ? null
        : [
            call('get_reading', {'device': d.name}),
          ];
  }

  // A light, by name or as "the lights".
  String? lightName() {
    if (target != null && target.kind == VoiceKind.light) return target.name;
    if (target != null) return null;
    final generic = any(const [
      'light',
      'lights',
      'strip',
      'strips',
      'leds',
      'led',
      'lamp',
      'lamps',
    ]);
    if (!generic && !any(const ['everything', 'all'])) {
      // "make it blue" with one light in the home; in a longer sentence
      // a stray "on" or "blue" is somebody else talking.
      return lights.length == 1 && words.length <= 4
          ? lights.single.name
          : null;
    }
    if (lights.length == 1) return lights.single.name;
    if (lights.length > 1) return allLights;
    return null;
  }

  for (final (name, _) in voiceColours) {
    if (has(name.toLowerCase())) {
      final l = lightName();
      return l == null
          ? null
          : [
              call('set_light_color', {
                'device': l,
                'color': name.toLowerCase(),
              }),
            ];
    }
  }
  // The whole name ("rainbow flow"), or else its first word ("rainbow"):
  // the first pattern of that family.
  final pattern =
      idealPatterns
          .where((p) => text.contains(' ${_words(p.name).join(' ')} '))
          .firstOrNull ??
      idealPatterns.where((p) => has(_words(p.name).first)).firstOrNull;
  if (pattern != null) {
    final l = lightName();
    return l == null
        ? null
        : [
            call('set_light_scene', {
              'device': l,
              'scene': pattern.name.toLowerCase(),
            }),
          ];
  }

  final fridge =
      target?.kind == VoiceKind.fridge ||
      (target == null && any(const ['fridge', 'freezer', 'cooler']));
  if (fridge && number != null && !off && !on) {
    final f =
        target ??
        (home.of(VoiceKind.fridge).length == 1
            ? home.of(VoiceKind.fridge).single
            : null);
    return f == null
        ? null
        : [
            call('set_fridge_temperature', {
              'device': f.name,
              'temperature': number,
            }),
          ];
  }

  final dim = any(const ['dim', 'darker', 'brightness', 'brighter', 'percent']);
  if (dim || (number != null && !on && !off)) {
    final l = lightName();
    if (l == null) return null;
    final pct =
        number ??
        (any(const ['brighter', 'full', 'max'])
            ? 100
            : (has('dim') ? 30 : null));
    if (pct == null) return null;
    return [
      call('set_light_brightness', {
        'device': l,
        'brightness': pct.clamp(1, 100),
      }),
    ];
  }

  if (on || off) {
    final tool = on ? 'turn_on' : 'turn_off';
    if (target != null && target.kind != VoiceKind.sensor) {
      return [
        call(tool, {'device': target.name}),
      ];
    }
    if (target == null) {
      if (fridge && home.of(VoiceKind.fridge).length == 1) {
        return [
          call(tool, {'device': home.of(VoiceKind.fridge).single.name}),
        ];
      }
      final plugs = home.of(VoiceKind.plug).toList();
      if (any(const ['plug', 'socket', 'outlet']) && plugs.length == 1) {
        return [
          call(tool, {'device': plugs.single.name}),
        ];
      }
      final l = lightName();
      if (l != null &&
          (lights.isNotEmpty) &&
          (any(const [
                'light',
                'lights',
                'strip',
                'strips',
                'leds',
                'lamp',
                'lamps',
                'everything',
                'all',
              ]) ||
              (lights.length == 1 && words.length <= 4))) {
        return [
          call(tool, {'device': l}),
        ];
      }
    }
  }
  return null;
}

/// Lower-case words, apostrophes dropped ("what's" -> "whats"), with the
/// ways Whistle mishears "LEDs" put right.
List<String> _words(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll('%', ' percent ')
    .replaceAll('°', ' degrees ')
    .split(RegExp(r'[^a-z0-9\-]+'))
    .where((w) => w.isNotEmpty)
    .map((w) => _misheard[w] ?? w)
    .toList();

/// Heard on the M10 for "LEDs" (2026-10-28): "the outside legs".
const _misheard = {
  'leg': 'leds',
  'legs': 'leds',
  'lace': 'leds',
  'lids': 'leds',
  'elities': 'leds',
};

/// "batteries" for "Battery", "chargers" for "Charger".
String _stem(String w) => w.length > 4 && w.endsWith('ies')
    ? '${w.substring(0, w.length - 3)}y'
    : (w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w);

/// Words that say nothing about which device.
const _filler = {
  'the',
  'a',
  'an',
  'my',
  'turn',
  'switch',
  'set',
  'make',
  'put',
  'please',
  'on',
  'off',
  'to',
  'it',
  'in',
  'of',
  'and',
  'light',
  'lights',
  'strip',
  'strips',
  'led',
  'leds',
  'lamp',
  'plug',
  'socket',
  'all',
  'up',
  'down',
  'percent',
  'degrees',
  'is',
  'whats',
  'what',
  'how',
  'hows',
  'at',
  'now',
  'hey',
  'gary',
  'can',
  'you',
  'could',
  'be',
};

/// The device whose name shares the most telling words with what was said.
/// A tie is settled by what was asked: "outside off" means the Outside LEDs
/// over the Outside sensor, "how warm is outside" the other way round.
/// Otherwise a tie names neither.
VoiceDevice? _device(
  VoiceCatalog home,
  List<String> said, {
  required bool control,
}) {
  final heard = said.where((w) => !_filler.contains(w)).map(_stem).toSet();
  var best = <VoiceDevice>[];
  var bestScore = 0.0;
  for (final d in home.devices) {
    final name = _words(d.name)
        .where((w) => !_filler.contains(w))
        .map(_stem)
        .toList();
    if (name.isEmpty) continue;
    final hits = name.where(heard.contains).length;
    if (hits == 0) continue;
    // "kitchen" for "Kitchen strip" is a whole match; "bed" for
    // "Bed reading lamp" a partial one.
    final score = hits / name.length + hits;
    if (score > bestScore) {
      best = [d];
      bestScore = score;
    } else if (score == bestScore) {
      best.add(d);
    }
  }
  if (best.length > 1) {
    best = [
      for (final d in best)
        if ((d.kind == VoiceKind.sensor) != control) d,
    ];
  }
  return best.length == 1 ? best.single : null;
}

/// Batteries or solar, when that is what a question is about.
DeviceKind? _topic(String text) {
  bool has(String w) => text.contains(' $w ');
  if (['battery', 'batteries', 'charge'].any(has)) return DeviceKind.battery;
  if (['solar', 'sun', 'panels', 'panel'].any(has)) return DeviceKind.solar;
  return null;
}

/// "What's the battery at?" with no device named: the one device of that
/// kind.
VoiceDevice? _askedAbout(VoiceCatalog home, String text) {
  final kind = switch (text) {
    _
        when text.contains(' battery ') ||
            text.contains(' batteries ') ||
            text.contains(' charge ') =>
      DeviceKind.battery,
    _ when text.contains(' solar ') || text.contains(' sun ') =>
      DeviceKind.solar,
    _
        when text.contains(' temperature ') ||
            text.contains(' humidity ') ||
            text.contains(' warm ') ||
            text.contains(' cold ') =>
      DeviceKind.climate,
    _ => null,
  };
  if (kind == null) return null;
  final ds = home.devices.where((d) => d.state?.kind == kind).toList();
  return ds.length == 1 ? ds.single : (ds.isEmpty ? null : ds.first);
}

const _units = {
  'zero': 0,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
};
const _tens = {
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

/// The first number said, in digits or words, with "minus" for below
/// zero: "50", "fifty", "seventy five", "a hundred", "minus 4", "half".
int? _number(List<String> ws) {
  for (var i = 0; i < ws.length; i++) {
    final w = ws[i];
    final neg = i > 0 && (ws[i - 1] == 'minus' || ws[i - 1] == 'negative');
    int sign(int v) => neg ? -v : v;
    final d = int.tryParse(w);
    if (d != null) return sign(d);
    if (w == 'hundred') return 100;
    if (w == 'half') return 50;
    if (_units[w] case final u?) return sign(u);
    if (_tens[w] case final t?) {
      final next = i + 1 < ws.length ? _units[ws[i + 1]] : null;
      return sign(t + (next != null && next < 10 ? next : 0));
    }
  }
  return null;
}
