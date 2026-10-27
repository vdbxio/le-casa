// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

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

class _LightControlsState extends State<LightControls> {
  bool _sending = false;
  double? _dragging;

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
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _value(LightSetting.on) == true;
    final brightness = (_value(LightSetting.brightness) as num? ?? 100)
        .toDouble();
    final rgb = _picked ?? idealLedRgb(_value(LightSetting.colour));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Power'),
          subtitle: Text(
            _sending ? 'Sending…' : 'Shows what Le\'Casa last set',
          ),
          value: on,
          onChanged: _sending ? null : (v) => _send(LightSetting.on, v),
        ),
        Row(
          children: [
            const Icon(Icons.brightness_low),
            Expanded(
              child: Slider(
                min: 1,
                max: 100,
                divisions: 99,
                label: '${(_dragging ?? brightness).round()} %',
                value: _dragging ?? brightness,
                onChanged: _sending
                    ? null
                    : (v) => setState(() => _dragging = v),
                onChangeEnd: _sending
                    ? null
                    : (v) => _send(LightSetting.colour, {
                        'rgb': rgb ?? 0xFFFFFF,
                        'brightness': v.round(),
                      }),
              ),
            ),
            const Icon(Icons.brightness_high),
          ],
        ),
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
                selected: on && rgb == colour,
                onSelected: _sending
                    ? null
                    : (_) {
                        _picked = colour;
                        _send(LightSetting.colour, {
                          'rgb': colour,
                          'brightness': brightness.round(),
                        });
                      },
              ),
          ],
        ),
      ],
    );
  }
}
