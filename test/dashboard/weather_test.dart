import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/settings/settings_store.dart';
import 'package:lecasa/weather/weather.dart';

void main() {
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
}
