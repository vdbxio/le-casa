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

  /// The colours a person can change in Design, by name.
  static const editable = ['screen', 'card', 'ink', 'muted', 'line', 'accent'];

  Color named(String name) => switch (name) {
    'screen' => screen,
    'card' => card,
    'card2' => card2,
    'ink' => ink,
    'muted' => muted,
    'line' => line,
    'accent' => accent,
    _ => ink,
  };

  /// These colours with some replaced, by [editable] name.
  LeColors withOverrides(Map<String, int> o) {
    if (o.isEmpty) return this;
    Color pick(String n, Color c) => o[n] == null ? c : Color(o[n]!);
    final newCard = pick('card', card);
    return LeColors(
      screen: pick('screen', screen),
      card: newCard,
      // The inset colour follows a changed card colour.
      card2: o['card'] == null
          ? card2
          : Color.lerp(newCard, pick('ink', ink), 0.06)!,
      ink: pick('ink', ink),
      muted: pick('muted', muted),
      line: pick('line', line),
      accent: pick('accent', accent),
      solar: solar,
      solar2: solar2,
      battery: battery,
      climate: climate,
      heat: heat,
      cold: cold,
    );
  }

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

/// The shape of cards and the space around them, set in Design.
@immutable
class CardStyle extends ThemeExtension<CardStyle> {
  /// Corner radius of a card.
  final double radius;

  /// Width of the outline round each card, in the line colour. 0 is none.
  final double border;

  /// Space inside a card, round its content.
  final double padding;

  /// Space between two cards.
  final double gap;

  /// Space between the cards and the screen's edge.
  final double edge;

  /// Size of a card's title.
  final double titleSize;

  const CardStyle({
    this.radius = 20,
    this.border = 0,
    this.padding = 16,
    this.gap = 12,
    this.edge = 14,
    this.titleSize = 15,
  });

  static const standard = CardStyle();

  static CardStyle of(BuildContext context) =>
      Theme.of(context).extension<CardStyle>() ?? standard;

  BorderRadius get borderRadius => BorderRadius.circular(radius);

  /// How much more padding than the standard 16 cards have; cards fit
  /// their content to the space left inside.
  double get extraPadding => padding - standard.padding;

  /// A card's background, with its outline if there is one.
  BoxDecoration decoration(LeColors c, {BorderRadius? radius}) => BoxDecoration(
    color: c.card,
    borderRadius: radius ?? borderRadius,
    border: border <= 0 ? null : Border.all(color: c.line, width: border),
  );

  @override
  CardStyle copyWith({
    double? radius,
    double? border,
    double? padding,
    double? gap,
    double? edge,
    double? titleSize,
  }) => CardStyle(
    radius: radius ?? this.radius,
    border: border ?? this.border,
    padding: padding ?? this.padding,
    gap: gap ?? this.gap,
    edge: edge ?? this.edge,
    titleSize: titleSize ?? this.titleSize,
  );

  @override
  CardStyle lerp(CardStyle? other, double t) {
    if (other == null) return this;
    double l(double a, double b) => a + (b - a) * t;
    return CardStyle(
      radius: l(radius, other.radius),
      border: l(border, other.border),
      padding: l(padding, other.padding),
      gap: l(gap, other.gap),
      edge: l(edge, other.edge),
      titleSize: l(titleSize, other.titleSize),
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

ThemeData leCasaTheme(
  Brightness b, {
  Map<String, int> colors = const {},
  CardStyle style = CardStyle.standard,
}) {
  final c = (b == Brightness.dark ? LeColors.dark : LeColors.light)
      .withOverrides(colors);
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: b,
    surface: c.screen,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: c.screen,
    extensions: [c, style],
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
