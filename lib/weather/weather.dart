// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../settings/settings_store.dart';

/// One hour of the forecast.
class WeatherHour {
  final DateTime time;
  final double temperature;
  final int code;
  const WeatherHour(this.time, this.temperature, this.code);
}

class WeatherNow {
  final double temperature, feelsLike, wind;
  final int humidity, code;
  final double? high, low;
  final int? rainChance;
  final List<WeatherHour> hours;
  final DateTime fetchedAt;

  const WeatherNow({
    required this.temperature,
    required this.feelsLike,
    required this.wind,
    required this.humidity,
    required this.code,
    required this.high,
    required this.low,
    required this.rainChance,
    required this.hours,
    required this.fetchedAt,
  });

  String get condition => weatherText(code);

  /// Parses an Open-Meteo forecast response (the query in
  /// [WeatherService.forecastUri]). Throws [FormatException] on surprises.
  static WeatherNow parse(Map<String, Object?> j, DateTime now) {
    try {
      final cur = (j['current'] as Map).cast<String, Object?>();
      final daily = (j['daily'] as Map?)?.cast<String, Object?>();
      final hourly = (j['hourly'] as Map).cast<String, Object?>();
      num? first(String k) {
        final l = daily?[k] as List?;
        return (l == null || l.isEmpty) ? null : l.first as num?;
      }

      final times = (hourly['time'] as List).cast<String>();
      final temps = hourly['temperature_2m'] as List;
      final codes = hourly['weather_code'] as List;
      // Times are local to the place (timezone=auto). Start at the current
      // hour of the place's own clock, taken from current.time.
      final curTime = DateTime.parse(cur['time'] as String);
      final startHour = DateTime(
        curTime.year,
        curTime.month,
        curTime.day,
        curTime.hour,
      );
      final hours = <WeatherHour>[];
      for (var i = 0; i < times.length && hours.length < 6; i++) {
        final t = DateTime.parse(times[i]);
        if (t.isBefore(startHour)) continue;
        if (temps[i] == null || codes[i] == null) continue;
        hours.add(
          WeatherHour(
            t,
            (temps[i] as num).toDouble(),
            (codes[i] as num).toInt(),
          ),
        );
      }
      return WeatherNow(
        temperature: (cur['temperature_2m'] as num).toDouble(),
        feelsLike: (cur['apparent_temperature'] as num).toDouble(),
        wind: (cur['wind_speed_10m'] as num).toDouble(),
        humidity: (cur['relative_humidity_2m'] as num).toInt(),
        code: (cur['weather_code'] as num).toInt(),
        high: first('temperature_2m_max')?.toDouble(),
        low: first('temperature_2m_min')?.toDouble(),
        rainChance: first('precipitation_probability_max')?.toInt(),
        hours: hours,
        fetchedAt: now,
      );
    } on TypeError catch (e) {
      throw FormatException('Unexpected forecast shape: $e');
    }
  }
}

/// WMO weather interpretation codes, as Open-Meteo uses them.
String weatherText(int code) => switch (code) {
  0 => 'Clear',
  1 => 'Mainly clear',
  2 => 'Partly cloudy',
  3 => 'Overcast',
  45 || 48 => 'Fog',
  51 || 53 || 55 || 56 || 57 => 'Drizzle',
  61 || 63 || 65 || 66 || 67 => 'Rain',
  71 || 73 || 75 || 77 => 'Snow',
  80 || 81 || 82 => 'Showers',
  85 || 86 => 'Snow showers',
  95 || 96 || 99 => 'Thunderstorm',
  _ => 'Weather $code',
};

enum WeatherStatus {
  /// Neither the internet nor the phone companion is allowed to bring the
  /// forecast in.
  noSource,

  /// No place picked and not following the tablet's location.
  noPlace,

  /// Following the tablet's location, but it could not be found (no
  /// permission, location off, or no fix).
  noLocation,
  loading,
  ok,
  offline,
}

