// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/connection_manager.dart';
import '../decoders/decoded.dart';
import '../drivers/driver.dart';
import '../drivers/ideal_led.dart';

/// Power, brightness and a few colours for an LED strip controller. The
/// controller cannot be asked what it is showing, so this starts from what
/// Le'Casa last set it to, from any screen.
class LightControls extends StatefulWidget {
  final String id;
  final Decoded state;
  final ConnectionManager connections;

  const LightControls({
    super.key,
    required this.id,
    required this.state,
    required this.connections,
  });

  @override
  State<LightControls> createState() => _LightControlsState();
}

const _colours = <(String, int)>[
  ('Warm', 0xFF8C3C),
  ('White', 0xFFFFFF),
  ('Red', 0xFF0000),
  ('Orange', 0xFF6000),
  ('Green', 0x00FF00),
  ('Blue', 0x0000FF),
  ('Purple', 0x8000FF),
];

class _LightControlsState extends State<LightControls>
    with WidgetsBindingObserver {
  // The page connects as it opens so that changes go out at once; the
  // strip blinks three times as it does.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.connections.warm(widget.id));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.connections.warm(widget.id));
    } else if (state == AppLifecycleState.paused) {
      widget.connections.cool(widget.id);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.connections.cool(widget.id);
    super.dispose();
  }

  bool _sending = false;
  double? _dragging;
  double? _speedDrag;

  /// The colour picked here, kept while the page is open so a command that
  /// fails does not lose it.
  int? _picked;

  Object? _value(String label) =>
      widget.state.readings.where((r) => r.label == label).firstOrNull?.value;

  Future<void> _send(String setting, Object value) async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.connections.control(
        widget.id,
        DeviceCommand(setting, value),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('The light did not change: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _dragging = null;
          _speedDrag = null;
        });
      }
    }
  }

  /// The pattern picked here, kept like [_picked].
  String? _pickedPattern;

  /// Sends the whole look again with one part changed: brightness and
  /// speed have no command of their own.
  void _apply({
    required IdealPattern? pattern,
    required int? rgb,
    required int brightness,
    required int speed,
  }) {
    if (pattern != null) {
      _send(LightSetting.pattern, {
        'pattern': pattern.name,
        'rgb': rgb ?? 0xFFFFFF,
        'speed': speed,
        'brightness': brightness,
      });
    } else if (rgb != null) {
      _send(LightSetting.colour, {'rgb': rgb, 'brightness': brightness});
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _value(LightSetting.on) == true;
    final brightness = (_value(LightSetting.brightness) as num? ?? 100)
        .toDouble();
    final speed = (_value(LightSetting.speed) as num? ?? 80).toDouble();
    final rgb = _picked ?? idealLedRgb(_value(LightSetting.colour));
    final patternName = _pickedPattern ?? _value(LightSetting.pattern);
    final pattern = idealPatternNamed(patternName);
    // Brightness and speed re-send a look Le'Casa set; with none known,
    // guessing would replace a pattern from the remote with a solid colour.
    final known = pattern != null || rgb != null;
    final theme = Theme.of(context);
    void apply({IdealPattern? p, int? colour, double? b, double? sp}) => _apply(
      pattern: p ?? pattern,
      rgb: colour ?? rgb,
      brightness: (b ?? brightness).round(),
      speed: (sp ?? speed).round(),
    );
    Widget slider({
      required IconData low,
      required IconData high,
      required double value,
      required void Function(double) onEnd,
    }) => Row(
      children: [
        Icon(low),
        Expanded(
          child: Slider(
            min: 1,
            max: 100,
            divisions: 99,
            label: '${value.round()} %',
            value: value,
            onChanged: _sending || !known
                ? null
                : (v) => setState(() => _dragging = v),
            onChangeEnd: _sending || !known ? null : onEnd,
          ),
        ),
        Icon(high),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Power'),
          subtitle: ListenableBuilder(
            listenable: widget.connections,
            builder: (context, _) {
              final link = widget.connections.isLinked(widget.id)
                  ? 'connected'
                  : widget.connections.isWarming(widget.id)
                  ? 'connecting…'
                  : 'connects on change';
              return Text(
                _sending
                    ? 'Sending…'
                    : '${patternName ?? 'Nothing set yet'} · as Le\'Casa last '
                          'set it · $link',
              );
            },
          ),
          value: on,
          onChanged: _sending ? null : (v) => _send(LightSetting.on, v),
        ),
        Text('Brightness', style: theme.textTheme.labelLarge),
        slider(
          low: Icons.brightness_low,
          high: Icons.brightness_high,
          value: _dragging ?? brightness,
          onEnd: (v) => apply(b: v),
        ),
        if (pattern != null) ...[
          Text('Speed', style: theme.textTheme.labelLarge),
          Row(
            children: [
              const Icon(Icons.slow_motion_video),
              Expanded(
                child: Slider(
                  min: 0,
                  max: 100,
                  divisions: 100,
                  label: '${(_speedDrag ?? speed).round()} %',
                  value: _speedDrag ?? speed,
                  onChanged: _sending
                      ? null
                      : (v) => setState(() => _speedDrag = v),
                  onChangeEnd: _sending ? null : (v) => apply(sp: v),
                ),
              ),
              const Icon(Icons.speed),
            ],
          ),
        ],
        if (!known)
          Text(
            'Pick a colour or pattern first. The strip cannot say what it is '
            'showing, so a pattern from its remote or app is left alone.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
        Text(
          pattern?.effect != null ? 'Effect colour' : 'Colour',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (name, colour) in _colours)
              ChoiceChip(
                avatar: CircleAvatar(
                  backgroundColor: Color(0xFF000000 | colour),
                ),
                label: Text(name),
                selected:
                    rgb == colour &&
                    (pattern == null || pattern.effect != null),
                onSelected: _sending
                    ? null
                    : (_) {
                        _picked = colour;
                        // A colour recolours an effect; over a rainbow scene
                        // it means "just this colour".
                        if (pattern?.effect == null) {
                          _pickedPattern = idealSolid;
                        }
                        _apply(
                          pattern: pattern?.effect != null ? pattern : null,
                          rgb: colour,
                          brightness: brightness.round(),
                          speed: speed.round(),
                        );
                      },
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Patterns', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in idealPatterns)
              ChoiceChip(
                avatar: p.scene != null
                    ? _Swatch(p.colours)
                    : _Swatch([rgb ?? 0xFFFFFF, 0]),
                label: Text(p.name),
                selected: pattern == p,
                onSelected: _sending
                    ? null
                    : (_) {
                        _pickedPattern = p.name;
                        apply(p: p);
                      },
              ),
          ],
        ),
      ],
    );
  }
}

/// A pattern's colours as a small round gradient.
class _Swatch extends StatelessWidget {
  final List<int> colours;
  const _Swatch(this.colours);

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: SweepGradient(
        colors: [
          for (final c in [...colours, colours.first]) Color(0xFF000000 | c),
        ],
      ),
    ),
  );
}
