// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

/// The bold face for numbers and headings.
const displayFont = 'LeagueSpartan';

/// What a card is about, which picks its colour.
enum Tone { solar, battery, climate, heat, cold, accent, neutral }

/// Dashboard colours for one brightness. Semantic colours (solar, battery,
/// ...) are separate from the accent, which is reserved for edit tools.
@immutable
class LeColors extends ThemeExtension<LeColors> {
  final Color screen, card, card2, ink, muted, line, accent;
  final Color solar, solar2, battery, climate, heat, cold;

  const LeColors({
    required this.screen,
    required this.card,
    required this.card2,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
    required this.solar,
    required this.solar2,
    required this.battery,
    required this.climate,
    required this.heat,
    required this.cold,
  });

  static const light = LeColors(
    screen: Color(0xFFF2F5F2),
    card: Color(0xFFFFFFFF),
    card2: Color(0xFFEDF1EE),
    ink: Color(0xFF16201B),
    muted: Color(0xFF5A6962),
    line: Color(0xFFC6CFC9),
    accent: Color(0xFF3A50D9),
    solar: Color(0xFFB87D00),
    solar2: Color(0xFFE0B13D),
    battery: Color(0xFF188A55),
    climate: Color(0xFF2678A8),
    heat: Color(0xFFCC5023),
    cold: Color(0xFF2F93BE),
  );

  static const dark = LeColors(
    screen: Color(0xFF090D0B),
    card: Color(0xFF151C19),
    card2: Color(0xFF1D2622),
    ink: Color(0xFFE4EBE6),
    muted: Color(0xFF91A198),
    line: Color(0xFF2A3430),
    accent: Color(0xFF8F9EFF),
    solar: Color(0xFFF0B534),
    solar2: Color(0xFF9C7418),
    battery: Color(0xFF3ECF88),
    climate: Color(0xFF5DB7EA),
    heat: Color(0xFFFF7B47),
    cold: Color(0xFF6CC8EF),
  );

  static LeColors of(BuildContext context) =>
      Theme.of(context).extension<LeColors>() ?? dark;

  Color tone(Tone t) => switch (t) {
    Tone.solar => solar,
    Tone.battery => battery,
    Tone.climate => climate,
    Tone.heat => heat,
    Tone.cold => cold,
    Tone.accent => accent,
    Tone.neutral => muted,
  };

  @override
  LeColors copyWith() => this;

  @override
  LeColors lerp(LeColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return LeColors(
      screen: l(screen, other.screen),
      card: l(card, other.card),
      card2: l(card2, other.card2),
      ink: l(ink, other.ink),
      muted: l(muted, other.muted),
      line: l(line, other.line),
      accent: l(accent, other.accent),
      solar: l(solar, other.solar),
      solar2: l(solar2, other.solar2),
      battery: l(battery, other.battery),
      climate: l(climate, other.climate),
      heat: l(heat, other.heat),
      cold: l(cold, other.cold),
    );
  }
}

/// Big numbers: League Spartan semibold with tabular figures, so values
/// do not jitter sideways as they change.
TextStyle numberStyle(double size, Color color) => TextStyle(
  fontFamily: displayFont,
  fontWeight: FontWeight.w600,
  fontVariations: const [FontVariation.weight(600)],
  fontSize: size,
  height: 1,
  color: color,
  fontFeatures: const [FontFeature.tabularFigures()],
);

ThemeData leCasaTheme(Brightness b) {
  final c = b == Brightness.dark ? LeColors.dark : LeColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: b,
    surface: c.screen,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: c.screen,
    extensions: [c],
    cardTheme: const CardThemeData(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFamily: displayFont,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontFamily: displayFont,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
