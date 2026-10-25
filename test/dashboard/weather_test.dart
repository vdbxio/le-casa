import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/card_options.dart';
import 'package:lecasa/dashboard/cards/card_view.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/settings/settings_store.dart';
import 'package:lecasa/ui/palette.dart';
import 'package:lecasa/weather/weather.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_devices.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('parses an Open-Meteo forecast from the current hour on', () {
    final hours = [
      for (var h = 0; h < 48; h++)
        '2026-10-24T${(h % 24).toString().padLeft(2, '0')}:00',
    ];
    for (var h = 24; h < 48; h++) {
      hours[h] = '2026-10-25T${(h - 24).toString().padLeft(2, '0')}:00';
    }
    final j = <String, Object?>{
      'current': {
        'time': '2026-10-24T22:45',
        'temperature_2m': 11.2,
        'apparent_temperature': 9.1,
        'weather_code': 2,
        'wind_speed_10m': 14.4,
        'relative_humidity_2m': 71,
      },
      'hourly': {
        'time': hours,
        'temperature_2m': [for (var h = 0; h < 48; h++) 10 - h * 0.1],
        'weather_code': [for (var h = 0; h < 48; h++) h.isEven ? 2 : 61],
      },
      'daily': {
        'temperature_2m_max': [14.0, 13.0],
        'temperature_2m_min': [6.0, 5.0],
        'precipitation_probability_max': [20, 60],
      },
    };
    final w = WeatherNow.parse(j, DateTime(2026, 10, 24, 22, 50));
    expect(w.temperature, 11.2);
    expect(w.condition, 'Partly cloudy');
    expect(w.high, 14);
    expect(w.rainChance, 20);
    expect(w.hours, hasLength(6));
    expect(w.hours.first.time, DateTime(2026, 10, 24, 22));
    expect(w.hours[2].time, DateTime(2026, 10, 25, 0));
  });

  test('a malformed response is a FormatException', () {
    expect(
      () => WeatherNow.parse({'current': 3}, DateTime(2026)),
      throwsFormatException,
    );
  });

  test('the forecast query asks for local time at the place', () {
    final u = WeatherService.forecastUri(
      const WeatherPlace('Here', 45.5, -122.6),
    );
    expect(u.host, 'api.open-meteo.com');
    expect(u.queryParameters['timezone'], 'auto');
    expect(u.queryParameters['latitude'], '45.5000');
  });

  group('where the forecast comes from', () {
    test('nothing is fetched until internet access is allowed', () async {
      final st = SettingsStore()..place = const WeatherPlace('Here', 1, 2);
      final w = WeatherService(st);
      await w.refresh();
      expect(w.status, WeatherStatus.noSource);
    });

    test('allowed but no place asks for one', () async {
      final st = SettingsStore();
      await st.setWeather(internet: true);
      final w = WeatherService(st);
      await w.refresh();
      expect(w.status, WeatherStatus.noPlace);
    });

    test('following the tablet that cannot be found says so', () async {
      final st = SettingsStore();
      await st.setWeather(internet: true, here: true);
      var asked = 0;
      final w = WeatherService(
        st,
        locate: () async {
          asked++;
          return null;
        },
      );
      await w.refresh();
      expect(asked, 1);
      expect(w.status, WeatherStatus.noLocation);
      // Picking a place by name stops following the tablet.
      await st.setPlace(const WeatherPlace('Bend', 44, -121));
      expect(st.weatherHere, isFalse);
    });

    test('tablets that already had a place keep fetching', () async {
      SharedPreferences.setMockInitialValues({
        'settings:placeName': 'Bend',
        'settings:placeLat': 44.0,
        'settings:placeLon': -121.0,
      });
      final st = SettingsStore();
      await st.load();
      expect(st.weatherInternet, isTrue);
    });
  });

  testWidgets('an unset weather card has a button to its options', (t) async {
    final st = SettingsStore();
    final w = WeatherService(st);
    await w.refresh();
    final sources = CardSources(tracker: chloesGear(), weather: w);
    final m = sources.model(const CardSpec('weather'));
    expect(m.setup, 'Set up weather');
    var opened = 0;
    for (final size in const [
      Size(460, 380),
      Size(300, 220),
      Size(280, 170),
      Size(210, 130),
    ]) {
      await t.pumpWidget(
        MaterialApp(
          theme: leCasaTheme(Brightness.dark),
          home: Center(
            child: SizedBox.fromSize(
              size: size,
              child: CardSetupScope(
                onSetup: () => opened++,
                child: DashCard(m, CardSize.medium),
              ),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull, reason: '$size');
      if (size.height >= 220) {
        await t.tap(find.text('Set up weather'));
        expect(opened, greaterThan(0));
      }
    }
  });

  testWidgets('weather options set the location and internet access', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final st = SettingsStore();
    final w = WeatherService(st, locate: () async => null);
    final sources = CardSources(tracker: chloesGear(), weather: w);
    await t.pumpWidget(
      MaterialApp(
        theme: leCasaTheme(Brightness.dark),
        home: CardOptionsPage(
          spec: const CardSpec('weather'),
          slotSize: const Size(420, 300),
          sources: sources,
          entries: catalog(sources),
          onDashboard: const {'weather'},
        ),
      ),
    );
    expect(find.text('Use device location'), findsOneWidget);
    expect(find.text('Set location'), findsOneWidget);
    expect(find.text('Link companion app'), findsOneWidget);
    await t.tap(find.text('Allow internet access'));
    await t.pumpAndSettle();
    expect(st.weatherInternet, isTrue);
    await t.tap(find.text('Use device location'));
    await t.pumpAndSettle();
    expect(st.weatherHere, isTrue);
    expect(w.status, WeatherStatus.noLocation);
    expect(find.textContaining('Could not find the tablet'), findsOneWidget);
  });
}
