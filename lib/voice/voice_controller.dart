// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:record/record.dart';

import '../ble/connection_manager.dart';
import '../ble/device_tracker.dart';
import '../settings/settings_store.dart';
import 'speech_gate.dart';
import 'voice_engine.dart';
import 'voice_tools.dart';

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

  /// The engine is working on what was said.
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

/// Offline voice: Whistle hears, Needle picks the device command, the
/// connection manager sends it. The mic opens when the person taps it or
/// turns on "Hey, Gary" in Settings, and only while the app is in front.
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

  /// How long the engine took on the last thing said, for judging slow
  /// tablets.
  int? lastMs;

  /// Mic level, 0..1, while listening.
  double get level => _gate.level;

  VoiceEngine? _engine;
  Future<VoiceEngine?>? _starting;
  String? _configured;
  final _gate = SpeechGate();
  AudioRecorder? _mic;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _timeout;
  Timer? _hide;

  bool get wake => settings.voiceWake;

  bool get _busy => phase == VoicePhase.thinking || phase == VoicePhase.loading;

  void _set(VoicePhase p) {
    phase = p;
    notifyListeners();
  }

  void _followSettings() {
    if (wake && _micSub == null && phase != VoicePhase.unavailable) {
      unawaited(
        _ready().then((e) async {
          if (e != null && await _openMic()) _rest();
        }),
      );
    } else if (!wake && phase == VoicePhase.waiting) {
      unawaited(_closeMic());
      _set(VoicePhase.off);
    }
  }

  /// Loads the engine once; null when voice cannot run here.
  Future<VoiceEngine?> _ready() => _starting ??= () async {
    _set(VoicePhase.loading);
    try {
      final needle = await rootBundle.load('assets/voice/needle3.cact');
      final whistle = await rootBundle.load('assets/voice/whistle.cact');
      final e = await VoiceEngine.start(
        needle.buffer.asUint8List(needle.offsetInBytes, needle.lengthInBytes),
        whistle.buffer.asUint8List(
          whistle.offsetInBytes,
          whistle.lengthInBytes,
        ),
      );
      _engine = e;
      _set(VoicePhase.off);
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
    if (wake) {
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

  void _listen() {
    outcome = null;
    results = [];
    _set(VoicePhase.listening);
    _timeout?.cancel();
    // Nobody spoke: give up quietly.
    _timeout = Timer(const Duration(seconds: 8), () {
      if (phase == VoicePhase.listening && !_gate.inSpeech) _rest();
    });
  }

  void _onAudio(Uint8List bytes) {
    final ended = _gate.add(SpeechGate.fromPcm16(bytes));
    if (phase == VoicePhase.listening) notifyListeners();
    for (final u in ended) {
      switch (phase) {
        case VoicePhase.listening:
          unawaited(_command(u));
        case VoicePhase.waiting || VoicePhase.showing when wake:
          unawaited(_maybeWake(u));
        default:
      }
    }
  }

  Future<void> _maybeWake(Float32List u) async {
    final e = _engine;
    if (e == null || _busy) return;
    // Only the first seconds matter for the wake word; a long chat is
    // not transcribed whole on the off chance.
    final head = u.length > 6 * SpeechGate.rate
        ? Float32List.sublistView(u, 0, 6 * SpeechGate.rate)
        : u;
    final t = await e.transcribe(head);
    final heard = '${t['text'] ?? ''}';
    final rest = afterWakeWord(heard);
    debugPrint('voice: heard "$heard" in ${t['ms']} ms');
    if (rest == null) return;
    _hide?.cancel();
    if (rest.isEmpty) return _listen();
    // The command came in the same breath: answer the words, unless the
    // utterance ran past what was transcribed.
    await _command(u, text: head.length == u.length ? rest : null);
  }

  Future<void> _command(Float32List u, {String? text}) async {
    final e = _engine;
    if (e == null) return;
    _timeout?.cancel();
    _set(VoicePhase.thinking);
    try {
      final catalog = _catalog();
      final tools = catalog.tools;
      final key = jsonEncode([tools, catalog.keywords]);
      if (key != _configured) {
        await e.configure(
          system: _dateFact(),
          tools: tools,
          keywords: catalog.keywords,
        );
        _configured = key;
      }
      final r = text != null
          ? await e.complete(text: text)
          : await e.complete(pcm: u);
      lastMs = r['ms'] as int?;
      debugPrint('voice: ${jsonEncode(r)}');
      var o = catalog.interpret(r, heard: text);
      // "Hey Gary, lights off" heard as one: drop the wake word.
      if (text == null && o.heard.isNotEmpty) {
        final rest = afterWakeWord(o.heard);
        if (rest != null && rest.isNotEmpty && o is VoiceNotUnderstood) {
          o = catalog.interpret(await e.complete(text: rest), heard: rest);
        }
      }
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
      wake ? _set(VoicePhase.waiting) : _set(VoicePhase.off);
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
    super.dispose();
  }
}
