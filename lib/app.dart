// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import 'ble/ble_scanner.dart';
import 'ble/connection_manager.dart';
import 'ble/device_tracker.dart';
import 'decoders/registry.dart';
import 'keys/key_store.dart';
import 'ui/scan_page.dart';

/// Hand-rolled dependency wiring. Small enough that a DI package would be
/// more code than it saves.
class AppServices extends InheritedWidget {
  final BleScanner scanner;
  final KeyStore keys;
  final DeviceTracker tracker;
  final ConnectionManager connections;

  const AppServices({
    super.key,
    required this.scanner,
    required this.keys,
    required this.tracker,
    required this.connections,
    required super.child,
  });

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppServices>()!;

  @override
  bool updateShouldNotify(AppServices oldWidget) => false;
}

class LeCasaApp extends StatefulWidget {
  const LeCasaApp({super.key});

  @override
  State<LeCasaApp> createState() => _LeCasaAppState();
}

class _LeCasaAppState extends State<LeCasaApp> {
  late final KeyStore keys = KeyStore();
  late final DeviceTracker tracker = DeviceTracker(
    DecoderRegistry.standard(keyFor: keys.keyFor),
  );
  late final BleScanner scanner = BleScanner();
  late final ConnectionManager connections = ConnectionManager.forScanner(
    scanner,
    tracker,
  );

  @override
  void initState() {
    super.initState();
    keys.load();
    connections.load();
    keys.addListener(tracker.redecodeAll);
    scanner.advertisements.listen((adv) {
      tracker.onAdvertisement(adv);
      connections.onAdvertisement(adv);
    });
  }

  @override
  void dispose() {
    connections.dispose();
    scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFE0A458),
      brightness: Brightness.dark,
    );
    return AppServices(
      scanner: scanner,
      keys: keys,
      tracker: tracker,
      connections: connections,
      child: MaterialApp(
        title: "Le'Casa",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: scheme,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF14110F),
          cardTheme: const CardThemeData(
            margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
        ),
        home: const ScanPage(),
      ),
    );
  }
}
