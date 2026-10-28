// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../ui/palette.dart';
import 'voice_controller.dart';
import 'voice_tools.dart';

/// The mic beside the settings gear: quiet until it is listening.
class VoiceButton extends StatelessWidget {
  final VoiceController voice;
  const VoiceButton({super.key, required this.voice});

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final p = voice.phase;
        final live = p == VoicePhase.listening || p == VoicePhase.thinking;
        return Opacity(
          opacity: live || p == VoicePhase.loading ? 1 : 0.45,
          child: IconButton(
            tooltip: switch (p) {
              VoicePhase.waiting => 'Listening for "Hey, Gary"',
              VoicePhase.listening => 'Stop listening',
              _ => 'Speak a command',
            },
            onPressed: voice.tap,
            // No spinners: on the M10 one kept the raster thread at 65 %
            // CPU while the engine needed it.
            icon: p == VoicePhase.loading
                ? Icon(Icons.hourglass_top, color: c.muted)
                : Icon(
                    p == VoicePhase.waiting || live
                        ? Icons.mic
                        : Icons.mic_none_outlined,
                    color: live ? c.accent : c.muted,
                  ),
          ),
        );
      },
    );
  }
}

/// What voice heard and did, in a pill at the bottom of the dashboard.
/// Hidden while there is nothing to say.
class VoiceOverlay extends StatelessWidget {
  final VoiceController voice;
  const VoiceOverlay({super.key, required this.voice});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final content = _content(context);
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: content == null
              ? const SizedBox.shrink()
              : _Pill(key: ValueKey(voice.phase), child: content),
        );
      },
    );
  }

  Widget? _content(BuildContext context) {
    final c = LeColors.of(context);
    final big = Theme.of(context).textTheme.titleLarge
        ?.copyWith(fontWeight: FontWeight.w600);
    final small = TextStyle(color: c.muted, fontSize: 15);
    Widget heard(String t) => t.isEmpty
        ? const SizedBox.shrink()
        : Text(
            '“$t”',
            style: small,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          );
    Widget timing() => voice.lastMs == null
        ? const SizedBox.shrink()
        : Text('${voice.lastMs} ms', style: small.copyWith(fontSize: 12));

    switch (voice.phase) {
      case VoicePhase.listening:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Level(level: voice.level, color: c.accent),
            const SizedBox(width: 14),
            Text('Listening…', style: big),
          ],
        );
      case VoicePhase.loading:
        return Text('Getting voice ready…', style: small);
      case VoicePhase.thinking:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_top, color: c.accent),
            const SizedBox(width: 14),
            Text('One moment…', style: big),
          ],
        );
      case VoicePhase.unavailable:
        return null;
      case VoicePhase.showing:
        if (voice.problem case final p?) return Text(p, style: small);
        final o = voice.outcome;
        return switch (o) {
          null => null,
          VoiceAct() => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heard(o.heard),
              const SizedBox(height: 6),
              for (final r in voice.results)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      switch (r.error) {
                        null => Icons.more_horiz,
                        '' => Icons.check_circle,
                        _ => Icons.error_outline,
                      },
                      color: r.error == null || r.error!.isEmpty
                          ? c.accent
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        r.error == null || r.error!.isEmpty
                            ? r.command.summary
                            : '${r.command.summary} · ${r.error}',
                        style: big,
                      ),
                    ),
                  ],
                ),
              timing(),
            ],
          ),
          VoiceConfirm() => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heard(o.heard),
              const SizedBox(height: 6),
              Text('Did you mean', style: small),
              Text(o.commands.map((c) => c.summary).join(', '), style: big),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: voice.confirm,
                    child: const Text('Yes'),
                  ),
                  const SizedBox(width: 10),
                  TextButton(onPressed: voice.dismiss, child: const Text('No')),
                ],
              ),
            ],
          ),
          VoiceAnswer() => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heard(o.heard),
              const SizedBox(height: 6),
              Text(o.answer, style: big),
              timing(),
            ],
          ),
          VoiceNotUnderstood() => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heard(o.heard),
              const SizedBox(height: 6),
              Text(
                o.heard.isEmpty ? 'I didn’t catch that' : 'I can’t do that yet',
                style: big,
              ),
              timing(),
            ],
          ),
        };
      default:
        return null;
    }
  }
}

class _Pill extends StatelessWidget {
  final Widget child;
  const _Pill({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Material(
        color: c.card,
        elevation: 6,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: child,
        ),
      ),
    );
  }
}

/// Three bars that follow the mic level.
class _Level extends StatelessWidget {
  final double level;
  final Color color;
  const _Level({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final k in const [0.6, 1.0, 0.75])
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: 5,
            height: 6 + 20 * (level * k).clamp(0, 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
