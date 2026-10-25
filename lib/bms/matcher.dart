// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Matches an advertisement against a BMS's [MatcherPattern]s.

import '../ble/gatt_session.dart';
import '../decoders/raw_advertisement.dart';
import 'bms_types.dart';

final Map<String, RegExp> _globCache = {};

/// Translates a shell-style pattern (fnmatch) into an anchored RegExp.
RegExp globToRegExp(String pattern) => _globCache.putIfAbsent(pattern, () {
  final b = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    switch (ch) {
      case '*':
        b.write('.*');
      case '?':
        b.write('.');
      case '[':
        final close = pattern.indexOf(']', i + 2);
        if (close < 0) {
          b.write(r'\[');
        } else {
          var body = pattern.substring(i + 1, close);
          if (body.startsWith('!')) body = '^${body.substring(1)}';
          b.write('[${body.replaceAll(r'\', r'\\')}]');
          i = close;
        }
      default:
        b.write(RegExp.escape(ch));
    }
  }
  b.write(r'$');
  return RegExp(b.toString(), dotAll: true);
});

/// All service UUIDs of [adv] as 128-bit lowercase strings.
Set<String> advServiceUuids(RawAdvertisement adv) => {
  for (final u in adv.serviceUuids) uuid16(u),
  for (final u in adv.longServiceUuids) normalizeUuid(u),
};

bool advertisementMatches(MatcherPattern m, RawAdvertisement adv) {
  if (m.serviceUuid != null &&
      !advServiceUuids(adv).contains(normalizeUuid(m.serviceUuid!))) {
    return false;
  }
  if (m.serviceDataUuid != null) {
    final want = normalizeUuid(m.serviceDataUuid!);
    final keys = {for (final k in adv.serviceData.keys) uuid16(k)};
    if (!keys.contains(want)) return false;
  }
  if (m.oui != null) {
    final mac = adv.macString?.toLowerCase();
    final oui = m.oui!.toLowerCase();
    if (mac == null ||
        !mac.startsWith(oui.length > 8 ? oui.substring(0, 8) : oui)) {
      return false;
    }
  }
  if (m.manufacturerId != null) {
    final data = adv.manufacturerData[m.manufacturerId];
    if (data == null) return false;
    final start = m.manufacturerDataStart;
    if (start != null && start.isNotEmpty) {
      if (data.length < start.length) return false;
      for (var i = 0; i < start.length; i++) {
        if (data[i] != start[i]) return false;
      }
    }
  }
  if (m.localName != null && m.localName!.isNotEmpty) {
    // Python's re.match anchors only at the start; fnmatch.translate adds
    // the end anchor itself, which globToRegExp does too.
    if (!globToRegExp(m.localName!).hasMatch(adv.name ?? '')) return false;
  }
  return true;
}
