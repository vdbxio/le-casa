// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:record/record.dart';

import '../ble/connection_manager.dart';
import '../ble/device_tracker.dart';
import '../settings/settings_store.dart';
import 'asset_files.dart';
import 'phrase_matcher.dart';
import 'speech_gate.dart';
import 'voice_engine.dart';
import 'voice_tools.dart';
import 'wake_word.dart';

enum VoicePhase {
  /// Not started: the models load on first use.
  off,

  /// Loading the models (a few seconds on a slow tablet).
  loading,

  /// Voice cannot run here; [VoiceController.problem] says why.
  unavailable,

  /// Mic open, waiting for "Hey, Gary".
  waiting,

  /// Taking a command.
  listening,

  /// Working on what was said.
  thinking,

  /// Showing what came of it.
  showing,
}

/// One device change voice made, and how it went.
class VoiceResult {
  final VoiceCommand command;

  /// Null while sending, then the error or '' when it worked.
  String? error;
  VoiceResult(this.command);
}

/// Offline voice. "Hey, Gary" is heard by a keyword spotter ([WakeWord])
/// that listens for nothing else; the command after it, or after a tap on
/// the mic, is written down by Whistle and read by [matchPhrase], or by
/// Needle 3 on screens fast enough to run it. The connection manager sends
/// the change. The mic is only open while the app is in front.
class VoiceController extends ChangeNotifier {
  final DeviceTracker tracker;
  final ConnectionManager connections;
  final SettingsStore settings;

  VoiceController({
    required this.tracker,
    required this.connections,
    required this.settings,
  }) {
    settings.addListener(_followSettings);
    _lifecycle = AppLifecycleListener(
      onResume: _followSettings,
      onHide: () => unawaited(_closeMic()),
    );
  }

  late final AppLifecycleListener _lifecycle;
  VoicePhase phase = VoicePhase.off;
  String? problem;
  VoiceOutcome? outcome;
  List<VoiceResult> results = [];

  /// How long the last command took to understand, for judging slow
  /// tablets.
  int? lastMs;

  /// Mic level, 0..1, while listening.
  double get level => _gate.level;

  VoiceEngine? _engine;
  Future<VoiceEngine?>? _starting;
  WakeWord? _wakeWord;
  Future<WakeWord?>? _wakeStarting;
  String? _configured;

  /// Needle 3 takes about 40 s a command on the M10's 32-bit chip, so
  /// 32-bit Android leaves it out, and so does any screen where one call
  /// took too long.
  bool _needle = Abi.current() != Abi.androidArm;

  // A command is a few seconds; a TV behind it should not hold the gate
  // open for long.
  final _gate = SpeechGate(maxFrames: 300);
  AudioRecorder? _mic;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _timeout;
  Timer? _hide;
  DateTime _soundUntil = DateTime(0);
  final _quiet = <Float32List>[];

  /// Listening began at the wake word, and only it has been heard so far.
  var _wakeOnly = false;

  /// A command that ended while the wake word alone was being transcribed.
  Float32List? _held;

  bool get wake => settings.voiceWake;

  bool get _busy => phase == VoicePhase.thinking || phase == VoicePhase.loading;

  void _set(VoicePhase p) {
    phase = p;
    notifyListeners();
  }

  void _followSettings() {
    if (wake && _micSub == null && phase != VoicePhase.unavailable) {
      unawaited(() async {
        final w = await _readyWake();
        if (w != null && await _openMic()) {
          _rest();
          // Load Whistle now, so the first "Hey, Gary" is not kept
          // waiting for it.
          unawaited(_ready());
        }
      }());
    } else if (!wake && phase == VoicePhase.waiting) {
      unawaited(_closeMic());
      _set(VoicePhase.off);
    }
  }

  /// Loads Whistle (and Needle) once; null when voice cannot run here.
  Future<VoiceEngine?> _ready() => _starting ??= () async {
    final was = phase;
    _set(VoicePhase.loading);
    try {
      final e = await VoiceEngine.start(
        _needle ? await voiceFile('assets/voice/needle3.cact') : null,
        await voiceFile('assets/voice/whistle.cact'),
      );
      _engine = e;
      _set(was == VoicePhase.loading ? VoicePhase.off : was);
      return e;
    } on FlutterError {
      return _fail('The voice models are not in this build');
    } on VoiceEngineError catch (e) {
      debugPrint('voice: $e');
      return _fail(
        e.message.contains("Couldn't resolve native function") ||
                e.message.contains('No asset with id')
            ? 'Voice is not built for this device'
            : 'Voice could not start: ${e.message}',
      );
    }
  }();

