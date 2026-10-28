// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

/// "Hey, Gary" as another screen of the home heard it.
class PeerWake {
  /// The screen's short id, as its advert carries it.
  final String screen;

  /// How far the wake word rose over that screen's background, in dB.
  final int level;
  final DateTime seen;

  const PeerWake(this.screen, this.level, this.seen);
}

/// Lets the screens of a home settle who answers a "Hey, Gary" they all
/// heard, through the adverts they already send each other. Screen sync
/// provides it.
abstract interface class WakeShare {
  /// This screen's short id.
  String get screen;

  /// Tells the other screens this one heard the wake word [level] dB over
  /// its background.
  void announceWake(int level);

  Stream<PeerWake> get wakes;
}

/// Whether a screen that heard the wake word at [at], [level] dB over its
/// background, should leave the command to another screen. The one that
/// heard it most clearly over its own background answers, so a tablet by
/// the TV does not win for being in the noise; a tie goes to the higher
/// screen id, so exactly one answers.
PeerWake? answeredBy(
  String screen,
  int level,
  DateTime at,
  Iterable<PeerWake> peers, {
  Duration window = const Duration(seconds: 2),
}) {
  PeerWake? best;
  for (final p in peers) {
    if (p.screen == screen) continue;
    if (p.seen.difference(at).abs() > window) continue;
    final wins =
        p.level > level || (p.level == level && p.screen.compareTo(screen) > 0);
    if (!wins) continue;
    if (best == null || p.level > best.level) best = p;
  }
  return best;
}
