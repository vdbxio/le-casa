// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/material.dart';

import 'ble/ble_scanner.dart';
import 'ble/connection_manager.dart';
import 'ble/device_tracker.dart';
import 'ble/scan_autostart.dart';
import 'dashboard/dashboard_controller.dart';
import 'dashboard/dashboard_page.dart';
import 'dashboard/history.dart';
import 'decoders/registry.dart';
import 'keys/key_store.dart';
import 'platform/tablet.dart';
import 'settings/dimmer.dart';
import 'settings/settings_store.dart';
import 'ui/palette.dart';
import 'weather/weather.dart';

/// Hand-rolled dependency wiring. Small enough that a DI package would be
/// more code than it saves.
class AppServices extends InheritedWidget {
  final BleScanner scanner;
  final ScanAutostart autostart;
  final KeyStore keys;
  final DeviceTracker tracker;
  final ConnectionManager connections;
  final DashboardController dashboard;
  final History history;
  final TabletSensors tablet;
  final SettingsStore settings;
  final WeatherService weather;

  /// Fires when anything a card shows has changed, at most once a second.
  final Listenable liveData;

  const AppServices({
    super.key,
    required this.scanner,
    required this.autostart,
    required this.keys,
    required this.tracker,
    required this.connections,
    required this.dashboard,
    required this.history,
    required this.tablet,
    required this.settings,
    required this.weather,
    required this.liveData,
    required super.child,
  });

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppServices>()!;

  @override
  bool updateShouldNotify(AppServices oldWidget) => false;
}

/// Coalesces a noisy listenable (the tracker fires per advertisement) into
/// at most one notification per [period].
class Throttled extends ChangeNotifier {
  final Listenable source;
  final Duration period;
  Timer? _timer;
  bool _pending = false;

  Throttled(this.source, this.period) {
    source.addListener(_onChange);
  }

  void _onChange() {
    if (_timer != null) {
      _pending = true;
      return;
    }
    notifyListeners();
    _timer = Timer(period, () {
      _timer = null;
      if (_pending) {
        _pending = false;
        _onChange();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    source.removeListener(_onChange);
    super.dispose();
  }
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
  late final ScanAutostart autostart = ScanAutostart(scanner);
  late final ConnectionManager connections = ConnectionManager.forScanner(
    scanner,
    tracker,
  );
  late final DashboardController dashboard = DashboardController();
  late final History history = History(tracker);
  late final TabletSensors tablet = TabletSensors();
  late final SettingsStore settings = SettingsStore();
  late final WeatherService weather = WeatherService(settings);
  late final Throttled liveData = Throttled(
    Listenable.merge([tracker, tablet, weather]),
    const Duration(seconds: 1),
  );
  Dimmer? _dimmer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    keys.load();
    connections.load();
    dashboard.load();
    keys.addListener(tracker.redecodeAll);
    scanner.advertisements.listen((adv) {
      tracker.onAdvertisement(adv);
      connections.onAdvertisement(adv);
    });
    autostart.start();
    history.start();
    // Android may kill a backgrounded app without warning: save on the way.
    _lifecycle = AppLifecycleListener(onHide: history.save);
    tablet.start();
    settings.load().then((_) {
      weather.start();
      _dimmer = Dimmer(settings, tablet);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _dimmer?.dispose();
    liveData.dispose();
    weather.dispose();
    tablet.dispose();
    history.dispose();
    dashboard.dispose();
    autostart.dispose();
    connections.dispose();
    scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppServices(
      scanner: scanner,
      autostart: autostart,
      keys: keys,
      tracker: tracker,
      connections: connections,
      dashboard: dashboard,
      history: history,
      tablet: tablet,
      settings: settings,
      weather: weather,
      liveData: liveData,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: "Le'Casa",
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: leCasaTheme(Brightness.light),
          darkTheme: leCasaTheme(Brightness.dark),
          home: const DashboardPage(),
        ),
      ),
    );
  }
}
