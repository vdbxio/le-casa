// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

/// What a button remote did over the last day, and whether it is home.
///
/// A Le'Fob sends a short burst of identical adverts for every button
/// press, and a "chirp" (a status burst with no button in it) on a timer
/// between presses. Chirps say "I'm still here": once they stop for much
/// longer than the fob's usual gap, the fob has left. The gap is learnt
/// from the chirps themselves, so a fob on a 60 s chirp, one on 5 min, and
/// a future one that stretches its gap when idle all work without a
/// setting.
library;

import 'dart:math' as math;

/// One burst heard from a remote: a press, or a chirp.
class Burst {
  final DateTime at;
  final bool press;
  const Burst(this.at, this.press);
}

/// One button event: [button] counts from 1.
class Press {
  final DateTime at;
  final int button;

  /// The BTHome event name: press, double_press, long_press, hold_press...
  final String kind;
  const Press(this.at, this.button, this.kind);
}

/// A span of time, [from] up to [to].
class Span {
  final DateTime from;
  final DateTime to;
  const Span(this.from, this.to);

  Duration get length => to.difference(from);

  /// How much of this span lies inside [other].
  Duration overlap(Span other) {
    final a = from.isAfter(other.from) ? from : other.from;
    final b = to.isBefore(other.to) ? to : other.to;
    return b.isAfter(a) ? b.difference(a) : Duration.zero;
  }

  @override
  String toString() => 'Span($from, $to)';
}

/// Where a remote is now, and when it was away.
class Presence {
  /// True home, false away, null while the screen has not listened for
  /// long enough to tell (just started, and the fob was last heard before).
  final bool? home;

  /// The gap between chirps this fob keeps, as learnt.
  final Duration interval;

  /// How long a silence it takes to call the fob away.
  final Duration timeout;

  /// When it was last heard.
  final DateTime? lastHeard;

  /// When it last arrived or left, if seen.
  final DateTime? since;

  /// Times it was away, oldest first.
  final List<Span> away;

  /// Whether [interval] came from the fob's own chirps rather than the
  /// default.
  final bool learnt;

  const Presence({
    required this.home,
    required this.interval,
    required this.timeout,
    required this.lastHeard,
    required this.since,
    required this.away,
    required this.learnt,
  });
}

/// The chirp gap assumed before any has been seen: Le'Fob's default.
const defaultChirp = Duration(minutes: 5);

/// How many missed chirps it takes to call a fob away. A tablet's scanner
/// misses the odd burst; 2.5 gaps rides out one missed chirp without
/// flapping, and calls a fob away about two and a half chirps after it
/// left.
const missedChirps = 2.5;

/// The silence that means away, for a fob that chirps every [interval].
Duration presenceTimeout(Duration interval) {
  final t = interval * missedChirps;
  // A fast chirper still gets a minute and a half of slack.
  final least = interval + const Duration(seconds: 90);
  return t > least ? t : least;
}

