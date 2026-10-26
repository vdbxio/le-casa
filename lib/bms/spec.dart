// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.

import '../decoders/raw_advertisement.dart';
import 'base_bms.dart';
import 'matcher.dart';

/// What is known about a BMS type before connecting: how to recognise it
/// and how to make a driver for it.
class BmsSpec {
  /// aiobmsble module name, e.g. `jbd_bms`. Stable; used in tests.
  final String module;
  final BmsInfo info;
  final List<MatcherPattern> matchers;
  final BaseBms Function(BmsDevice device, [BmsConfig? config]) create;

  /// The BMS needs a PIN or password before it answers.
  final bool acceptSecret;

  /// Short note for the setup screen on where the secret comes from.
  final String? secretHint;

  const BmsSpec({
    required this.module,
    required this.info,
    required this.matchers,
    required this.create,
    this.acceptSecret = false,
    this.secretHint,
  });

  String get title => '${info['manufacturer']} ${info['model']}';

  bool supports(RawAdvertisement adv) =>
      matchers.any((m) => advertisementMatches(m, adv));
}
