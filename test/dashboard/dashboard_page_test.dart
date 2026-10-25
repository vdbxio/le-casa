// Renders the real dashboard with Chloe's gear at common tablet sizes, in
// view and edit mode, light and dark. Any overflow or exception fails the
// test. Set PREVIEW_DIR to also save PNGs for a visual check.
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
import 'package:lecasa/dashboard/auto_layout.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/dashboard_controller.dart';
import 'package:lecasa/dashboard/dashboard_page.dart';
import 'package:lecasa/dashboard/history.dart';
import 'package:lecasa/keys/key_store.dart';
import 'package:lecasa/platform/tablet.dart';
import 'package:lecasa/settings/settings_store.dart';
import 'package:lecasa/ui/palette.dart';
import 'package:lecasa/weather/weather.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_devices.dart';
import 'test_fonts.dart';

class _FakeCentral implements CentralManager {
  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.unknown;

  @override
  dynamic noSuchMethod(Invocation i) =>
      i.isGetter ? const Stream<Never>.empty() : Future.value();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const sizes = [Size(1280, 800), Size(1024, 600), Size(960, 540)];
  final previewDir = Platform.environment['PREVIEW_DIR'];

  for (final size in sizes) {
    for (final dark in [false, true]) {
      testWidgets(
        'dashboard at ${size.width.toInt()}x${size.height.toInt()} ${dark ? 'dark' : 'light'}',
        (t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);

          final tracker = chloesGear();
          final scanner = BleScanner(_FakeCentral());
          final connections = ConnectionManager.forScanner(scanner, tracker);
          final settings = SettingsStore();
          final weather = WeatherService(settings);
          final tablet = TabletSensors()
            ..batteryPercent = 64
            ..charging = true
            ..lux = 120;
          final dash = DashboardController();
          await dash.load();
          dash.setLayout(
            autoLayout(
              catalog(
                CardSources(tracker: tracker, tablet: tablet, weather: weather),
              ),
            ),
          );

          await t.pumpWidget(
            RepaintBoundary(
              child: AppServices(
                scanner: scanner,
                autostart: ScanAutostart(scanner),
                keys: KeyStore(),
                tracker: tracker,
                connections: connections,
                dashboard: dash,
                history: History(tracker),
                tablet: tablet,
                settings: settings,
                weather: weather,
                liveData: tracker,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: leCasaTheme(dark ? Brightness.dark : Brightness.light),
                  home: const DashboardPage(),
                ),
              ),
            ),
          );
          await t.pump();
          expect(find.text('Solar'), findsOneWidget);

          Future<void> shot(String name) async {
            if (previewDir == null) return;
            final boundary = t.renderObject<RenderRepaintBoundary>(
              find.byType(RepaintBoundary).first,
            );
            final image = await t.runAsync(() => boundary.toImage());
            final bytes = await t.runAsync(
              () => image!.toByteData(format: ui.ImageByteFormat.png),
            );
            File(
                '$previewDir/$name-${size.width.toInt()}x${size.height.toInt()}-${dark ? 'dark' : 'light'}.png',
              )
              ..createSync(recursive: true)
              ..writeAsBytesSync(bytes!.buffer.asUint8List());
          }

          await shot('view');

          dash.setEditing(true);
          await t.pump();
          dash.select(const [2, 1]);
          await t.pump();
          await shot('edit');

          // The picker opens, hides cards already placed, and cancels cleanly.
          await t.tap(find.byTooltip('Change card'));
          await t.pumpAndSettle();
          expect(
            find.text('Already on the dashboard'.toUpperCase()),
            findsOneWidget,
          );
          await shot('picker');
          await t.tap(find.text('Cancel'));
          await t.pumpAndSettle();
          expect(find.text('Cancel'), findsNothing);

          // Rows instead of columns still lays out without overflow.
          await t.tap(find.text('Rows'));
          await t.pump();
          await shot('rows');

          connections.dispose();
          dash.dispose();
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
