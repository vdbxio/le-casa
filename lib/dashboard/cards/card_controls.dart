// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../ble/connection_manager.dart';
import '../../drivers/driver.dart';
import '../../ui/palette.dart';
import 'card_model.dart';

/// The row of buttons on a card: a power switch and minus and plus for a
/// number. Every command connects and takes a few seconds, so the row
/// shows the asked-for state at once; taps on the stepper made meanwhile
/// add up and only the last value goes out. A failure puts the device's
/// own state back.
class CardControlsView extends StatefulWidget {
  final CardControls controls;
  final Tone tone;
  const CardControlsView(this.controls, this.tone, {super.key});

  static const height = 44.0;

  @override
  State<CardControlsView> createState() => _CardControlsViewState();
}

class _CardControlsViewState extends State<CardControlsView> {
  int? _want;
  bool? _wantPower;
  bool _sending = false;
  bool _switching = false;

  ConnectionManager? get _connections =>
      context.dependOnInheritedWidgetOfExactType<AppServices>()?.connections;

  CardStepper? get _stepper => widget.controls.stepper;
  int get _shown => _want ?? _stepper!.value;

  void _step(int by) {
    final s = _stepper!;
    final next = (_shown + by).clamp(s.min, s.max);
    if (next == _shown) return;
    HapticFeedback.selectionClick();
    setState(() => _want = next);
    if (!_sending) _sendSteps();
  }

  Future<void> _sendSteps() async {
    final s = _stepper!;
    final connections = _connections;
    if (connections == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      int? sent;
      while (_want != sent) {
        sent = _want;
        await connections.control(
          widget.controls.id,
          DeviceCommand(s.setting, sent!),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not change the ${s.label}: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _want = null;
        });
      }
    }
  }

  Future<void> _togglePower() async {
    final connections = _connections;
    if (connections == null || _switching) return;
    final on = !(widget.controls.power ?? false);
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _switching = true;
      _wantPower = on;
    });
    try {
      await connections.control(widget.controls.id, DeviceCommand('power', on));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not turn it ${on ? 'on' : 'off'}: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _switching = false;
          _wantPower = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final tone = c.tone(widget.tone);
    final power = widget.controls.power;
    final on = _wantPower ?? power;
    final s = _stepper;
    Widget round(IconData icon, VoidCallback? onTap, {bool filled = false}) =>
        IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 20),
          color: filled ? c.card : tone,
          style: IconButton.styleFrom(
            backgroundColor: filled ? tone : tone.withValues(alpha: 0.14),
            minimumSize: const Size.square(CardControlsView.height),
            maximumSize: const Size.square(CardControlsView.height),
            padding: EdgeInsets.zero,
          ),
        );
    return SizedBox(
      height: CardControlsView.height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (power != null) ...[
            _switching
                ? SizedBox.square(
                    dimension: CardControlsView.height,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tone,
                        ),
                      ),
                    ),
                  )
                : round(
                    Icons.power_settings_new,
                    _togglePower,
                    filled: on == true,
                  ),
            if (s != null) const SizedBox(width: 10),
          ],
          if (s != null) ...[
            round(Icons.remove, _shown > s.min ? () => _step(-1) : null),
            SizedBox(
              width: 60,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$_shown${s.unit.isEmpty ? '' : ' ${s.unit}'}',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                  Text(
                    _sending ? 'Sending…' : s.label,
                    maxLines: 1,
                    style: TextStyle(fontSize: 11, color: c.muted),
                  ),
                ],
              ),
            ),
            round(Icons.add, _shown < s.max ? () => _step(1) : null),
          ],
        ],
      ),
    );
  }
}