/// Works out home and away from what was heard.
///
/// [bursts] oldest first. [listening] are the times this screen was
/// running and scanning, oldest first: a silence while the app was closed
/// says nothing, and after a start the screen waits one timeout before it
/// calls a fob away.
///
/// The gap is the longest of the last few chirp-to-chirp gaps, so a fob
/// that slows down is not called away on its first longer gap as long as
/// the longer gap is within [missedChirps] of the last one. Gaps that
/// were themselves an absence are not learnt from.
Presence presenceOf(
  List<Burst> bursts,
  List<Span> listening,
  DateTime now, {
  Duration fallback = defaultChirp,
}) {
  const window = 6;
  final gaps = <Duration>[];
  Duration interval() => gaps.isEmpty ? fallback : gaps.reduce(_max);

  final away = <Span>[];
  DateTime? lastChirp;
  DateTime? last;
  DateTime? since;

  void silence(DateTime a, DateTime b) {
    final t = presenceTimeout(interval());
    for (final l in listening) {
      if (!l.to.isAfter(a) || !l.from.isBefore(b)) continue;
      // Listening since before the last burst: the clock runs from it.
      // Started listening after it: wait a full timeout from the start.
      final from = (l.from.isAfter(a) ? l.from : a).add(t);
      final to = l.to.isBefore(b) ? l.to : b;
      if (from.isBefore(to)) away.add(Span(from, to));
    }
  }

  for (final b in bursts) {
    if (last != null) {
      final before = away.length;
      silence(last, b.at);
      if (away.length > before) since = b.at; // came back
    }
    if (!b.press) {
      if (lastChirp != null) {
        final g = b.at.difference(lastChirp);
        // An absence, or the app closed, is not a chirp gap.
        if (g <= presenceTimeout(interval()) &&
            g > const Duration(seconds: 5)) {
          gaps.add(g);
          if (gaps.length > window) gaps.removeAt(0);
        }
      }
      lastChirp = b.at;
    }
    last = b.at;
  }

  bool? home;
  if (last == null) {
    home = null;
  } else {
    final before = away.length;
    silence(last, now);
    if (away.length > before && !away.last.to.isBefore(now)) {
      home = false;
      since = away.last.from;
    } else {
      // Not heard since the screen started, and not yet a timeout in.
      final current = listening.isEmpty ? null : listening.last.from;
      final heardThisRun = current == null || !last.isBefore(current);
      home = heardThisRun ? true : null;
    }
  }
  return Presence(
    home: home,
    interval: interval(),
    timeout: presenceTimeout(interval()),
    lastHeard: last,
    since: since,
    away: away,
    learnt: gaps.isNotEmpty,
  );
}

Duration _max(Duration a, Duration b) => a > b ? a : b;

/// The last day of one remote: its bursts and presses.
class FobLog {
  static const keep = Duration(hours: 24);

  final List<Burst> bursts = [];
  final List<Press> presses = [];

  void trim(DateTime now) {
    final cut = now.subtract(keep);
    bursts.removeWhere((b) => b.at.isBefore(cut));
    presses.removeWhere((p) => p.at.isBefore(cut));
    // A busy day of presses is still small, but bound it.
    if (presses.length > 2000) presses.removeRange(0, presses.length - 2000);
    if (bursts.length > 4000) bursts.removeRange(0, bursts.length - 4000);
  }

  Map<String, Object?> toJson() => {
    'b': [
      for (final b in bursts)
        [b.at.millisecondsSinceEpoch ~/ 1000, b.press ? 1 : 0],
    ],
    'p': [
      for (final p in presses)
        [p.at.millisecondsSinceEpoch ~/ 1000, p.button, p.kind],
    ],
  };

  static FobLog fromJson(Map<String, Object?> j) {
    DateTime t(Object? s) =>
        DateTime.fromMillisecondsSinceEpoch((s as num).toInt() * 1000);
    final l = FobLog();
    for (final b in (j['b'] as List? ?? const [])) {
      final x = b as List;
      l.bursts.add(Burst(t(x[0]), x[1] == 1));
    }
    for (final p in (j['p'] as List? ?? const [])) {
      final x = p as List;
      l.presses.add(Press(t(x[0]), (x[1] as num).toInt(), x[2] as String));
    }
    return l;
  }
}

/// Spans of listening, merged where they touch, last day only.
List<Span> mergeSpans(List<Span> spans, DateTime now) {
  final cut = now.subtract(FobLog.keep);
  final sorted = [
    for (final s in spans)
      if (s.to.isAfter(cut)) s,
  ]..sort((a, b) => a.from.compareTo(b.from));
  final out = <Span>[];
  for (final s in sorted) {
    if (out.isNotEmpty && !s.from.isAfter(out.last.to)) {
      final l = out.removeLast();
      out.add(Span(l.from, s.to.isAfter(l.to) ? s.to : l.to));
    } else {
      out.add(s);
    }
  }
  return out;
}

/// Index of a button label "button 3" → 3, or null.
int? buttonNumber(String label) {
  final m = RegExp(r'^button (\d+)$').firstMatch(label);
  return m == null ? null : int.parse(m.group(1)!);
}

/// The number of tracks to draw: four for a Le'Fob, else as many buttons
/// as have been pressed (at least one).
int trackCount(List<Press> presses, {int least = 1}) =>
    presses.fold(least, (n, p) => math.max(n, p.button)).clamp(1, 8);
