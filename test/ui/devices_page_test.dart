// The settings and devices page: a split view on tablets, a list that
// opens deeper pages on phones. Set PREVIEW_DIR to save PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/app.dart';
import 'package:lecasa/ble/ble_scanner.dart';
import 'package:lecasa/ble/connection_manager.dart';
import 'package:lecasa/ble/scan_autostart.dart';
import 'package:lecasa/dashboard/dashboard_controller.dart';
import 'package:lecasa/dashboard/history.dart';
import 'package:lecasa/keys/key_store.dart';
import 'package:lecasa/platform/tablet.dart';
import 'package:lecasa/settings/settings_store.dart';
import 'package:lecasa/sync/ble_radio.dart';
import 'package:lecasa/sync/home.dart';
import 'package:lecasa/sync/sync_service.dart';
import 'package:lecasa/sync/read_by.dart';
import 'package:lecasa/ui/bluetooth_gate.dart';
import 'package:lecasa/ui/device_page.dart';
import 'package:lecasa/ui/devices_page.dart';
import 'package:lecasa/ui/palette.dart';
import 'package:lecasa/weather/weather.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dashboard/fake_devices.dart';
import '../dashboard/test_fonts.dart';

class _FakeCentral implements CentralManager {
  @override
  final BluetoothLowEnergyState state;
  _FakeCentral([this.state = BluetoothLowEnergyState.unknown]);

  @override
  dynamic noSuchMethod(Invocation i) =>
      i.isGetter ? const Stream<Never>.empty() : Future.value();
}

/// Pumps the page and returns what to call at the end of the test.
Future<Future<void> Function()> _pump(
  WidgetTester t,
  Size size, {
  BluetoothLowEnergyState bluetooth = BluetoothLowEnergyState.unknown,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final tracker = chloesGear();
  final scanner = BleScanner(_FakeCentral(bluetooth));
  final autostart = ScanAutostart(scanner)..start();
  final connections = ConnectionManager.forScanner(scanner, tracker);
  final settings = SettingsStore();
  final keys = KeyStore();
  final home = HomeStore.memory('test', 'Test screen');
  final sync = SyncService(
    home: home,
    tracker: tracker,
    keys: keys,
    connections: connections,
    radio: BleSyncRadio(scanner),
    readBy: ReadByStore.memory(),
  )..start();
  await t.pumpWidget(
    RepaintBoundary(
      child: AppServices(
        scanner: scanner,
        autostart: autostart,
        keys: keys,
        tracker: tracker,
        connections: connections,
        dashboard: DashboardController(),
        history: History(tracker),
        tablet: TabletSensors(),
        settings: settings,
        weather: WeatherService(settings),
        home: home,
        sync: sync,
        liveData: tracker,
        child: MaterialApp(
          theme: leCasaTheme(Brightness.light),
          builder: (context, child) => BluetoothGate(child: child!),
          home: const DevicesPage(),
        ),
      ),
    ),
  );
  await t.pump();
  return () async {
    sync.dispose();
    connections.dispose();
    await t.pumpWidget(const SizedBox());
  };
}

Future<void> _shot(WidgetTester t, String name) async {
  final dir = Platform.environment['PREVIEW_DIR'];
  if (dir == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  final image = await t.runAsync(() => boundary.toImage());
  final bytes = await t.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  File('$dir/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tablet: list on the left, general settings on the right', (
    t,
  ) async {
    final done = await _pump(t, const Size(1280, 800));
    expect(t.takeException(), isNull);
    // Groups are sections of the list, not tiles to open.
    expect(find.textContaining('Solar · 2'), findsOneWidget);
    expect(find.text('Luna 50'), findsOneWidget);
    // General settings show beside the list from the start.
    expect(find.text('Theme'), findsOneWidget);
    await _shot(t, 'settings-tablet-general');

    await t.tap(find.text('Luna 50'));
    await t.pump();
    expect(find.byType(DevicePage), findsOneWidget);
    expect(find.text('Theme'), findsNothing);
    await _shot(t, 'settings-tablet-device');
    // Still one page: nothing was pushed.
    expect(find.text('Luna 50'), findsWidgets);

    await t.tap(find.text('General'));
    await t.pump();
    expect(find.text('Theme'), findsOneWidget);
    await done();
  });

  testWidgets('phone: the list alone, a device opens as its own page', (
    t,
  ) async {
    final done = await _pump(t, const Size(390, 844));
    expect(t.takeException(), isNull);
    expect(find.text('Theme'), findsNothing);
    expect(find.byType(DevicePage), findsNothing);
    await _shot(t, 'settings-phone-list');

    await t.tap(find.text('Luna 50'));
    await t.pumpAndSettle();
    expect(find.byType(DevicePage), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    await _shot(t, 'settings-phone-device');

    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    await t.tap(find.text('General'));
    await t.pumpAndSettle();
    expect(find.text('Theme'), findsOneWidget);
    await done();
  });

  testWidgets('renaming a device in its header renames it everywhere', (
    t,
  ) async {
    final done = await _pump(t, const Size(1280, 800));
    await t.tap(find.text('Luna 50'));
    await t.pump();
    // The details sit on one line of chips; iOS-style ids go in the header.
    expect(find.textContaining('Signal'), findsOneWidget);
    await _shot(t, 'device-header-tablet');
    await t.tap(find.byTooltip('Rename'));
    await t.pump();
    await t.enterText(find.byType(TextField).first, 'Roof 50');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    // The header and the list both use the new name.
    expect(find.text('Roof 50'), findsNWidgets(2));
    // Emptying it goes back to the advertised name.
    await t.tap(find.byTooltip('Rename'));
    await t.pump();
    await t.enterText(find.byType(TextField).first, '');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(find.text('Roof 50'), findsNothing);
    expect(find.text('Luna 50'), findsNWidgets(2));
    await done();
  });

  testWidgets('a phone shows the platform id with the other details', (
    t,
  ) async {
    final done = await _pump(t, const Size(390, 844));
    await t.tap(find.text('Luna 50'));
    await t.pumpAndSettle();
    expect(find.textContaining('Signal'), findsOneWidget);
    expect(t.takeException(), isNull);
    await _shot(t, 'device-header-phone');
    await done();
  });

  testWidgets('Bluetooth off dims everything and says so', (t) async {
    final done = await _pump(
      t,
      const Size(1280, 800),
      bluetooth: BluetoothLowEnergyState.poweredOff,
    );
    expect(find.text('Bluetooth is off'), findsOneWidget);
    await _shot(t, 'bluetooth-off');
    // Taps do not reach the stale page underneath.
    await t.tap(find.text('Luna 50'), warnIfMissed: false);
    await t.pump();
    expect(find.byType(DevicePage), findsNothing);
    await done();
  });
}