  /// Starts the wake word spotter once; null when it cannot run here.
  Future<WakeWord?> _readyWake() => _wakeStarting ??= () async {
    try {
      return _wakeWord = await WakeWord.start(_onWake);
    } catch (e) {
      debugPrint('voice: $e');
      problem = '"Hey, Gary" is not available on this device';
      _set(VoicePhase.showing);
      _hideLater();
      return null;
    }
  }();

  /// Why voice cannot run here, once [_ready] has found out.
  String? _whyNot;

  Null _fail(String why) {
    problem = _whyNot = why;
    _set(VoicePhase.unavailable);
    return null;
  }

  Future<bool> _openMic() async {
    if (_micSub != null) return true;
    final mic = _mic ??= AudioRecorder();
    if (!await mic.hasPermission()) {
      problem = 'Le\'Casa needs the microphone for voice';
      _set(VoicePhase.showing);
      _hideLater();
      return false;
    }
    final stream = await mic.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: SpeechGate.rate,
        numChannels: 1,
        // The phone-call cleanup: on iOS, echoCancel turns on Apple's voice
        // processing, which also damps steady noise like a TV across the
        // room; on Android, the system noise suppressor where there is
        // one. No auto gain: the speech gate follows the room's level.
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
    _micSub = stream.listen(_onAudio);
    return true;
  }

  Future<void> _closeMic() async {
    final s = _micSub;
    _micSub = null;
    await s?.cancel();
    await _mic?.stop();
    _gate.flush();
  }

  /// After a command: wait for the wake word, or close the mic.
  void _rest() {
    _timeout?.cancel();
    if (wake && _wakeWord != null) {
      _wakeWord!.reset();
      // A result on screen stays until it times out; the wake word is
      // still heard meanwhile.
      if (phase != VoicePhase.showing) _set(VoicePhase.waiting);
    } else {
      unawaited(_closeMic());
      if (phase != VoicePhase.showing) _set(VoicePhase.off);
    }
  }

  /// The mic button: start a command, or finish one early.
  Future<void> tap() async {
    if (phase == VoicePhase.listening) {
      final u = _gate.flush();
      if (u != null) {
        await _command(u);
      } else {
        _rest();
      }
      return;
    }
    if (_busy) return;
    _hide?.cancel();
    problem = null;
    final e = await _ready();
    if (e == null) {
      problem = _whyNot;
      _set(VoicePhase.showing);
      _hideLater();
      return;
    }
    if (!await _openMic()) return;
    _listen();
  }

  void _onWake() {
    if (_busy || phase == VoicePhase.listening) return;
    debugPrint('voice: "Hey, Gary"');
    unawaited(() async {
      if (await _ready() == null) {
        problem = _whyNot;
        _set(VoicePhase.showing);
        _hideLater();
        return;
      }
      _hide?.cancel();
      problem = null;
      _listen(afterWake: true);
    }());
  }

  void _listen({bool afterWake = false, bool keep = false}) {
    outcome = null;
    results = [];
    _wakeOnly = afterWake;
    _held = null;
    if (afterWake) {
      // "Hey, Gary, turn off the lights" in one breath: the spotter wakes
      // a moment after "Gary", so the command has begun. Keep the last
      // two seconds (the wake word is cut from the transcript); older
      // sound, like the TV, is not the command.
      _gate.keepLast(100);
    } else if (!keep) {
      _gate.flush();
    }
    _set(VoicePhase.listening);
    _timeout?.cancel();
    // Nobody spoke: give up quietly.
    _timeout = Timer(const Duration(seconds: 8), () {
      if (phase == VoicePhase.listening) {
        final u = _gate.flush();
        u == null ? _rest() : unawaited(_command(u));
      }
    });
  }

  void _onAudio(Uint8List bytes) {
    final samples = SpeechGate.fromPcm16(bytes);
    switch (phase) {
      case VoicePhase.listening:
      case VoicePhase.thinking when _wakeOnly:
        notifyListeners();
        final ended = _gate.add(samples);
        if (ended.isEmpty) break;
        if (phase == VoicePhase.thinking) {
          _held = ended.first;
        } else {
          unawaited(_command(ended.first));
        }
      case VoicePhase.waiting || VoicePhase.showing when wake:
        // The spotter only hears the room when there is sound: on the M10
        // it takes most of a core while it decodes.
        _gate.add(samples);
        final now = DateTime.now();
        if (_gate.inSpeech) _soundUntil = now.add(const Duration(seconds: 2));
        if (now.isBefore(_soundUntil)) {
          for (final p in _quiet) {
            _wakeWord?.add(p);
          }
          _quiet.clear();
          _wakeWord?.add(samples);
        } else {
          // Kept so the start of "Hey" is not lost.
          _quiet.add(samples);
          if (_quiet.length > 4) _quiet.removeAt(0);
        }
      default:
    }
  }