/// Finds the tablet, or null when it cannot. Swapped out in tests.
typedef Locate = Future<WeatherPlace?> Function();

/// Fetches the forecast straight from Open-Meteo when the tablet has
/// internet and the user allowed it. Later the phone companion will relay
/// it over Bluetooth for tablets that are never online.
class WeatherService extends ChangeNotifier {
  final SettingsStore settings;
  final Locate _locate;
  WeatherNow? now;
  WeatherStatus status = WeatherStatus.noSource;
  Timer? _timer;
  String? _for;

  /// Where the forecast is for: the picked place, or the tablet's own
  /// location once found.
  WeatherPlace? place;

  WeatherService(this.settings, {Locate? locate})
    : _locate = locate ?? locateTablet {
    settings.addListener(_placeChanged);
  }

  void start() {
    _placeChanged();
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => refresh());
  }

  String get _source {
    final p = settings.place;
    return '${settings.weatherInternet} ${settings.weatherHere} '
        '${p?.name} ${p?.lat} ${p?.lon}';
  }

  void _placeChanged() {
    final key = _source;
    if (key == _for) return;
    _for = key;
    now = null;
    place = null;
    refresh();
  }

  static Uri forecastUri(WeatherPlace p) => Uri.https(
    'api.open-meteo.com',
    '/v1/forecast',
    {
      'latitude': p.lat.toStringAsFixed(4),
      'longitude': p.lon.toStringAsFixed(4),
      'current': 'temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m',
      'hourly': 'temperature_2m,weather_code',
      'daily':
          'temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'forecast_days': '2',
      'timezone': 'auto',
    },
  );

  Future<void> refresh() async {
    final key = _source;
    void set(WeatherStatus st) {
      if (key != _source) return;
      status = st;
      notifyListeners();
    }

    if (!settings.weatherInternet) return set(WeatherStatus.noSource);
    if (now == null) set(WeatherStatus.loading);
    final WeatherPlace? p;
    if (settings.weatherHere) {
      p = await _locate() ?? place;
      if (key != _source) return;
      if (p == null) return set(WeatherStatus.noLocation);
    } else {
      p = settings.place;
      if (p == null) return set(WeatherStatus.noPlace);
    }
    place = p;
    try {
      final j = await getJson(forecastUri(p));
      if (key != _source) return;
      now = WeatherNow.parse(j, DateTime.now());
      status = WeatherStatus.ok;
    } catch (e) {
      debugPrint('Weather fetch failed: $e');
      // Keep showing a recent forecast through a short outage.
      final stale =
          now == null ||
          DateTime.now().difference(now!.fetchedAt) > const Duration(hours: 3);
      if (stale) {
        now = null;
        status = WeatherStatus.offline;
      }
    }
    if (key == _source) notifyListeners();
  }

  /// The tablet's rough location, asking for permission the first time.
  /// City-level accuracy is all a forecast needs.
  static Future<WeatherPlace?> locateTablet() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 20),
          ),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      if (pos == null) return null;
      return WeatherPlace('Your location', pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('Locating the tablet failed: $e');
      return null;
    }
  }

  /// Looks a place up by name (Open-Meteo geocoding).
  static Future<List<WeatherPlace>> search(String query) async {
    final j = await getJson(
      Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
        'name': query,
        'count': '6',
        'language': 'en',
      }),
    );
    return [
      for (final r in (j['results'] as List? ?? const []))
        if (r is Map)
          WeatherPlace(
            [
              r['name'],
              r['admin1'],
              r['country'],
            ].whereType<String>().toSet().join(', '),
            (r['latitude'] as num).toDouble(),
            (r['longitude'] as num).toDouble(),
          ),
    ];
  }

  static Future<Map<String, Object?>> getJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final body = await res.transform(utf8.decoder).join();
      return (jsonDecode(body) as Map).cast<String, Object?>();
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    settings.removeListener(_placeChanged);
    super.dispose();
  }
}
