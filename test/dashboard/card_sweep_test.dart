// Draws every kind of card across a grid of slot sizes, the way the
// dashboard would pick a size for each. Any overflow fails the test. Set
// PREVIEW_DIR to also save one contact sheet per card for a visual check.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/dashboard/catalog.dart';
import 'package:lecasa/dashboard/dashboard_page.dart';
import 'package:lecasa/dashboard/history.dart';
import 'package:lecasa/dashboard/layout.dart';
import 'package:lecasa/platform/tablet.dart';
import 'package:lecasa/settings/settings_store.dart';
import 'package:lecasa/ui/palette.dart';
import 'package:lecasa/weather/weather.dart';

import 'fake_devices.dart';
import 'test_fonts.dart';

/// Every series is a day-shaped wave, so graphs have something to draw.
class _WavyHistory extends History {
  _WavyHistory() : super(chloesGear());

  @override
  List<double>? of(String k) => [
    for (var i = 0; i < 180; i++)
      math.max(0, math.sin(i / 180 * math.pi) * 600 + math.sin(i / 7) * 40),
  ];
}

WeatherService _weather() {
  final w = WeatherService(SettingsStore());
  final hours = [
    for (var h = 0; h < 24; h++) '2026-10-24T${'$h'.padLeft(2, '0')}:00',
  ];
  w.now = WeatherNow.parse({
    'current': {
      'time': '2026-10-24T13:10',
      'temperature_2m': 15.2,
      'apparent_temperature': 13.1,
      'weather_code': 1,
      'wind_speed_10m': 9.0,
      'relative_humidity_2m': 31,
    },
    'hourly': {
      'time': hours,
      'temperature_2m': [for (var h = 0; h < 24; h++) 8 + 9 * math.sin(h / 4)],
      'weather_code': [for (var h = 0; h < 24; h++) h % 5 == 0 ? 3 : 1],
    },
    'daily': {
      'temperature_2m_max': [19.0],
      'temperature_2m_min': [4.0],
      'precipitation_probability_max': [10],
    },
  }, DateTime(2026, 10, 24, 13, 10));
  w.status = WeatherStatus.ok;
  return w;
}

const widths = [150.0, 210.0, 280.0, 360.0, 460.0, 600.0];
const heights = [96.0, 130.0, 170.0, 220.0, 290.0, 380.0];

void main() {
  setUpAll(loadTestFonts);
  final previewDir = Platform.environment['PREVIEW_DIR'];

  final sources = CardSources(
    tracker: chloesGear(),
    history: _WavyHistory(),
    tablet: TabletSensors()
      ..batteryPercent = 64
      ..charging = true,
    weather: _weather(),
    now: () => DateTime(2026, 10, 24, 13, 12),
  );
  final specs = <String, CardSpec>{
    for (final e in catalog(sources)) e.spec.key: e.spec,
  };

  for (final MapEntry(key: name, value: spec) in specs.entries) {
    testWidgets('card $name fits every slot size', (t) async {
      const gap = 10.0;
      final sheet = Size(
        widths.fold(2 * gap, (a, w) => a + w + gap),
        heights.fold(2 * gap, (a, h) => a + h + gap),
      );
      t.view.physicalSize = sheet;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);

      await t.pumpWidget(
        RepaintBoundary(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: leCasaTheme(Brightness.dark),
            home: Builder(
              builder: (context) => Material(
                color: LeColors.of(context).screen,
                child: Padding(
                  padding: const EdgeInsets.all(gap),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final h in heights) ...[
                        Row(
                          children: [
                            for (final w in widths) ...[
                              SizedBox(
                                width: w,
                                height: h,
                                child: cardContent(
                                  spec,
                                  Size(w, h),
                                  sources,
                                ).$1,
                              ),
                              const SizedBox(width: gap),
                            ],
                          ],
                        ),
                        const SizedBox(height: gap),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();

      if (previewDir != null) {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        final image = await t.runAsync(() => boundary.toImage());
        final bytes = await t.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.png),
        );
        final file = name.replaceAll(RegExp('[^A-Za-z0-9]+'), '_');
        File('$previewDir/sweep-$file.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      }
    });
  }
}