  Future<void> _command(Float32List u) async {
    final e = _engine;
    if (e == null || phase == VoicePhase.thinking) return;
    _timeout?.cancel();
    _set(VoicePhase.thinking);
    final watch = Stopwatch()..start();
    try {
      final catalog = _catalog();
      final key = jsonEncode([catalog.tools, catalog.keywords]);
      if (key != _configured) {
        await e.configure(
          system: _dateFact(),
          tools: catalog.tools,
          keywords: catalog.keywords,
        );
        _configured = key;
      }
      final t = await e.transcribe(u);
      final said = '${t['text'] ?? ''}'.trim();
      // "Hey Gary" said again, or its tail caught by the gate.
      final heard = afterWakeWord(said) ?? said;
      debugPrint('voice: heard "$heard" in ${t['ms']} ms');
      if (heard.isEmpty && said.isNotEmpty && _wakeOnly) {
        // Only "Hey, Gary", then a pause: the command comes next, and
        // what was said meanwhile is in the gate.
        final h = _held;
        _listen(keep: true);
        if (h != null) await _command(h);
        return;
      }
      VoiceOutcome o;
      if (heard.isEmpty) {
        o = const VoiceNotUnderstood('');
      } else if (matchPhrase(catalog, heard) case final calls?) {
        o = catalog.interpret({
          'function_calls': calls,
          'confidence': 1.0,
        }, heard: heard);
      } else if (_needle) {
        final r = await e.complete(text: heard);
        debugPrint('voice: ${jsonEncode(r)}');
        if ((r['ms'] as int? ?? 0) > 5000) _needle = false;
        o = catalog.interpret(r, heard: heard);
      } else {
        o = VoiceNotUnderstood(heard);
      }
      lastMs = watch.elapsedMilliseconds;
      outcome = o;
      _set(VoicePhase.showing);
      if (o is VoiceAct) await _run(o.commands);
    } catch (err) {
      debugPrint('voice: $err');
      problem = 'Voice hit a problem: $err';
      _set(VoicePhase.showing);
    }
    _hideLater();
    _rest();
  }

  static String _dateFact() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return 'date: ${n.year}-${two(n.month)}-${two(n.day)} '
        '${days[n.weekday - 1]} ${two(n.hour)}:${two(n.minute)}';
  }

  VoiceCatalog _catalog() => VoiceCatalog([
    for (final d in tracker.devices)
      if (VoiceDevice.kindOf(d.view, controllable: connections.canControl(d.id))
          case final k?)
        VoiceDevice(d.id, d.label ?? d.title, k, d.view),
  ]);

  Future<void> _run(List<VoiceCommand> commands) async {
    results = [for (final c in commands) VoiceResult(c)];
    notifyListeners();
    for (final r in results) {
      try {
        await connections.control(r.command.device.id, r.command.command);
        r.error = '';
      } catch (e) {
        r.error = e is StateError ? e.message : '$e';
      }
      notifyListeners();
    }
  }

  /// "Did you mean…?" answered yes.
  Future<void> confirm() async {
    final o = outcome;
    if (o is! VoiceConfirm) return;
    _hide?.cancel();
    outcome = VoiceAct(o.heard, o.commands);
    _set(VoicePhase.showing);
    await _run(o.commands);
    _hideLater();
  }

  void dismiss() {
    _hide?.cancel();
    outcome = null;
    problem = null;
    results = [];
    if (phase == VoicePhase.showing) {
      _set(wake && _wakeWord != null ? VoicePhase.waiting : VoicePhase.off);
    } else {
      notifyListeners();
    }
  }

  void _hideLater() {
    _hide?.cancel();
    final asks = outcome is VoiceConfirm;
    _hide = Timer(Duration(seconds: asks ? 10 : 6), () {
      if (phase == VoicePhase.showing) dismiss();
    });
  }

  @override
  void dispose() {
    settings.removeListener(_followSettings);
    _lifecycle.dispose();
    _timeout?.cancel();
    _hide?.cancel();
    unawaited(_closeMic().then((_) => _mic?.dispose()));
    _engine?.dispose();
    _wakeWord?.dispose();
    super.dispose();
  }
}
