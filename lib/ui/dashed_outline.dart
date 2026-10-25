// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

/// The dashed border edit mode draws around slots and card boxes.
class DashedOutline extends CustomPainter {
  final Color color;
  final double width;
  final double radius;
  DashedOutline(this.color, this.width, {this.radius = 20});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(width / 2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 14) {
        canvas.drawPath(m.extractPath(d, d + 8), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedOutline old) =>
      old.color != color || old.width != width || old.radius != radius;
}
