// Settings: a panel down the right over the dimmed dashboard, with General,
// Home, Devices and Design. Set PREVIEW_DIR to save PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/app.dart';
import 'package:lecasa/voice/voice_controller.dart';
import 'package:lecasa/ble/ble_scanner.dart';
import 'package:lecasa/ble/connection_manager.dart';
import 'package:lecasa/ble/scan_autostart.dart';
import 'package:lecasa/dashboard/dashboard_controller.dart';
import 'package:lecasa/dashboard/history.dart';
import 'package:lecasa/keys/key_store.dart';
import 'package:lecasa/platform/tablet.dart';
import 'package:lecasa/settings/design_store.dart';
import 'package:lecasa/settings/people.dart';
import 'package:lecasa/settings/settings_store.dart';
import 'package:lecasa/sync/ble_radio.dart';
import 'package:lecasa/sync/home.dart';
import 'package:lecasa/sync/sync_service.dart';
import 'package:lecasa/sync/read_by.dart';
import 'package:lecasa/ui/bluetooth_gate.dart';
import 'package:lecasa/ui/device_page.dart';
import 'package:lecasa/dashboard/auto_layout.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/dashboard_page.dart';
import 'package:lecasa/settings/device_stage.dart';
import 'package:lecasa/settings/design_page.dart';
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

late DashboardController _dash;
late DesignStore _design;
late PeopleStore _people;

