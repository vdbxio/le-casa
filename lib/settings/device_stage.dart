// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Split;

import '../app.dart';
import '../ble/device_tracker.dart';
import '../dashboard/catalog.dart';
import '../dashboard/dashboard_page.dart' show cardContent;
import '../dashboard/layout.dart';
import '../decoders/decoded.dart';
import '../ui/format.dart';
import '../ui/palette.dart';
import 'sidebar.dart';

/// A device's card, large, on the dimmed dashboard beside its settings
/// page, with every reading it has under it and a button to put it on
/// the dashboard.
class DeviceStage extends StatelessWidget {
  final String id;
  const DeviceStage({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.liveData, s.dashboard]),
      builder: (context, _) {
        final d = s.tracker.find(id);
        final v = d?.view;
        if (d == null || v == null) {
          return const _Message(
            'Nothing to put on a card yet: Le\'Casa does not know how to '
            'read this device.',
          );
        }
        if (v.kind == DeviceKind.background || v.kind == DeviceKind.improv) {
          return const _Message(
            'This one only says it is there. There is nothing on it to show.',
          );
        }
        return _Staged(device: d, view: v);
      },
    );
  }
}

class _Staged extends StatelessWidget {
  final TrackedDevice device;
  final Decoded view;
  const _Staged({required this.device, required this.view});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final c = LeColors.of(context);
    final look = CardStyle.of(context);
    final dash = s.dashboard;
    final sources = CardSources(
      tracker: s.tracker,
      history: s.history,
      tablet: s.tablet,
      weather: s.weather,
      heardBefore: (id) => dash.heard[id],
    );
    final fresh = CardSpec.device(device.id, name: deviceName(device));
    // The card as it is on the dashboard (its own layout and title), if
    // it is there.
    final placed = !dash.hasLayout
        ? null
        : dash.page.slots
              .map((e) => e.$2.card)
              .where((card) => card?.key == fresh.key)
              .firstOrNull;
    final inChips =
        placed == null &&
        dash.hasLayout &&
        dash.page.cardKeys.contains(fresh.key);
    final spec = placed ?? fresh;
    final onDash = placed != null || inChips;
    final readings = [
      for (final r in view.readings)
        if (r.value != null) r,
    ];
    final a = device.latest;

    return LayoutBuilder(
      builder: (context, box) {
        final w = math.min(box.maxWidth - 48, 600.0);
        final h = math.min(w * 0.62, math.max(220.0, box.maxHeight * 0.45));
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: SizedBox(
              width: w,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // What it is, above the card.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Tag(view.model),
                      if (view.protocol != view.model) _Tag(view.protocol),
                      _Tag('${a.rssi} dBm'),
                      _Tag('Seen ${ago(device.lastSeen)}'),
                      if (onDash) _Tag('On the dashboard', strong: true),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: h,
                    child: cardContent(
                      spec,
                      Size(w, h),
                      sources,
                      extraPadding: look.extraPadding,
                    ).$1,
                  ),
                  if (readings.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DecoratedBox(
                      decoration: look.decoration(c),
                      child: Padding(
                        padding: EdgeInsets.all(look.padding + 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Everything it reports',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: look.titleSize,
                                color: c.ink,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 18,
                              runSpacing: 14,
                              children: [for (final r in readings) _Reading(r)],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: c.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 16,
                          ),
                        ),
                        onPressed: dash.hasLayout
                            ? () {
                                closeSettings(context);
                                dash.startPlacing(spec);
                              }
                            : null,
                        icon: Icon(onDash ? Icons.open_with : Icons.add),
                        label: Text(
                          onDash ? 'Move on the dashboard' : 'Add to dashboard',
                        ),
                      ),
                      if (onDash)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                          ),
                          onPressed: () {
                            dash.page.take(spec.key);
                            dash.changed();
                          },
                          icon: const Icon(Icons.remove_circle_outline),
                          label: const Text('Take off the dashboard'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Reading extends StatelessWidget {
  final Reading r;
  const _Reading(this.r);

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final v = r.value;
    final value = switch (v) {
      bool b => b ? 'On' : 'Off',
      _ => r.display.replaceAll(' ${r.unit}', '').trim(),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            r.label[0].toUpperCase() + r.label.substring(1),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: value, style: numberStyle(22, c.ink)),
                if (r.unit.isNotEmpty && v is! bool)
                  TextSpan(
                    text: ' ${r.unit}',
                    style: TextStyle(fontSize: 13, color: c.muted),
                  ),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final bool strong;
  const _Tag(this.text, {this.strong = false});

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: strong ? c.accent : Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 18),
      ),
    ),
  );
}
