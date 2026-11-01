// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ble/connection_manager.dart';
import '../../drivers/driver.dart';
import '../../ui/palette.dart';
import 'card_model.dart';

/// Minus and plus on a card. Every command connects and takes a few
/// seconds, so the number moves at once, taps made meanwhile add up, and
/// only the last value goes out. A failure puts the device's value back.
class CardStepperView extends StatefulWidget {
  final String id;
  final CardStepper stepper;
  final Tone tone;
  final ConnectionManager connections;

  const CardStepperView({
    super.key,
    required this.id,
    required this.stepper,
    required this.tone,
    required this.connections,
  });

  @override
  State<CardStepperView> createState() => _CardStepperViewState();
}

class _CardStepperViewState extends State<CardStepperView> {
  int? _want;
  bool _sending = false;

  int get _shown => _want ?? widget.stepper.value;

  void _step(int by) {
    final s = widget.stepper;
    final next = (_shown + by).clamp(s.min, s.max);
    if (next == _shown) return;
    HapticFeedback.selectionClick();
    setState(() => _want = next);
    if (!_sending) _send();
  }

  Future<void> _send() async {
    final s = widget.stepper;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      int? sent;
      while (_want != sent) {
        sent = _want;
        await widget.connections.control(
          widget.id,
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

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final s = widget.stepper;
    final tone = c.tone(widget.tone);
    Widget button(IconData icon, int by, bool ok) => IconButton(
      onPressed: ok ? () => _step(by) : null,
      icon: Icon(icon, size: 20),
      color: tone,
      style: IconButton.styleFrom(
        backgroundColor: tone.withValues(alpha: 0.14),
        minimumSize: const Size.square(44),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.remove, -1, _shown > s.min),
        SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
        button(Icons.add, 1, _shown < s.max),
      ],
    );
  }
}
