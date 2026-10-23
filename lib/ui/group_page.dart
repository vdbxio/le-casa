// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../decoders/decoded.dart';
import 'device_card.dart';

/// All devices of one kind, in the order they were first heard.
class GroupPage extends StatefulWidget {
  final DeviceKind kind;
  const GroupPage({super.key, required this.kind});

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracker = AppServices.of(context).tracker;
    return Scaffold(
      appBar: AppBar(title: Text(widget.kind.label)),
      body: ListenableBuilder(
        listenable: tracker,
        builder: (context, _) {
          final devices = tracker.groups[widget.kind] ?? const [];
          if (devices.isEmpty) {
            return const Center(child: Text('Nothing here right now'));
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final d in devices)
                DeviceCard(key: ValueKey(d.id), device: d),
            ],
          );
        },
      ),
    );
  }
}
