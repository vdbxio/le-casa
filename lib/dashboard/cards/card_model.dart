// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../../ui/palette.dart';

/// One labelled value: "Voltage 26.62 V".
class Metric {
  final String label;
  final String value;
  final String unit;

  /// How to say it in a one-line summary when the unit alone is not clear
  /// ("46% humidity" rather than "46 %").
  final String? phrase;

  /// Left out of one-line summaries (sensor battery and the like).
  final bool minor;

  const Metric(
    this.label,
    this.value, [
    this.unit = '',
    this.phrase,
    this.minor = false,
  ]);

  String get inline => unit.isEmpty ? value : '$value $unit';

  String get summary => phrase ?? inline;
}

/// One part of a total, e.g. one charger's watts in the combined solar card.
class Share {
  final String name;
  final double amount;
  final String value;
  final List<String> extra;
  const Share(this.name, this.amount, this.value, [this.extra = const []]);
}

/// One column of the weather card's hourly strip.
class HourCell {
  final String label;
  final IconData icon;
  final String value;
  const HourCell(this.label, this.icon, this.value);
}

/// Everything a card shows, independent of size. One renderer draws every
/// card from this at any of the four sizes, so a new device only needs a
/// builder, never a new widget. This is the seed of the card design system.
class CardModel {
  final String title;
  final String subtitle;
  final IconData icon;
  final Tone tone;

  /// The one number that matters, shown big at every size.
  final Metric? headline;

  /// A short state shown as a chip: "Bulk", "Charging".
  final String? state;

  /// Secondary readings, most important first. Sizes show as many as fit.
  final List<Metric> details;

  /// Parts of the headline (combined solar).
  final List<Share> shares;

  /// 0..100, drawn as a ring on wide large/medium cards (state of charge).
  final double? ring;

  /// Recent history of the headline for the sparkline.
  final List<double>? series;

  /// Forecast strip (weather).
  final List<HourCell> hours;

  /// A sentence instead of data: needs setup, no internet...
  final String? note;

  /// Not heard from for a while: drawn faded with [note] saying so.
  final bool stale;

  /// The short label next to the number on a pill.
  final String pillLabel;

  const CardModel({
    required this.title,
    this.subtitle = '',
    required this.icon,
    this.tone = Tone.neutral,
    this.headline,
    this.state,
    this.details = const [],
    this.shares = const [],
    this.ring,
    this.series,
    this.hours = const [],
    this.note,
    this.stale = false,
    String? pillLabel,
  }) : pillLabel = pillLabel ?? title;
}
