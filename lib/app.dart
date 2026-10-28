// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'ble/ble_scanner.dart';
import 'ble/connection_manager.dart';
import 'ble/device_tracker.dart';
import 'ble/scan_autostart.dart';
import 'dashboard/dashboard_controller.dart';
import 'dashboard/dashboard_page.dart';
import 'dashboard/history.dart';
import 'decoders/registry.dart';
import 'drivers/driver.dart';
import 'keys/key_store.dart';
import 'platform/tablet.dart';
import 'settings/dimmer.dart';
import 'settings/settings_store.dart';
import 'sync/ble_radio.dart';
import 'sync/home.dart';
import 'sync/sync_service.dart';
import 'sync/wire.dart';
import 'ui/bluetooth_gate.dart';
import 'ui/palette.dart';
import 'voice/voice_controller.dart';
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
  final HomeStore home;
  final SyncService sync;
  final VoiceController voice;

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
    required this.home,
    required this.sync,
    required this.voice,
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
    drivers: GattDriverRegistry.standard(secretFor: keys.secretFor),
    holdLinks:
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS,
    optIn: true,
  );
  late final DashboardController dashboard = DashboardController();
  late final History history = History(tracker);
  late final TabletSensors tablet = TabletSensors();
  late final SettingsStore settings = SettingsStore();
  late final WeatherService weather = WeatherService(settings);
  late final HomeStore home = HomeStore();
  late final SyncService sync = SyncService(
    home: home,
    tracker: tracker,
    keys: keys,
    connections: connections,
    radio: BleSyncRadio(scanner, connections: connections),
    dialsFirst: defaultTargetPlatform == TargetPlatform.android,
    // Cheap Android tablets hear a tenth of the broadcasts around them
    // while a link is up, so they visit the other screens instead.
    visitEvery: defaultTargetPlatform == TargetPlatform.android
        ? const Duration(seconds: 20)
        : null,
  );
  late final VoiceController voice = VoiceController(
    tracker: tracker,
    connections: connections,
    settings: settings,
    share: sync,
  );
  late final Throttled liveData = Throttled(
    Listenable.merge([tracker, tablet, weather]),
    const Duration(seconds: 1),
  );
  Dimmer? _dimmer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    keys.label = (id) {
      final d = tracker[id];
      return (
        name: d?.latest.name,
        mac: d?.mac,
        fp: d == null || d.remoteOnly
            ? null
            : advertFingerprint(d.lastRecognised ?? d.latest),
      );
    };
    keys
        .load()
        .then((_) => home.load())
        .then((_) => sync.readBy.load())
        .then((_) => sync.start());
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
    _lifecycle = AppLifecycleListener(
      onHide: history.save,
      // Coming back from another app or the lock screen can bring the
      // system bars back; hide them again.
      onResume: hideSystemBars,
    );
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
    voice.dispose();
    weather.dispose();
    sync.dispose();
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
      home: home,
      sync: sync,
      voice: voice,
      liveData: liveData,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: "Le'Casa",
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: leCasaTheme(Brightness.light),
          darkTheme: leCasaTheme(Brightness.dark),
          builder: (context, child) =>
              BluetoothGate(child: child ?? const SizedBox()),
          home: const DashboardPage(),
        ),
      ),
    );
  }
}