/// Pumps the dashboard and returns what to call at the end of the test.
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
  final dash = DashboardController();
  await dash.load();
  final weather = WeatherService(settings);
  dash.setLayout(
    autoLayout(
      catalog(CardSources(tracker: tracker, weather: weather)),
      upright: size.height > size.width,
    ),
  );
  final design = DesignStore();
  final people = PeopleStore();
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
        dashboard: dash,
        history: History(tracker),
        tablet: TabletSensors(),
        settings: settings,
        weather: weather,
        home: home,
        voice: VoiceController(
          tracker: tracker,
          connections: connections,
          settings: settings,
        ),
        sync: sync,
        people: people,
        design: design,
        liveData: tracker,
        child: ListenableBuilder(
          listenable: design,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: design.theme(Brightness.light),
            builder: (context, child) => BluetoothGate(child: child!),
            home: const DashboardPage(),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  _dash = dash;
  _design = design;
  _people = people;
  return () async {
    // Let the debounced saves run.
    await t.pump(const Duration(seconds: 1));
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

Future<void> _openSettings(WidgetTester t) async {
  await t.tap(find.byTooltip('Settings').first);
  await t.pumpAndSettle();
}

Future<void> _go(WidgetTester t, String section) async {
  await t.tap(find.text(section).first);
  await _settle(t);
}

/// Lets page transitions finish. Device pages tick every second, so
/// pumpAndSettle never settles on them.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the gear opens the panel: four sections and the stats', (
    t,
  ) async {
    final done = await _pump(t, const Size(1280, 800));
    await _openSettings(t);
    expect(t.takeException(), isNull);
    for (final s in ['General', 'Home', 'Devices', 'Design']) {
      expect(find.text(s), findsWidgets);
    }
    expect(find.text('At a glance'), findsOneWidget);
    expect(find.text('On the dashboard'), findsOneWidget);
    await _shot(t, 'sidebar-menu');

    await _go(t, 'General');
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Listen for devices'), findsOneWidget);
    await _shot(t, 'sidebar-general');

    // Back to the menu inside the panel, then a tap on the dim closes it.
    await t.tap(find.byType(BackButton));
    await _settle(t);
    expect(find.text('At a glance'), findsOneWidget);
    await t.tapAt(const Offset(200, 400));
    await _settle(t);
    expect(find.text('At a glance'), findsNothing);
    await done();
  });

  testWidgets('a device shows its card on the dimmed dashboard', (t) async {
    final done = await _pump(t, const Size(1280, 800));
    await _openSettings(t);
    await _go(t, 'Devices');
    expect(find.textContaining('Solar · 2'), findsOneWidget);
    await _shot(t, 'sidebar-devices');
    await t.tap(find.text('Luna 50').last);
    await _settle(t);
    expect(t.takeException(), isNull);
    expect(find.byType(DevicePage), findsOneWidget);
    expect(find.byType(DeviceStage), findsOneWidget);
    expect(find.text('Everything it reports'), findsOneWidget);
    await _shot(t, 'sidebar-device');

    // Luna is only in the combined solar card, so it can be added. The
    // dashboard is full: a + sits between every two slots.
    await t.tap(find.text('Add to dashboard'));
    await _settle(t);
    expect(find.byType(DevicePage), findsNothing);
    expect(_dash.placing, isNotNull);
    expect(find.textContaining('Tap a + to put'), findsOneWidget);
    await _shot(t, 'placing');
    final before = _dash.page.slots.length;
    await t.tap(find.byTooltip('Put it here').first);
    await _settle(t);
    expect(_dash.page.slots.length, before + 1);
    expect(_dash.placing, isNull);
    final luna = _dash.page.cardKeys.firstWhere((k) => k.contains('luna'));
    await _shot(t, 'placed');

    // Now on the dashboard, it can come off again.
    await _openSettings(t);
    await _go(t, 'Devices');
    await t.tap(find.text('Luna 50').last);
    await _settle(t);
    expect(find.text('Move on the dashboard'), findsOneWidget);
    await t.tap(find.text('Take off the dashboard'));
    await _settle(t);
    expect(_dash.page.cardKeys, isNot(contains(luna)));
    // Adding it back fills the empty slot it left.
    await t.tap(find.text('Add to dashboard'));
    await _settle(t);
    await t.tap(find.text('Put it here').first);
    await _settle(t);
    expect(_dash.page.cardKeys, contains(luna));
    expect(_dash.page.slots.length, before + 1);
    expect(t.takeException(), isNull);
    await done();
  });

  testWidgets('renaming a device in its header renames it everywhere', (
    t,
  ) async {
    final done = await _pump(t, const Size(1280, 800));
    await _openSettings(t);
    await _go(t, 'Devices');
    await t.tap(find.text('Luna 50').last);
    await _settle(t);
    expect(find.textContaining('Signal'), findsOneWidget);
    await t.tap(find.byTooltip('Rename'));
    await t.pump();
    await t.enterText(find.byType(TextField).first, 'Roof 50');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _settle(t);
    // The header and the card beside the panel use the new name.
    expect(find.text('Roof 50'), findsWidgets);
    await t.tap(find.byType(BackButton));
    await _settle(t);
    expect(find.text('Roof 50'), findsWidgets);
    await done();
  });

  testWidgets('home: add a person and give them a phone or fob', (t) async {
    final done = await _pump(t, const Size(1280, 800));
    await _openSettings(t);
    await _go(t, 'Home');
    expect(find.text('People'), findsOneWidget);
    expect(find.text('Screens and phones'), findsOneWidget);
    await t.tap(find.text('Add a person'));
    await _settle(t);
    await t.enterText(find.byType(TextField), 'Chloe');
    await t.tap(find.text('Save'));
    await _settle(t);
    expect(_people.people.single.name, 'Chloe');
    expect(find.text("Le'Fobs"), findsOneWidget);
    expect(t.takeException(), isNull);
    await _shot(t, 'sidebar-person');
    await t.tap(find.byType(BackButton));
    await _settle(t);
    expect(find.text('Chloe'), findsOneWidget);
    await _shot(t, 'sidebar-home');
    await done();
  });

  testWidgets('design: cards at every size beside the controls', (t) async {
    final done = await _pump(t, const Size(1280, 800));
    await _openSettings(t);
    await _go(t, 'Design');
    expect(find.byType(DesignStage), findsOneWidget);
    expect(find.textContaining('Large · '), findsWidgets);
    expect(t.takeException(), isNull);
    await _shot(t, 'sidebar-design');
    // Changing the shape changes the dashboard's look.
    _design.setStyle(_design.style.copyWith(radius: 4, border: 2, gap: 20));
    await _settle(t);
    expect(t.takeException(), isNull);
    await t.tap(find.text('Cards'));
    await _settle(t);
    expect(find.text('Hue'), findsOneWidget);
    await _shot(t, 'sidebar-design-edited');
    await done();
  });

  testWidgets('phone: the panel fills the screen', (t) async {
    final done = await _pump(t, const Size(390, 844));
    await _openSettings(t);
    expect(find.text('At a glance'), findsOneWidget);
    await _go(t, 'Devices');
    await t.tap(find.text('Luna 50').last);
    await _settle(t);
    expect(find.byType(DevicePage), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.text('Preview'));
    await _settle(t);
    expect(find.text('Everything it reports'), findsOneWidget);
    await _shot(t, 'sidebar-phone-preview');
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
    await done();
  });
}
